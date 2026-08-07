#auto_version

//===========================================================================//
//                                                                           //
//               SpaceEngine planetary sky rendering shader                  //
//                                                                           //
//===========================================================================//

// Defines passed from SpaceEngine. Possible defines:
// Effects:           	THERM, RINGS, ECL, PLANEMO
// Vendor-specific:     INTEL, LOGVS, LOGFS
#auto_defines

#ifdef LOGFS
#extension GL_ARB_conservative_depth : enable
#endif

// Standard defines
#define MAX_LIGHTS   4
#define MAX_ECLIPSES 8

#define SHADOW (defined(RINGS) || defined(ECL))

//===========================================================================//
//                                                                           //
//                            Texture samplers                               //
//                                                                           //
//===========================================================================//

uniform sampler2D irradianceSampler;    // precomputed skylight irradiance (E table)
uniform sampler2D transmittanceSampler; // precomputed transmittance (T table)
uniform sampler3D inscatterSampler;     // precomputed inscattered light (S table)

#ifdef RINGS
uniform sampler2D RingsMap;
#endif

//===========================================================================//
//                                                                           //
//                                Uniforms                                   //
//                                                                           //
//===========================================================================//

//uniform vec4   AtmoParams1;   // density, scattering bright, skylight bright, exposure
//uniform vec4   AtmoParams2;   // MieG, MieFade, HR, HM
//uniform vec4   AtmoParams3;   // planet_radius^2, atmoH^2, atmoH, mieG^2
//uniform vec3   AtmoRayleigh;  // betaR
//uniform vec3   AtmoMieExt;    // betaMExt
//uniform vec2   AtmoColAdjust; // hsl color adjust
//
//uniform vec4   Radiuses;      // atmosphere bottom radius, atmosphere top radius, atmosphere height, surface radius
//uniform mat4x4 ModelViewProj; // modelview * projection matrix
//
//uniform int    NLights;                 // lights count
//uniform vec3   LightPos   [MAX_LIGHTS]; // object-space light position
//uniform vec3   LightColor [MAX_LIGHTS]; // light color
//uniform vec3   LightParams[MAX_LIGHTS]; // light radius, light luminosity, light specular power
//
//#ifdef ECL
//uniform vec4   EclipseCasters[MAX_LIGHTS * MAX_ECLIPSES];
//#endif
//
//uniform vec4   AmbientColor;  // ambient color, eclipse shadow intensity
//uniform vec3   GlowColorAtmo; // glow color of the atmosphere
//uniform vec3   EyePos;        // object-space camera position, minEyeMu
//uniform vec3   Ellipsoid;     // planet ellipsoid oblateness
//
//#ifdef RINGS
//uniform vec3   RingsParams;   // rings inner radius, rings thickness, rings density, inv width
//#endif
//
//#if (defined(LOGFS) || defined(LOGVS))
//uniform float  LogZParams;    // logFactor
//#endif

#uniform_block

//===========================================================================//
//                                                                           //
//           Variables, shared with the atmospheric scattering code          //
//                                                                           //
//===========================================================================//

vec3  FragPos       = vec3(0.0,0.0,0.0);
float FragR         = 0.0;
float FragH         = 0.0;
float FragMu        = 0.0;
vec3  EyePosM       = vec3(0.0,0.0,0.0);
float EyeR          = 0.0;
float EyeH          = 0.0;
float EyeMu         = 0.0;
float EyeMuS        = 0.0;
float MieHorFade    = 0.0;
vec3  eyeVec        = vec3(0.0,0.0,0.0);
float eyeVecLength  = 0.0;
float HorizonMu     = 0.0;
float HorizonFixEps = 0.0;
vec3  Attenuation   = vec3(0.0,0.0,0.0);

const float pi = 3.14159265359;

#include "hsl.glh"
#include "atmo_common.glh"

#ifdef RINGS
#define RINGS_SHADOW_CODE
#include "rings_common.glh"
#endif

#ifdef ECL
#include "eclipse_common.glh"
#endif

//===========================================================================//
//                                                                           //
//                             Vertex shader                                 //
//                                                                           //
//===========================================================================//

#ifdef _VERTEX_

// Vertex shader input
layout(location = 0) in  vec3  VertexPos;
layout(location = 1) in  vec2  TexCoord;
layout(location = 2) in  vec3  Tangent;

// Vertex shader output
out vec4 vPosition;

//=============================================================================
// Vertex shader entry point

void main()
{
    // Calculate the output position
    gl_Position = ModelViewProj * vec4(VertexPos, 1.0);
    vPosition.xyz = VertexPos;

    // Logarithmic depth buffer:
    // calculate the per-vertex logarithmic depth value in vertex shader (LOGVS mode),
    // or transfer it to the fragment shader for further per-fragment calculation (LOGFS mode)
	#ifdef LOGVS
		gl_Position.z = (log2(max(1.0e-6, 1.0 + gl_Position.w)) * LogZParams - 1.0) * gl_Position.w;
    #endif
	#ifdef LOGFS
		vPosition.w = gl_Position.z;
	#endif
}

#endif // _VERTEX_

//===========================================================================//
//                                                                           //
//                            Fragment shader                                //
//                                                                           //
//===========================================================================//

#ifdef _FRAGMENT_

// Fragment shader input
in vec4 vPosition;

// Fragment shader output
#ifdef INTEL
out vec4 FragColor;
#else
layout(location = 0) out vec4 FragColor;
#endif

#ifdef LOGFS
layout(depth_less) out float gl_FragDepth;
#endif

//=============================================================================
// Fragment shader entry point

void main()
{
    // Logarithmic depth buffer:
    // calculate the per-pixel logarithmic depth value (LOGFS mode)
	#ifdef LOGFS
		gl_FragDepth = log2(1.0 + vPosition.w) * LogZParams;
	#endif

    // Calculate precise fragment position
    FragR   = Radiuses.y;
    FragPos = normalize(vPosition.xyz) * FragR;
    vec3  FragPosS = FragPos * Ellipsoid;
    vec3  Normal = normalize(FragPos);

    // Calculate eye vector in object space
    eyeVec = normalize(FragPos - EyePos);

    // Calculate fragment and eye parameters for atmosphere
    EyeR  = length(EyePos);
    EyeH  = (EyeR - Radiuses.x) / Radiuses.z;
    EyeMu = dot(EyePos, eyeVec) / EyeR;

    EyePosM = EyePos;
    float b = -EyeR * EyeMu;
    float t = EyeR * EyeR * (EyeMu * EyeMu - 1.0);
    float d = b - sqrt(max(t + Radiuses.y * Radiuses.y, 0.0));
    if (d > 0.0)
    {
        // if EyePos in space, move it to nearest intersection of ray with top atmosphere boundary
        EyePosM += d * eyeVec;
        EyeMu = (EyeR * EyeMu + d) / Radiuses.y;
        EyeR = Radiuses.y;
        EyeH = 1.0;
    }
    else if (EyeH < 0.0)
    {
        // if EyePos is below sea level, move it to nearest intersection of ray with bottom atmosphere boundary
        d = b + sqrt(t + Radiuses.x * Radiuses.x);
        if (d >= 0.0)
        {
            EyePosM += d * eyeVec;
            EyeMu = (EyeR * EyeMu + d) / Radiuses.x;
            EyeR = Radiuses.x;
            EyeH = 0.001;
        }
    }

    // Atmospheric scattering along ray from the atmosphere top boundary to the viewer
    #ifdef THERM
        EyeMuS = 0.0;
        MieHorFade = 0.0;
        vec3 Inscatter = inscatterSky(vec3(0.0)) * GlowColorAtmo;
    #else
        vec3 Inscatter = vec3(0.0);
    #endif

    // Calculate light vectors in object space
    for (int i=0; i<NLights; i++)
    {
        vec3 lightPos = LightPos[i] - FragPos;
        vec3 lightVec = normalize(lightPos);

        EyeMuS = dot(EyePosM, lightVec) / EyeR;
        MieHorFade = smoothstep(0.0, AtmoParams2.y, EyeMuS); // Fade to avoid imprecision problems in Mie scattering when sun is below horizon

        // Rings and eclipse shadows
        vec3 ShadowColor = vec3(1.0);
        vec3 eclFactor = vec3(1.0);

        #if SHADOW

            // Calculate shadow by rings
            #ifdef RINGS
                float cosPhi = abs(lightVec.y);
                vec2  shadowProj = vPosition.xz - lightPos.xz * min(vPosition.y / lightPos.y, 0.0);
                float texU = (length(shadowProj) * Radiuses.y - RingsParams.x) * RingsParams.w;
                ShadowColor *= RingsShadow(texU, cosPhi);
            #endif

            // Calculate eclipse shadow & atmospheric refraction tinting
            #ifdef ECL
                vec3  lightVecSN = normalize(lightPos * Ellipsoid);
                float lightAngularRadius = asin(LightParams[i].x * inversesqrt(dot(LightPos[i], LightPos[i])));
                vec3  skyEclColor = EclipseShadowColoredAuto(i, MAX_ECLIPSES, FragPosS, lightVecSN, lightAngularRadius);
                eclFactor = mix(vec3(1.0), skyEclColor, AmbientColor.a);
                ShadowColor *= eclFactor;
            #endif

        #endif // SHADOW

        // Direct sun light color, modulated by shadows
        vec3  sunLight = LightColor[i].rgb * ShadowColor;

        // Atmospheric scattering along ray from the atmosphere top boundary to the viewer
        Inscatter += inscatterSky(lightVec) * sunLight;

        // Atmospheric Ringshine Illumination
        // Concept & Sky Inscattering: Donatelo200
        // Multi-Band Integral & Analytical Shadow Cylinder (shadow_occ): JustNoetic
        #ifdef RINGS
        {
            vec3  sunDir = normalize(LightPos[i]);
            float frag_elev = Normal.y;
            float sun_elev  = sunDir.y;

            float planet_radius_m = max(1.0, Radiuses.y - Radiuses.z*3.14);
            float ring_inner_pr = (RingsParams.x / planet_radius_m);
            float ring_outer_pr = ((RingsParams.x + (1.0 / max(1e-6, RingsParams.w))) / planet_radius_m);
			float ring_outer_vis = ((1.5575/(1.5575 - tan(1/ring_outer_pr)))-1)/2+1;
			
			float sin_lat = abs(frag_elev);
            float cos_lat = sqrt(max(0, 1.0 - sin_lat * sin_lat*ring_outer_vis));
            float lat_decay = pow(cos_lat, 7.5);
            float form_factor = sin_lat * lat_decay * 5;
			
			//float ring_inner_pr = RingsParams.x / planet_radius_m;
            //float ring_outer_pr = (RingsParams.x + (1.0 / max(1e-6, RingsParams.w))) / planet_radius_m;

            float dist_to_center_pr = 1.0;

            float invLightDist = inversesqrt(dot(LightPos[i], LightPos[i]));
            float star_ang_radius = LightParams[i].x * invLightDist;
            float eff_sun_elev = sqrt(sun_elev * sun_elev + 0.18 * star_ang_radius * star_ang_radius);

            float same_hemi = sun_elev * frag_elev;
            float day_face = max(0.0, dot(Normal, sunDir));
            float noon_fade = mix(1.0, 0.4, day_face);
            float lit_factor = 1.3 * noon_fade;
            float unlit_factor = 0.55;
            float hemi_blend = smoothstep(-0.02, 0.02, same_hemi);
            float side_factor = mix(unlit_factor, lit_factor, hemi_blend);

            // Vector pointing from atmosphere fragment toward ring system in sky
            float sign_lat = (Normal.y >= 0.0) ? 1.0 : -1.0;
            vec3 ringLightDir = normalize(Normal * cos_lat - vec3(0.0, sign_lat * sin_lat, 0.0));

            float equinox_fade = smoothstep(0.0001, 0.001745, abs(sun_elev));
            float physical_sun_elev = eff_sun_elev * equinox_fade;

            float shadow_occ = 1.0;
            float NdotLS = dot(Normal, sunDir);
            if (NdotLS < 0.0) {
                // night_depth: 0.0 at terminator -> 1.0 at true midnight
                float night_depth = max(0.0, -NdotLS);
                // Exponent 1.4 + 95% max darkening creates a deep, unmistakably visible shadow with an 5% soft floor
                float dark_curve = pow(night_depth, 1.4);
                shadow_occ = 1.0 - dark_curve * 0.95;
            }

            // Save state for inscatterSky override
            float savedEyeMuS = EyeMuS;
            float savedMieHorFade = MieHorFade;

            // Set state for ring light scattering based on ring's elevation in sky relative to camera
            EyeMuS = clamp(dot(normalize(EyePosM), ringLightDir), 0.05, 1.0);
            MieHorFade = smoothstep(0.0, AtmoParams2.y, EyeMuS);

            // Accumulate light across all 8 ring bands inside single loop
            const int NUM_BANDS = 8;
            vec3 accum_band_light = vec3(0.0);
            vec3 ringLightColor = LightColor[i].rgb * eclFactor;
            for (int band = 0; band < NUM_BANDS; band++) {
                float u = (float(band) + 0.5) / float(NUM_BANDS);
                vec4 ring_sample = textureLod(RingsMap, vec2(u, 0.5), 0.0);

                float r_band = mix(ring_inner_pr, ring_outer_pr, u);
                float band_area = (2.0 * r_band * (ring_outer_pr - ring_inner_pr) / float(NUM_BANDS));
                float dist_sq = r_band * r_band + dist_to_center_pr * dist_to_center_pr;
                float w = (band_area / max(1e-6, dist_sq)) * 0.1;

                float band_brightness = physical_sun_elev * form_factor * w * RingsParams.z * side_factor;
                accum_band_light += ring_sample.rgb * ring_sample.a * ringLightColor * band_brightness;
            }

            // Radiative transfer modulated by shadow
            vec3 total_ring_light = accum_band_light * shadow_occ;

            Inscatter += inscatterSky(ringLightDir) * total_ring_light;

            // Restore state for sun rendering
            EyeMuS = savedEyeMuS;
            MieHorFade = savedMieHorFade;
        }
        #endif
    }

    FragColor = vec4(Inscatter, 0.0);

    // Limit the brightness while preserving color
    float luma = max(FragColor.r, max(FragColor.g, FragColor.b));
    FragColor.rgb *= clamp(65000.0 / (luma + 1.0e-10), 0.0, 1.0);
}

#endif // _FRAGMENT_

//=============================================================================
