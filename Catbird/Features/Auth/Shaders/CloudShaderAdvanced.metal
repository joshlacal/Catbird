#include <metal_stdlib>
using namespace metal;

// Hyper-realistic volumetric cloud shader with advanced ray tracing
struct VertexOut {
    float4 position [[position]];
    float2 texCoord;
    float2 screenPos;
};

struct CloudUniforms {
    float time;
    float2 resolution;
    float opacity;
    float4 lightModeColor;
    float4 darkModeColor;
    bool isDarkMode;
    float cloudScale;
    float animationSpeed;
    float3 padding; // For alignment
};

// Enhanced ray marching parameters for ultra-quality
constant int MAX_STEPS = 128;
constant float MAX_DISTANCE = 50.0;
constant float EPSILON = 0.0001;
constant int LIGHT_STEPS = 16;
constant float CLOUD_BASE = 1.5;
constant float CLOUD_TOP = 12.0;

// Advanced 3D Perlin noise for hyper-realistic clouds
float hash3(float3 p) {
    p = fract(p * float3(443.897, 441.423, 437.195));
    p += dot(p, p.yxz + 19.19);
    return fract((p.x + p.y) * p.z);
}

float3 hash3vec(float3 p) {
    p = float3(dot(p, float3(127.1, 311.7, 74.7)),
               dot(p, float3(269.5, 183.3, 246.1)),
               dot(p, float3(113.5, 271.9, 124.6)));
    return -1.0 + 2.0 * fract(sin(p) * 43758.5453123);
}

// Gradient noise for smoother, more realistic results
float gradientNoise3D(float3 p) {
    float3 i = floor(p);
    float3 f = fract(p);
    
    // Quintic interpolation for ultra-smooth results
    float3 u = f * f * f * (f * (f * 6.0 - 15.0) + 10.0);
    
    // Calculate gradients at cube corners
    float3 g000 = hash3vec(i + float3(0,0,0));
    float3 g001 = hash3vec(i + float3(0,0,1));
    float3 g010 = hash3vec(i + float3(0,1,0));
    float3 g011 = hash3vec(i + float3(0,1,1));
    float3 g100 = hash3vec(i + float3(1,0,0));
    float3 g101 = hash3vec(i + float3(1,0,1));
    float3 g110 = hash3vec(i + float3(1,1,0));
    float3 g111 = hash3vec(i + float3(1,1,1));
    
    // Calculate dot products
    float n000 = dot(g000, f - float3(0,0,0));
    float n001 = dot(g001, f - float3(0,0,1));
    float n010 = dot(g010, f - float3(0,1,0));
    float n011 = dot(g011, f - float3(0,1,1));
    float n100 = dot(g100, f - float3(1,0,0));
    float n101 = dot(g101, f - float3(1,0,1));
    float n110 = dot(g110, f - float3(1,1,0));
    float n111 = dot(g111, f - float3(1,1,1));
    
    // Trilinear interpolation
    float x00 = mix(n000, n100, u.x);
    float x01 = mix(n001, n101, u.x);
    float x10 = mix(n010, n110, u.x);
    float x11 = mix(n011, n111, u.x);
    float y0 = mix(x00, x10, u.y);
    float y1 = mix(x01, x11, u.y);
    
    return mix(y0, y1, u.z);
}

// Advanced 3D Worley noise for cloud cell structure
float worley3D(float3 p) {
    float3 n = floor(p);
    float3 f = fract(p);
    
    float minDist = 1.0;
    float secondDist = 1.0;
    
    for (int x = -1; x <= 1; x++) {
        for (int y = -1; y <= 1; y++) {
            for (int z = -1; z <= 1; z++) {
                float3 neighbor = float3(float(x), float(y), float(z));
                float3 point = hash3vec(n + neighbor) * 0.5 + 0.5;
                float3 diff = neighbor + point - f;
                float dist = length(diff);
                
                if (dist < minDist) {
                    secondDist = minDist;
                    minDist = dist;
                } else if (dist < secondDist) {
                    secondDist = dist;
                }
            }
        }
    }
    
    return minDist;
}

// Ultra-high quality FBM with domain warping
float fbm3D(float3 p, int octaves, float persistence = 0.5, float lacunarity = 2.0) {
    float value = 0.0;
    float amplitude = 0.5;
    float frequency = 1.0;
    float maxValue = 0.0;
    
    // Domain warping for more realistic turbulence
    float3 warp = float3(0.0);
    
    for (int i = 0; i < octaves; i++) {
        float3 pp = p * frequency + warp;
        float noise = gradientNoise3D(pp);
        
        // Add some high-frequency detail
        if (i > 2) {
            noise = abs(noise);
            noise = 1.0 - noise;
            noise = noise * noise;
        }
        
        value += amplitude * noise;
        maxValue += amplitude;
        
        // Update warping
        warp += float3(noise * 0.1, noise * 0.05, noise * 0.08);
        
        amplitude *= persistence;
        frequency *= lacunarity;
        
        // Rotate coordinates for each octave
        p = p * float3x3(0.8, -0.6, 0.0,
                        0.6, 0.8, 0.0,
                        0.0, 0.0, 1.0);
    }
    
    return value / maxValue;
}

// Hyper-realistic cloud density with physical properties
float getCloudDensity(float3 pos, float time, float scale) {
    // Realistic wind simulation with turbulence
    float windSpeed = 0.03;
    float3 baseWind = float3(time * windSpeed, 0.0, time * windSpeed * 0.3);
    float3 turbulence = float3(
        sin(pos.x * 0.1 + time * 0.2) * 0.2,
        cos(pos.z * 0.15 + time * 0.15) * 0.1,
        sin(pos.y * 0.1 + time * 0.1) * 0.15
    );
    pos += baseWind + turbulence;
    
    // Height relative to cloud layer
    float heightPercent = (pos.y - CLOUD_BASE) / (CLOUD_TOP - CLOUD_BASE);
    heightPercent = saturate(heightPercent);
    
    // Different cloud types at different heights
    float stratusInfluence = saturate(1.0 - abs(heightPercent - 0.2) * 5.0);
    float cumulusInfluence = saturate(1.0 - abs(heightPercent - 0.5) * 3.0);
    float cirrusInfluence = saturate((heightPercent - 0.7) * 3.0);
    
    float density = 0.0;
    
    // Stratus - flat, layered clouds
    if (stratusInfluence > 0.0) {
        float stratus = fbm3D(pos * float3(0.5, 2.0, 0.5) * scale, 4, 0.7, 2.0);
        stratus = smoothstep(0.4, 0.6, stratus);
        density += stratus * stratusInfluence * 0.4;
    }
    
    // Cumulus - puffy, cotton-like clouds
    if (cumulusInfluence > 0.0) {
        // Large billowing structures
        float cumulus = 1.0 - worley3D(pos * 0.05 * scale);
        cumulus = pow(cumulus, 2.0);
        
        // Add turbulent detail
        float detail = fbm3D(pos * 0.2 * scale, 6, 0.45, 2.2);
        cumulus *= (0.5 + detail * 0.5);
        
        // Shape with height profile
        float cumulusProfile = smoothstep(0.0, 0.2, heightPercent) * smoothstep(1.0, 0.6, heightPercent);
        cumulus *= cumulusProfile;
        
        density += cumulus * cumulusInfluence * 0.8;
    }
    
    // Cirrus - wispy, high-altitude clouds
    if (cirrusInfluence > 0.0) {
        float cirrus = fbm3D(pos * float3(0.1, 0.05, 0.1) * scale, 5, 0.6, 2.0);
        cirrus = pow(cirrus, 3.0);
        density += cirrus * cirrusInfluence * 0.3;
    }
    
    // Additional detail and erosion
    float erosion = fbm3D(pos * 0.4 * scale, 4, 0.4, 2.5);
    erosion = smoothstep(0.3, 0.7, erosion);
    density *= (0.7 + erosion * 0.3);
    
    // Coverage adjustment
    density = smoothstep(0.2, 0.8, density);
    
    // Final shaping
    float edgeFalloff = 1.0 - smoothstep(CLOUD_BASE - 0.5, CLOUD_BASE, pos.y);
    edgeFalloff *= smoothstep(CLOUD_TOP, CLOUD_TOP + 0.5, pos.y);
    density *= edgeFalloff;
    
    return saturate(density);
}

// Henyey-Greenstein phase function for realistic light scattering
float henyeyGreenstein(float cosTheta, float g) {
    float g2 = g * g;
    float num = 1.0 - g2;
    float denom = 4.0 * 3.14159265 * pow(1.0 + g2 - 2.0 * g * cosTheta, 1.5);
    return num / denom;
}

// Advanced atmospheric scattering
float3 atmosphericScattering(float3 viewDir, float3 lightDir, float height) {
    // Rayleigh scattering for blue sky
    float rayleighPhase = 0.75 * (1.0 + dot(viewDir, lightDir) * dot(viewDir, lightDir));
    float3 rayleighColor = float3(0.5, 0.7, 1.0) * rayleighPhase;
    
    // Mie scattering for sun glow
    float miePhase = henyeyGreenstein(dot(viewDir, lightDir), 0.8);
    float3 mieColor = float3(1.0, 0.9, 0.7) * miePhase;
    
    // Height-based blending
    float heightFactor = exp(-height * 0.1);
    return mix(rayleighColor, mieColor, heightFactor);
}

// Enhanced ray marching with multiple scattering and volumetric shadows
float4 rayMarchClouds(float3 rayOrigin, float3 rayDir, CloudUniforms uniforms) {
    // Deep fall blue sky color
    float3 skyColorTop = float3(0.15, 0.25, 0.6);    // Deep blue at zenith
    float3 skyColorHorizon = float3(0.4, 0.5, 0.75); // Lighter blue at horizon
    
    // Calculate sun position for realistic lighting
    float sunAngle = uniforms.time * 0.005 + 1.0;
    float3 sunDir = normalize(float3(cos(sunAngle) * 0.8, 0.6 + sin(sunAngle) * 0.3, sin(sunAngle) * 0.8));
    
    // Sky gradient based on view direction
    float skyGradient = dot(rayDir, float3(0, 1, 0)) * 0.5 + 0.5;
    float3 skyColor = mix(skyColorHorizon, skyColorTop, pow(skyGradient, 0.5));
    
    // Initialize accumulation variables
    float3 scatteredLight = float3(0.0);
    float3 transmittance = float3(1.0);
    float accumDensity = 0.0;
    
    // Adaptive step size based on distance
    float t = 0.0;
    float stepSize = 0.1;
    
    for (int i = 0; i < MAX_STEPS && t < MAX_DISTANCE; i++) {
        float3 pos = rayOrigin + rayDir * t;
        
        // Skip if below or above cloud layer
        if (pos.y < CLOUD_BASE - 0.5 || pos.y > CLOUD_TOP + 0.5) {
            t += stepSize * 2.0;
            continue;
        }
        
        float density = getCloudDensity(pos, uniforms.time * uniforms.animationSpeed, uniforms.cloudScale);
        
        if (density > 0.001) {
            // Calculate lighting with enhanced shadows
            float3 lightEnergy = float3(0.0);
            float shadowDensity = 0.0;
            
            // Primary light ray marching for shadows
            for (int j = 0; j < LIGHT_STEPS; j++) {
                float3 lightPos = pos + sunDir * float(j) * 0.5;
                float lightSample = getCloudDensity(lightPos, uniforms.time * uniforms.animationSpeed, uniforms.cloudScale);
                shadowDensity += lightSample;
            }
            
            // Beer-Lambert law for light absorption
            float3 directLight = exp(-shadowDensity * float3(0.8, 0.85, 1.0));
            
            // Multiple scattering approximation
            float scatterStrength = 1.0 - exp(-density * 5.0);
            float3 ambientLight = skyColor * 0.6 * scatterStrength;
            
            // Powder effect for realistic cloud appearance
            float powder = 1.0 - exp(-density * 2.0);
            directLight = mix(directLight, float3(1.0), powder * 0.4);
            
            // Silver lining at cloud edges
            float edgeDensity = 1.0 - smoothstep(0.0, 0.1, density);
            float silverLining = pow(edgeDensity, 3.0) * max(0.0, dot(sunDir, rayDir));
            
            // Crystal white cloud color
            float3 cloudAlbedo = float3(1.0, 1.0, 1.0); // Pure white
            
            // Combine lighting
            lightEnergy = cloudAlbedo * (directLight * 1.2 + ambientLight);
            lightEnergy += float3(1.0, 0.98, 0.95) * silverLining * 2.0;
            
            // Apply atmospheric scattering
            float3 scattering = atmosphericScattering(-rayDir, sunDir, pos.y);
            lightEnergy += scattering * 0.1 * density;
            
            // Subsurface scattering for cloud translucency
            float phase = henyeyGreenstein(dot(rayDir, sunDir), 0.6);
            lightEnergy += cloudAlbedo * phase * directLight * 0.3;
            
            // Energy-conserving integration
            float3 energyAbsorbed = (1.0 - exp(-density * stepSize * 4.0)) * transmittance;
            scatteredLight += lightEnergy * energyAbsorbed;
            transmittance *= exp(-density * stepSize * 4.0);
            
            accumDensity += density * stepSize;
            
            // Early termination
            if (all(transmittance < 0.01)) break;
        }
        
        // Adaptive stepping - smaller steps in dense regions
        stepSize = mix(0.1, 0.5, 1.0 - density);
        t += stepSize;
    }
    
    // Mix with sky color based on transmittance
    float3 finalColor = skyColor * transmittance + scatteredLight;
    
    // High dynamic range to low dynamic range conversion
    finalColor = finalColor / (1.0 + finalColor); // Reinhard tone mapping
    
    // Subtle color grading for photorealism
    finalColor = pow(finalColor, float3(0.85, 0.88, 0.95)); // Slight blue tint
    
    // Calculate alpha based on density
    float alpha = 1.0 - dot(transmittance, float3(0.333));
    alpha = saturate(alpha * uniforms.opacity);
    
    return float4(finalColor, alpha);
}

vertex VertexOut cloud_vertex_advanced(uint vertexID [[vertex_id]]) {
    float2 quadPositions[4] = {
        float2(-1.0, -1.0),
        float2( 1.0, -1.0),
        float2(-1.0,  1.0),
        float2( 1.0,  1.0)
    };
    
    float2 quadTexCoords[4] = {
        float2(0.0, 1.0),
        float2(1.0, 1.0),
        float2(0.0, 0.0),
        float2(1.0, 0.0)
    };
    
    VertexOut out;
    out.position = float4(quadPositions[vertexID], 0.0, 1.0);
    out.texCoord = quadTexCoords[vertexID];
    out.screenPos = quadPositions[vertexID];
    return out;
}

fragment float4 cloud_fragment_advanced(VertexOut in [[stage_in]],
                                       constant CloudUniforms& uniforms [[buffer(0)]]) {
    // Enhanced camera setup for more realistic perspective
    float2 uv = in.texCoord;
    float2 ndc = uv * 2.0 - 1.0;
    
    // Aspect ratio correction
    float aspectRatio = uniforms.resolution.x / uniforms.resolution.y;
    ndc.x *= aspectRatio;
    
    // Camera parameters
    float3 cameraPos = float3(0.0, 2.0, -5.0);
    float3 cameraTarget = float3(0.0, 4.0, 0.0);
    float3 cameraUp = float3(0.0, 1.0, 0.0);
    
    // Calculate camera matrix
    float3 forward = normalize(cameraTarget - cameraPos);
    float3 right = normalize(cross(forward, cameraUp));
    float3 up = cross(right, forward);
    
    // Field of view
    float fov = 60.0 * 3.14159265 / 180.0;
    float tanHalfFov = tan(fov * 0.5);
    
    // Calculate ray direction with realistic camera projection
    float3 rayDir = normalize(
        forward + 
        right * ndc.x * tanHalfFov + 
        up * ndc.y * tanHalfFov
    );
    
    // Slight camera movement for dynamic feel
    float3 cameraOffset = float3(
        sin(uniforms.time * 0.01) * 0.5,
        cos(uniforms.time * 0.008) * 0.2,
        0.0
    );
    float3 rayOrigin = cameraPos + cameraOffset;
    
    // Ray march through the volumetric clouds
    float4 cloudResult = rayMarchClouds(rayOrigin, rayDir, uniforms);
    
    // Post-processing for photorealism
    float3 color = cloudResult.rgb;
    
    // Subtle vignetting
    float vignette = 1.0 - length(uv - 0.5) * 0.3;
    color *= vignette;
    
    // Slight chromatic aberration for lens realism
    if (length(ndc) > 0.5) {
        float2 caOffset = ndc * 0.002;
        float3 caRayDir = normalize(
            forward + 
            right * (ndc.x + caOffset.x) * tanHalfFov + 
            up * ndc.y * tanHalfFov
        );
        float3 caBRayDir = normalize(
            forward + 
            right * (ndc.x - caOffset.x) * tanHalfFov + 
            up * ndc.y * tanHalfFov
        );
        
        // Only sample chromatic aberration on cloud edges for performance
        if (cloudResult.a > 0.1 && cloudResult.a < 0.9) {
            float4 caR = rayMarchClouds(rayOrigin, caRayDir, uniforms);
            float4 caB = rayMarchClouds(rayOrigin, caBRayDir, uniforms);
            color.r = mix(color.r, caR.r, 0.3);
            color.b = mix(color.b, caB.b, 0.3);
        }
    }
    
    // Film grain for photographic quality
    float grain = hash3(float3(in.texCoord * uniforms.resolution, uniforms.time * 1000.0));
    color += (grain - 0.5) * 0.015;
    
    // Final color grading - emphasize the deep blue sky
    color = pow(color, float3(0.9, 0.92, 0.98)); // Enhance blues
    color = mix(color, color * float3(0.9, 0.95, 1.0), 0.3); // Cool tint
    
    // Ensure we maintain the alpha channel
    return float4(saturate(color), cloudResult.a);
}