#auto_version

//===========================================================================//
//                                                                           //
//                   SpaceEngine ship mesh rendering shader                  //
//                                                                           //
//===========================================================================//

// Defines passed from SpaceEngine. Possible defines:
// Texture maps:      	DETDIF, DETNRM, SPEC, EMIS, TEMP, ASPEC, ATRNS
// Effects:           	ECL, ENVMAP
// Vendor-specific:     INTEL, LOGVS, LOGFS
#auto_defines

#ifdef LOGFS
#extension GL_ARB_conservative_depth : enable
#endif

// Standard defines
#define MAX_LIGHTS   4
#define MAX_ECLIPSES 8
#define PLANCK_TEXTURE

// Normal maps blending methods:
// 0 - linear
// 1 - partial derivatives
// 2 - whiteout
// 3 - Unreal development network
// 4 - reoriented normal mapping
#define NORMALS_BLEND_METHOD 3

//===========================================================================//
//                                                                           //
//                            Texture samplers                               //
//                                                                           //
//===========================================================================//

/*  0 */ uniform sampler2D DiffMap;
/*  1 */ uniform sampler2D NormMap;

#ifdef SPEC
/*  2 */ uniform sampler2D SpecMap;
#endif

#ifdef EMIS
/*  3 */ uniform sampler2D EmisMap;
#endif

#ifdef DETDIF
/*  4 */ uniform sampler2D DetailDiffMap;
#endif

#ifdef DETNRM
/*  5 */ uniform sampler2D DetailNormMap;
#endif

#ifdef ENVMAP
/*  6 */ uniform samplerCube EnvMap;
#endif

#ifdef THERM
/*  7 */ uniform sampler2D TempMap;
/*  8 */ uniform sampler1D PlanckFunction;
#endif

//===========================================================================//
//                                                                           //
//                                Uniforms                                   //
//                                                                           //
//===========================================================================//

//uniform vec4    MeshOffsScale;  // mesh offset, mesh scale
//uniform vec3    UVOffsScale;    // UV offset, UV scale
//uniform mat4x4  ModelViewProj;  // mvp matrix
//uniform vec4    Params;         // model scale, logFactor, alpha fade, exposure
//uniform vec3    EyePos;         // Object-space camera position
//uniform mat3x3  ModuleRotation; // module rotation matrix
//uniform int     NLights;                    // lights count
//uniform vec3    LightPos   [MAX_LIGHTS];    // Object-space light position
//uniform vec3    LightColor [MAX_LIGHTS];    // Light color
//uniform vec3    LightParams[MAX_LIGHTS];    // Light radius, light luminosity, light specular power
//uniform vec4    EclipseCasters[MAX_LIGHTS * MAX_ECLIPSES];
//uniform int     MapCompress;    // bit fields, marking compressed texture maps
//uniform vec4    AmbientParams;  // Ambient color intensity, eclipse shadow intensity, AO scale, Hapke to Lambert lerp
//uniform vec4    HapkeParams;    // Hapke BRDF parameters: (Hapke spot bright, 1 / Hapke spot width, Hapke spot bright CB, 1 / Hapke spot width CB)
//uniform vec4    ThermalParams;  // Max temperature, temperature shift, thermal brightness calibration, ---
//uniform vec3    DiffColorScale; // Diffuse color multiplier
//uniform vec3    DiffColorConst; // Diffuse color constant
//uniform vec4    EmisColor;      // Emissive color, emissive power
//uniform vec4    RMScaleConst;   // Roughness scale, metallness scale, roughness const, metallness const
//uniform vec4    EnvMapParams;   // Envmap resolution, max lod level, 1.0 / EnvMap exposure, ---
//uniform vec4    SpecColorScale; // Specular color multiplier, specular power
//uniform vec4    DetailScale;    // detail diff scale, detail diff mag, detail bump scale, detail bump mag

#uniform_block

#include "texture_mix.glh"

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
layout(location = 1) in  vec3  Normal;
layout(location = 2) in  vec4  Tangent;
layout(location = 3) in  vec2  TexCoord;

// Vertex shader output
out vec4 vPosition;
out vec3 vNormal;
out vec4 vTangent;
out vec2 vTexCoord;

//=============================================================================
// Vertex shader entry point

void main()
{
    // Calculate output position
    vec3 scaledVertexPos = VertexPos * MeshOffsScale.w + MeshOffsScale.xyz;
    gl_Position = ModelViewProj * vec4(scaledVertexPos, 1.0);

    // Logarithmic depth buffer:
    // calculate the per-vertex logarithmic depth value in vertex shader (LOGVS mode),
    // or transfer it to the fragment shader for further per-fragment calculation (LOGFS mode)
	#ifdef LOGVS
        float logz = log2(max(1.0e-6, 1.0 + gl_Position.w)) * Params.y;
        gl_Position.z = (logz - 1.0) * gl_Position.w;
        vPosition.w = logz * 0.5;
	#endif
	#ifdef LOGFS
        vPosition.w = gl_Position.z;
	#endif

    // Transfer vertex position
    vPosition.xyz = scaledVertexPos;

    // Transfer normal
    vNormal = Normal;

    // Transfer tangent and binormal sign
    vTangent = Tangent;
    
    // Transfer main texture coordinates
    vTexCoord = TexCoord;

    // Packed VBO: rescale texture coordinates
    vTexCoord = vTexCoord * UVOffsScale.z + UVOffsScale.xy;
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
in vec3 vNormal;
in vec4 vTangent;
in vec2 vTexCoord;

// Fragment shader output
#ifdef INTEL
out vec4 FragColor;
#else
layout(location = 0) out vec4 FragColor;
#endif

#if (defined(LOGFS) || defined(LOGVS))
layout(depth_less) out float gl_FragDepth;
#endif

//=============================================================================
// Hapke hot spot correction function

float Hapke(float mu)
{
    float  t = sqrt((1.0 - mu) / (1.0 + mu));
    return 1.0 + HapkeParams.x / (1.0 + t * HapkeParams.y) + HapkeParams.z / (1.0 + t * HapkeParams.w);
}

//=============================================================================
// Fragment shader entry point

void main()
{
    // Get diffuse color in rgb and transparency in alpha
    vec4 diffColor = texture(DiffMap, vTexCoord);
    if (bool(MapCompress & MPK_DIFFUSE)) FromYCoCg(diffColor);

    // Alpha test: discard pixel if alpha < 0.5
    #ifdef ATRNS
        if (diffColor.a < 0.5) discard;
    #endif

    // Modulate diffuse color
    diffColor.rgb = diffColor.rgb * DiffColorScale + DiffColorConst;

    // Logarithmic depth buffer:
    // calculate the per-pixel logarithmic depth value (DEPTH_BUFFER_LOG_FS mode)
    #ifdef LOGVS
        gl_FragDepth = vPosition.w;
    #endif
    #ifdef LOGFS
        gl_FragDepth = log2(1.0 + vPosition.w) * Params.y;
    #endif

    // Get normal
    vec3  Normal = normalize(vNormal);

    // Flip normal for back faces
    #ifdef ALPHA_TRANSP 
        if (gl_FrontFacing == false) // ATI driver don't understand !gl_FrontFacing
            Normal = -Normal;
    #endif

    // Get the normal map and/or detail normal map vector, expanded from [0, 1] to [-1, 1]
    vec4  bumpData = texture(NormMap, vTexCoord);
    vec3  normVec  = 2.0 * bumpData.xyz - NORM_ONE;
    if (bool(MapCompress & MPK_NORMAL)) FromBC5(normVec);

    #ifdef DETNRM
        //vec3 detNormVec = 2.0 * texture(DetailNormMap, vTexCoord * DetailScale.z).xyz - NORM_ONE;
        vec3 detNormVec0 = 2.0 * texture(DetailNormMap, vTexCoord * DetailScale.z      ).xyz - NORM_ONE;
        if (bool(MapCompress & MPK_DET_NORM)) FromBC5(detNormVec0);

        vec3 detNormVec1 = 2.0 * texture(DetailNormMap, vTexCoord * DetailScale.z * 4.0).xyz - NORM_ONE;
        if (bool(MapCompress & MPK_DET_NORM)) FromBC5(detNormVec1);

        vec3 detNormVec = BlendNormals(detNormVec0, detNormVec1, 0.5);
        normVec = BlendNormals(normVec, detNormVec, DetailScale.w);
    #else
        normVec = normalize(normVec);
    #endif

    // Get tangent, binormal and matrix of transformation to the tangent space
    vec3   Tangent  = /*vTangent.w */ normalize(vTangent.xyz);
    vec3   Binormal = vTangent.w * cross(Tangent, Normal);
	mat3x3 Rotation = mat3x3(Tangent, Binormal, Normal);

    // Convert the normal map vector to the world space
    normVec = Rotation * normVec;

    // Get the fragment position
    vec3  FragPos = vPosition.xyz * Params.x;

    // Calculate the eye vector in the object space
    vec3  eyeVec = normalize(FragPos - EyePos);

    float cosO = clamp(-dot(normVec, eyeVec), 0.001, 1.0);

    // Calculate light vectors in the object space
    vec3  LightPosS[MAX_LIGHTS];
    vec3  lightVec [MAX_LIGHTS];
    for (int i=0; i<NLights; i++)
    {
        LightPosS[i] = LightPos[i] - FragPos;
        lightVec [i] = normalize(LightPosS[i]);
    }

    // Calculate lighting value, mix between the Lambert and Hapke models
    vec3 sunLight[MAX_LIGHTS];
    for (int i=0; i<NLights; i++)
    {
        // Lambert BRDF
        float cosI = clamp(dot(normVec, lightVec[i]), 0.0, 1.0);

        // Simplified Hapke BRDF
        float mu = clamp(-dot(lightVec[i], eyeVec), -0.999, 1.0);
        float litFactor = cosI / (cosI + cosO) * Hapke(mu);

        // Mix between Lambert and Hapke models
        litFactor = mix(cosI, litFactor, AmbientParams.w);

        sunLight[i] = LightColor[i].rgb * litFactor;
    }

    // Calculate eclipse shadows
    #ifdef ECL
        for (int i=0; i<NLights; i++) 
        {
            float lightAngularRadius = asin(LightParams[i].x * inversesqrt(dot(LightPosS[i], LightPosS[i])));
            float Shadow = 1.0 - AmbientParams.y * EclipseShadowFar(i, MAX_ECLIPSES, FragPos, lightVec[i], lightAngularRadius);
            sunLight[i] *= Shadow;
        }
    #endif

    // Get detail diffuse color in rgb and specular intensity in alpha
    #ifdef DETDIF
        //diffColor = (diffColor + texture(DetailDiffMap, vTexCoord * DetailScale.x)) * 0.5;
        //diffColor = diffColor * (0.5 + 0.5 * texture(DetailDiffMap, vTexCoord * DetailScale.x * 8.0)) * 2.0;
        
        vec4 detColor0 = mix(vec4(0.5), texture(DetailDiffMap, vTexCoord * DetailScale.x      ), DetailScale.y);
        if (bool(MapCompress & MPK_DET_DIFF)) FromYCoCg(detColor0);

        vec4 detColor1 = mix(vec4(0.5), texture(DetailDiffMap, vTexCoord * DetailScale.x * 4.0), DetailScale.y);
        if (bool(MapCompress & MPK_DET_DIFF)) FromYCoCg(detColor1);

        diffColor = diffColor * detColor0 * detColor1 * (4.0 + 6.0 * DetailScale.y * DetailScale.y);
    #endif

    // Get the hull color modulated by illumination
    vec3 hullColor = vec3(0.0);
    for (int i=0; i<NLights; i++) 
        hullColor += sunLight[i];
    hullColor *= diffColor.rgb;

    // Calculate the specular color
    #if (defined(SPEC) || defined(ASPEC) || defined(ENVMAP))

        // Get specular color in rgb and specular power in alpha
        vec4 specColor;
        #if (defined(SPEC) && !defined(ASPEC))
            specColor = texture(SpecMap, vTexCoord);
        #elif (defined(SPEC) && defined(ASPEC))
            specColor = texture(SpecMap, vTexCoord) + diffColor;
        #else
            specColor = diffColor;
        #endif

        specColor.a *= SpecColorScale.a;

        vec3  specLightColor = vec3(0.0);

        // Calculate specular highlight
        for (int i=0; i<NLights; i++)
        {
            vec3 halfVec = normalize(lightVec[i] - eyeVec);
            float specPower = max(specColor.a * LightParams[i].z, 1.0);
            specLightColor += (specPower * 0.039788735 + 0.31830989) * pow(clamp(dot(halfVec, normVec), 0.0, 1.0), specPower) * sunLight[i];
        }

        // Calculate the reflection color
        #ifdef ENVMAP
            vec3 reflVec = ModuleRotation * reflect(eyeVec, normVec);
            specLightColor += texture(EnvMap, reflVec).rgb * EnvMapParams.z;
        #endif

        hullColor += SpecColorScale.rgb * specColor.rgb * specLightColor;

    #endif // (defined(SPEC) || defined(ASPEC) || defined(ENVMAP))

    // Get emissive color in rgb and emissive power in alpha
    #ifdef EMIS
        vec4  emisColor = texture(EmisMap, vTexCoord);
        if (bool(MapCompress & MPK_EMISSION)) FromYCoCg(emisColor);
        hullColor += EmisColor.rgb * emisColor.rgb;
    #endif
	
	// Calculate thermal emission color
	#ifdef THERM
		vec4   tempData = texture(TempMap, vTexCoord);
		if (bool(MapCompress & MPK_THERMAL)) FromYCoCg(tempData);
		
        float  surfTemp = tempData.r * ThermalParams.x;
		
		// Get thermal emission color by sampling the Planck function texture
		vec3 glowColorTherm = texture(PlanckFunction, log(surfTemp + ThermalParams.y) * 0.188 + 0.1316).rgb;
		
        hullColor.rgb += glowColorTherm * ThermalParams.z * 500.0;
	#endif

    // Calculate the result color
    FragColor.rgb = (AmbientParams.xxx * diffColor.rgb + hullColor) * Params.w;
    FragColor.a = Params.z;

    // Limit the brightness while preserving color
    float luma = max(FragColor.r, max(FragColor.g, FragColor.b));
    FragColor.rgb *= clamp(65000.0 / (luma + 1.0e-10), 0.0, 1.0);

    //bumpData = texture(NormMap, vTexCoord);
    //FragColor.rgb = bumpData.rgb;
    //FragColor.rgb = normVec;
    //FragColor.rgb = Normal * 0.5 + 0.5;
    //FragColor.rgb = Tangent;
    //FragColor.rgb = Binormal;
    //FragColor.rg  = vTexCoord;

/*#ifdef ENVMAP
    vec3 reflVec2 = ModuleRotation * reflect(eyeVec, normVec);
    FragColor.rgb = texture(EnvMap, reflVec2).rgb * EnvMapParams.z;
    //FragColor.rgb = reflVec2;
#endif*/
}

#endif // _FRAGMENT_

//=============================================================================
