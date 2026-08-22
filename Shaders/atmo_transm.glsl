// Precomputed Atmospheric Scattering
// Copyright (C) 2008 Eric Bruneton
// All rights reserved.
//
// Redistribution and use in source and binary forms, with or without
// modification, are permitted provided that the following conditions
// are met:
// 1. Redistributions of source code must retain the above copyright
//    notice, this list of conditions and the following disclaimer.
// 2. Redistributions in binary form must reproduce the above copyright
//    notice, this list of conditions and the following disclaimer in the
//    documentation and/or other materials provided with the distribution.
// 3. Neither the name of the copyright holders nor the names of its
//    contributors may be used to endorse or promote products derived from
//    this software without specific prior written permission.
//
// THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
// AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
// IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
// ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT OWNER OR CONTRIBUTORS BE
// LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
// CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
// SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
// INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
// CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
// ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF
// THE POSSIBILITY OF SUCH DAMAGE.

#auto_version

#ifdef LOG_Z_BUFFER_FS
#extension GL_ARB_conservative_depth : enable
#endif

#auto_defines

const int RES_R    = 32;	// default: 32
const int RES_MU   = 64;	// default: 128
const int RES_MU_S = 32;	// default: 32
const int RES_NU   = 16;	// default: 8

const float INV_RES_NU = 1.0 / RES_NU;

// Samplers

uniform sampler2D transmittanceSampler; // precomputed transmittance (T table)

// Uniforms

//uniform vec4    AtmoParams1;    // (density, scattering bright, skylight bright, exposure)
//uniform vec4    AtmoParams2;    // (MieG, MieFade, HR, HM)
//uniform vec3    AtmoRayleigh;   // (betaR)
//uniform vec3    AtmoMieExt;     // (betaMExt);
//uniform vec4    Radiuses;       // (atmosphere bottom radius, atmosphere top radius, atmosphere height, surface radius)
//uniform vec4    EyePos;         // Object-space camera position, logFactor
//uniform mat4x4  ModelViewProj;  // mvp matrix
#uniform_block

//-----------------------------------------------------------------------------
#ifdef _VERTEX_
//-----------------------------------------------------------------------------

layout(location = 0) in  vec3  VertexPos;
layout(location = 1) in  vec2  TexCoord;
layout(location = 2) in  vec3  Tangent;

out vec4 vNormal;// Normal, Pixel depth

void main()
{
    // Calculate output position
    gl_Position = ModelViewProj * vec4(VertexPos, 1.0);
    vNormal.xyz = VertexPos;

#ifdef LOG_Z_BUFFER_VS
    // Calculate a logarithmic depth value
    gl_Position.z = (log2(max(1.0e-6, 1.0 + gl_Position.z)) * EyePos.w - 1.0) * gl_Position.w;
#endif
#ifdef LOG_Z_BUFFER_FS
    // Transfer a depth value
    vNormal.w = gl_Position.z;
#endif
}

//-----------------------------------------------------------------------------
#else // _VERTEX_
//-----------------------------------------------------------------------------

                     in  vec4 vNormal;
layout(location = 0) out vec4 OutColor;

#ifdef LOG_Z_BUFFER_FS
layout(depth_less) out float gl_FragDepth;
#endif

//-----------------------------------------------------------------------------
// transmittance(=transparency) of atmosphere for infinite ray (r,mu)
// (mu=cos(view zenith angle)), intersections with ground ignored
// h - relative height (h = (r - planRadius) / atmoHeight)
// Bruneton 2017 mapping for the mu axis - kept bit-for-bit consistent with
// the copy of this function in atmo_common.glh (both read the same
// transmittanceSampler baked by ag_transmittance.glsl / ag_common.glh).
// No AtmoParams3 uniform is available in this shader, so H and Rg*Rg are
// recomputed from Radiuses instead of reusing precomputed components.
vec3 transmittance(float sqrth, float mu)
{
    float Rg = Radiuses.x;
    float Rt = Radiuses.y;
    float r  = Rg + sqrth * sqrth * (Rt - Rg);
    float H  = sqrt(max(Rt * Rt - Rg * Rg, 0.0));
    float d    = -r * mu + sqrt(max(r * r * (mu * mu - 1.0) + Rt * Rt, 0.0));
    float dMin = Rt - r;
    float dMax = sqrt(max(r * r - Rg * Rg, 0.0)) + H;
    float uMu  = (d - dMin) / max(dMax - dMin, 1e-6);
    return texture2D(transmittanceSampler, vec2(uMu, sqrth)).rgb;
}

//-----------------------------------------------------------------------------
// transmittance(=transparency) of atmosphere between x and x0
// assume segment x,x0 not intersecting ground
// r=||x||, mu=cos(zenith angle of [x,x0) ray at x)
vec3 transmittance(float sqrth, float mu, float sqrth0, float mu0)
{
    vec3 tr;
    if (mu > 0.0)
        tr = transmittance(sqrth, mu) / transmittance(sqrth0, mu0);
    else
        tr = transmittance(sqrth0, -mu0) / transmittance(sqrth, -mu);
    return mix(vec3(1.0), tr, AtmoParams1.x);
}

//-----------------------------------------------------------------------------
// optical depth for ray (r,mu) of length d, using analytic formula
// (mu=cos(view zenith angle)), intersections with ground ignored
// H = height scale of exponential density function
float opticalDepth(float H, float r, float mu, float d)
{
    float rcpH = 1.0/H;
    float a = sqrt(0.5*r*rcpH);
    float dr = d/r;
    vec2  a01 = a * vec2(mu, dr + mu);
    vec2  a01s = sign(a01);
    vec2  a01sq = a01*a01;
    float x = (a01s.y > a01s.x) ? exp(a01sq.x) : 0.0;
    vec2  y = a01s / (2.3193*abs(a01) + sqrt(1.52*a01sq + 4.0)) * vec2(1.0, exp(-d * rcpH * (0.5*dr + mu)));
    return sqrt(6.2831*H*r) * exp((Radiuses.x-r) * rcpH) * (x + dot(y, vec2(1.0, -1.0)));
}

//-----------------------------------------------------------------------------
// transmittance (transparency) of atmosphere for ray (r, mu) of length d
// (mu = cos(view zenith angle)), intersections with ground ignored
// uses analytic formula instead of transmittance texture
vec3 transmittanceAnalytic(float r, float mu, float d)
{
    vec3 tr = exp(-AtmoRayleigh.rgb * opticalDepth(AtmoParams2.z, r, mu, d) - AtmoMieExt.rgb * opticalDepth(AtmoParams2.w, r, mu, d));
    if (isnan(tr.r)) tr = vec3(1.0);
    return mix(vec3(1.0), tr, AtmoParams1.x);
}

//-----------------------------------------------------------------------------

void main()
{
#ifdef LOG_Z_BUFFER_FS
    // Calculate a logarithmic depth value
    gl_FragDepth = log2(1.0 + vNormal.w) * EyePos.w;
#endif

    // Calculate precise fragment position
    float FragR   = Radiuses.y * 0.999;
    vec3  FragPos = normalize(vNormal.xyz) * FragR;

    // Calculate eye vector in object space
    //vec3  eyeVec = normalize(FragPos - EyePos);
    vec3  eyeVec = FragPos - EyePos.xyz;
    float eyeVecLength = length(eyeVec);
    eyeVec /= eyeVecLength;

    // Calculate fragment and eye parameters for atmosphere
    float EyeH;
    float EyeR  = length(EyePos.xyz);
    float EyeMu = dot(EyePos.xyz, eyeVec) / EyeR;

    // if EyePos in space, move it to nearest intersection of ray with top atmosphere boundary
    float d = -EyeR * EyeMu - sqrt(EyeR * EyeR * (EyeMu * EyeMu - 1.0) + Radiuses.y * Radiuses.y);
    if (d > 0.0)
    {
        EyeMu = (EyeR * EyeMu + d) / Radiuses.y;
        EyeR = Radiuses.y;
        EyeH = 1.0;
    }
    else
        EyeH = (EyeR - Radiuses.x) / Radiuses.z;

    // Atmospheric attenuation along ray from the atmosphere top boundary to the viewer
    //OutColor.rgb = vec3(1.0) - transmittanceWithShadow(EyeR, sqrt(EyeH), EyeMu);
    //OutColor.rgb = vec3(1.0) - transmittance(sqrt(EyeH), EyeMu);
    OutColor.rgb = vec3(1.0) - transmittanceAnalytic(EyeR, EyeMu, eyeVecLength);
    OutColor.a = 0.0;
}

//-----------------------------------------------------------------------------

#endif
