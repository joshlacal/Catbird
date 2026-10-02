#include <metal_stdlib>
using namespace metal;

// Vertex shader input structure (not used in vertex ID-based rendering)
struct VertexIn {
    float2 position;
    float2 texCoord;
};

// Vertex shader output / Fragment shader input
struct VertexOut {
    float4 position [[position]];
    float2 texCoord;
    float2 screenPos;
};

// Uniform data passed from SwiftUI
struct CloudUniforms {
    float time;
    float2 resolution;
    float opacity;
    float4 lightModeColor;
    float4 darkModeColor;
    bool isDarkMode;
    float cloudScale;
    float animationSpeed;
};

// Vertex shader - simplified for vertex ID based rendering
vertex VertexOut cloud_vertex(uint vertexID [[vertex_id]]) {
    // Create vertices for a full-screen quad using vertex ID
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

// Cloud parameters
constant float cloudscale = 1.1;
constant float speed = 0.03;
constant float clouddark = 0.5;
constant float cloudlight = 0.3;
constant float cloudcover = 0.2;
constant float cloudalpha = 8.0;
constant float skytint = 0.5;

constant float2x2 m = float2x2(1.6, 1.2, -1.2, 1.6);

float2 hash(float2 p) {
    p = float2(dot(p, float2(127.1, 311.7)), dot(p, float2(269.5, 183.3)));
    return -1.0 + 2.0 * fract(sin(p) * 43758.5453123);
}

float noise(float2 p) {
    float K1 = 0.366025404; // (sqrt(3)-1)/2;
    float K2 = 0.211324865; // (3-sqrt(3))/6;
    float2 i = floor(p + (p.x + p.y) * K1);
    float2 a = p - i + (i.x + i.y) * K2;
    float2 o = (a.x > a.y) ? float2(1.0, 0.0) : float2(0.0, 1.0);
    float2 b = a - o + K2;
    float2 c = a - 1.0 + 2.0 * K2;
    float3 h = max(0.5 - float3(dot(a, a), dot(b, b), dot(c, c)), 0.0);
    float3 n = h * h * h * h * float3(dot(a, hash(i + 0.0)), dot(b, hash(i + o)), dot(c, hash(i + 1.0)));
    return dot(n, float3(70.0));
}

float fbm(float2 n) {
    float total = 0.0, amplitude = 0.1;
    for (int i = 0; i < 5; i++) {  // Reduced from 7 - imperceptible for slow clouds
        total += noise(n) * amplitude;
        n = m * n;
        amplitude *= 0.4;
    }
    return total;
}

// Fragment shader inspired by shadertoy clouds
fragment float4 cloud_fragment(VertexOut in [[stage_in]],
                              constant CloudUniforms& uniforms [[buffer(0)]]) {
    
    float2 p = in.texCoord;
    float2 uv = p * float2(uniforms.resolution.x / uniforms.resolution.y, 1.0);
    float time = uniforms.time * speed * uniforms.animationSpeed;
    float q = fbm(uv * cloudscale * 0.5);
    
    // Ridged noise shape - reduced iterations for performance
    float r = 0.0;
    uv *= cloudscale;
    uv -= q - time;
    float weight = 0.8;
    for (int i = 0; i < 6; i++) {  // Reduced from 8
        r += abs(weight * noise(uv));
        uv = m * uv + time;
        weight *= 0.7;
    }

    // Noise shape - reduced iterations for performance
    float f = 0.0;
    uv = p * float2(uniforms.resolution.x / uniforms.resolution.y, 1.0);
    uv *= cloudscale;
    uv -= q - time;
    weight = 0.7;
    for (int i = 0; i < 6; i++) {  // Reduced from 8
        f += weight * noise(uv);
        uv = m * uv + time;
        weight *= 0.6;
    }
    
    f *= r + f;
    
    // Noise colour - reduced iterations
    float c = 0.0;
    time = uniforms.time * speed * 2.0 * uniforms.animationSpeed;
    uv = p * float2(uniforms.resolution.x / uniforms.resolution.y, 1.0);
    uv *= cloudscale * 2.0;
    uv -= q - time;
    weight = 0.4;
    for (int i = 0; i < 5; i++) {  // Reduced from 7
        c += weight * noise(uv);
        uv = m * uv + time;
        weight *= 0.6;
    }

    // Noise ridge colour - reduced iterations
    float c1 = 0.0;
    time = uniforms.time * speed * 3.0 * uniforms.animationSpeed;
    uv = p * float2(uniforms.resolution.x / uniforms.resolution.y, 1.0);
    uv *= cloudscale * 3.0;
    uv -= q - time;
    weight = 0.4;
    for (int i = 0; i < 5; i++) {  // Reduced from 7
        c1 += abs(weight * noise(uv));
        uv = m * uv + time;
        weight *= 0.6;
    }
    
    c += c1;
    
    // Sky colors matching your deep blue fall sky
    float3 skycolour1 = float3(0.12, 0.25, 0.65); // Deep fall blue
    float3 skycolour2 = float3(0.35, 0.50, 0.80); // Lighter horizon blue
    float3 skycolour = mix(skycolour2, skycolour1, p.y);
    
    // Pure white clouds
    float3 cloudcolour = float3(1.0, 1.0, 1.0) * clamp((clouddark + cloudlight * c), 0.0, 1.0);
    
    f = cloudcover + cloudalpha * f * r;
    
    float3 result = mix(skycolour, clamp(skytint * skycolour + cloudcolour, 0.0, 1.0), clamp(f + c, 0.0, 1.0));
    
    // Fully opaque like original Shadertoy
    return float4(result, 1.0);
}

// MARK: - Improved Shader Variants (Enhanced Performance & Quality)

// Improved vertex shader with better interpolation
vertex VertexOut cloud_vertex_improved(uint vertexID [[vertex_id]]) {
    // Create vertices for a full-screen quad using vertex ID
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

// Improved noise function with better distribution
float noise_improved(float2 p) {
    float K1 = 0.366025404; // (sqrt(3)-1)/2;
    float K2 = 0.211324865; // (3-sqrt(3))/6;
    float2 i = floor(p + (p.x + p.y) * K1);
    float2 a = p - i + (i.x + i.y) * K2;
    float2 o = step(a.y, a.x) ? float2(1.0, 0.0) : float2(0.0, 1.0);
    float2 b = a - o + K2;
    float2 c = a - 1.0 + 2.0 * K2;
    float3 h = max(0.5 - float3(dot(a, a), dot(b, b), dot(c, c)), 0.0);
    float3 n = h * h * h * h * float3(dot(a, hash(i + 0.0)), dot(b, hash(i + o)), dot(c, hash(i + 1.0)));
    return dot(n, float3(70.0));
}

// Improved FBM with better octave scaling
float fbm_improved(float2 n) {
    float total = 0.0, amplitude = 0.5;
    float frequency = 1.0;
    for (int i = 0; i < 6; i++) {
        total += noise_improved(n * frequency) * amplitude;
        amplitude *= 0.5;
        frequency *= 2.0;
    }
    return total;
}

// Improved fragment shader with better cloud formation
fragment float4 cloud_fragment_improved(VertexOut in [[stage_in]],
                                        constant CloudUniforms& uniforms [[buffer(0)]]) {
    
    float2 p = in.texCoord;
    float2 uv = p * float2(uniforms.resolution.x / uniforms.resolution.y, 1.0);
    float time = uniforms.time * speed * uniforms.animationSpeed * 0.8;
    
    // Enhanced cloud layers
    float q = fbm_improved(uv * cloudscale * uniforms.cloudScale * 0.4);
    
    // More realistic cloud formation
    float r = 0.0;
    uv *= cloudscale * uniforms.cloudScale;
    uv -= q - time * 0.7;
    float weight = 0.7;
    for (int i = 0; i < 6; i++) {
        r += abs(weight * noise_improved(uv));
        uv = m * uv + time * 0.3;
        weight *= 0.6;
    }
    
    // Softer noise shape
    float f = 0.0;
    uv = p * float2(uniforms.resolution.x / uniforms.resolution.y, 1.0);
    uv *= cloudscale * uniforms.cloudScale;
    uv -= q - time * 0.5;
    weight = 0.6;
    for (int i = 0; i < 6; i++) {
        f += weight * noise_improved(uv);
        uv = m * uv + time * 0.2;
        weight *= 0.55;
    }
    
    f *= r + f * 0.8;
    
    // Enhanced sky colors with better gradient
    float3 skycolour1 = float3(0.10, 0.22, 0.62); // Deep blue
    float3 skycolour2 = float3(0.38, 0.52, 0.82); // Horizon blue
    float3 skycolour3 = float3(0.25, 0.35, 0.75); // Mid blue
    
    float gradient = smoothstep(0.0, 1.0, p.y);
    float3 skycolour = mix(skycolour2, mix(skycolour3, skycolour1, gradient * 0.7), gradient);
    
    // Better cloud coloring with subtle variations
    float3 cloudcolour = float3(0.98, 0.99, 1.0) * clamp((clouddark * 0.8 + cloudlight * 1.2 * f), 0.0, 1.0);
    
    f = cloudcover * 0.8 + cloudalpha * 0.9 * f * r;
    
    float3 result = mix(skycolour, clamp(skytint * 0.9 * skycolour + cloudcolour, 0.0, 1.0), clamp(f, 0.0, 1.0));
    
    // Fully opaque like original Shadertoy
    return float4(result, 1.0);
}

// MARK: - Advanced Shader Variants (High Quality & Advanced Effects)

// Advanced vertex shader (same as improved for now)
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

// Advanced noise with curl noise for more realistic cloud patterns
float2 curl_noise(float2 p) {
    const float eps = 0.1;
    float n1 = noise(p + float2(eps, 0.0));
    float n2 = noise(p + float2(0.0, eps));
    float n3 = noise(p - float2(eps, 0.0));
    float n4 = noise(p - float2(0.0, eps));
    
    float2 curl = float2(n2 - n4, n3 - n1) / (2.0 * eps);
    return curl;
}

// Simplified advanced FBM for performance
float fbm_advanced(float2 n, float time) {
    float total = 0.0, amplitude = 0.5;
    float frequency = 1.0;
    
    for (int i = 0; i < 4; i++) { // Reduced from 8 to 4 iterations
        total += noise(n * frequency + time * 0.05) * amplitude;
        amplitude *= 0.5;
        frequency *= 2.0;
    }
    return total;
}

// Advanced fragment shader with volumetric-like effects
fragment float4 cloud_fragment_advanced(VertexOut in [[stage_in]],
                                        constant CloudUniforms& uniforms [[buffer(0)]]) {
    
    float2 p = in.texCoord;
    float2 uv = p * float2(uniforms.resolution.x / uniforms.resolution.y, 1.0);
    float time = uniforms.time * speed * uniforms.animationSpeed * 0.6;
    
    // Multi-layer cloud system
    float q1 = fbm_advanced(uv * cloudscale * uniforms.cloudScale * 0.3, time);
    float q2 = fbm_advanced(uv * cloudscale * uniforms.cloudScale * 0.6, time * 1.5);
    float q3 = fbm_advanced(uv * cloudscale * uniforms.cloudScale * 1.2, time * 0.8);
    
    // Combine layers for complex cloud structure
    float combined_q = (q1 * 0.5 + q2 * 0.3 + q3 * 0.2);
    
    // Advanced cloud formation with multiple octaves
    float r = 0.0;
    uv *= cloudscale * uniforms.cloudScale;
    uv -= combined_q - time * 0.4;
    float weight = 0.8;
    for (int i = 0; i < 8; i++) {
        float2 curl = curl_noise(uv) * 0.05;
        r += abs(weight * noise(uv + curl));
        uv = m * uv + time * 0.15;
        weight *= 0.65;
    }
    
    // Detailed cloud structure
    float f = 0.0;
    uv = p * float2(uniforms.resolution.x / uniforms.resolution.y, 1.0);
    uv *= cloudscale * uniforms.cloudScale;
    uv -= combined_q - time * 0.3;
    weight = 0.7;
    for (int i = 0; i < 8; i++) {
        float2 curl = curl_noise(uv) * 0.03;
        f += weight * noise(uv + curl);
        uv = m * uv + time * 0.1;
        weight *= 0.58;
    }
    
    f *= r + f * 0.7;
    
    // Advanced atmospheric scattering simulation
    float3 skycolour1 = float3(0.08, 0.20, 0.60); // Deep zenith
    float3 skycolour2 = float3(0.35, 0.50, 0.80); // Horizon
    float3 skycolour3 = float3(0.20, 0.32, 0.72); // Mid atmosphere
    float3 skycolour4 = float3(0.45, 0.58, 0.85); // High atmosphere
    
    float gradient = p.y;
    float3 skycolour = mix(
        mix(skycolour2, skycolour3, smoothstep(0.0, 0.4, gradient)),
        mix(skycolour3, mix(skycolour4, skycolour1, smoothstep(0.6, 1.0, gradient)), smoothstep(0.4, 0.8, gradient)),
        smoothstep(0.2, 0.8, gradient)
    );
    
    // Advanced cloud coloring with sub-surface scattering simulation
    float subsurface = clamp(f * 2.0 - 1.0, 0.0, 1.0);
    float3 cloudcolour_base = float3(0.95, 0.97, 1.0);
    float3 cloudcolour_lit = float3(1.0, 0.98, 0.95);
    float3 cloudcolour = mix(cloudcolour_base, cloudcolour_lit, subsurface) * 
                        clamp((clouddark * 0.7 + cloudlight * 1.3 * f), 0.0, 1.0);
    
    // Volumetric density calculation
    float density = cloudcover * 0.7 + cloudalpha * 0.8 * f * r;
    
    // Advanced lighting with Rayleigh scattering approximation
    float3 result = mix(skycolour, 
                       clamp(skytint * 0.85 * skycolour + cloudcolour, 0.0, 1.0), 
                       smoothstep(0.0, 1.2, density));
    
    // Fully opaque like original Shadertoy
    return float4(result, 1.0);
}

// MARK: - Ultra Advanced Volumetric Cloud System

// 3D hash function for better randomness
float3 hash3d(float3 p) {
    p = float3(dot(p, float3(127.1, 311.7, 74.7)),
               dot(p, float3(269.5, 183.3, 246.1)),
               dot(p, float3(113.5, 271.9, 124.6)));
    return -1.0 + 2.0 * fract(sin(p) * 43758.5453123);
}

// 3D Worley noise for realistic cellular cloud structures
float worley3d(float3 p) {
    float3 id = floor(p);
    float3 f = fract(p);
    
    float minDist = 1.0;
    for (int x = -1; x <= 1; x++) {
        for (int y = -1; y <= 1; y++) {
            for (int z = -1; z <= 1; z++) {
                float3 neighbor = float3(float(x), float(y), float(z));
                float3 point = fract(hash3d(id + neighbor)) * 0.5 + 0.25;
                
                float3 diff = neighbor + point - f;
                float dist = length(diff);
                minDist = min(minDist, dist);
            }
        }
    }
    return minDist;
}

// Improved 3D noise with better gradients
float noise3d(float3 p) {
    float3 i = floor(p);
    float3 f = fract(p);
    float3 u = f * f * (3.0 - 2.0 * f);
    
    return mix(mix(mix(dot(hash3d(i + float3(0,0,0)), f - float3(0,0,0)),
                       dot(hash3d(i + float3(1,0,0)), f - float3(1,0,0)), u.x),
                   mix(dot(hash3d(i + float3(0,1,0)), f - float3(0,1,0)),
                       dot(hash3d(i + float3(1,1,0)), f - float3(1,1,0)), u.x), u.y),
               mix(mix(dot(hash3d(i + float3(0,0,1)), f - float3(0,0,1)),
                       dot(hash3d(i + float3(1,0,1)), f - float3(1,0,1)), u.x),
                   mix(dot(hash3d(i + float3(0,1,1)), f - float3(0,1,1)),
                       dot(hash3d(i + float3(1,1,1)), f - float3(1,1,1)), u.x), u.y), u.z);
}

// 3D FBM with domain warping
float fbm3d(float3 p, int octaves) {
    float value = 0.0;
    float amplitude = 0.5;
    float frequency = 1.0;
    
    for (int i = 0; i < octaves; i++) {
        value += amplitude * noise3d(p * frequency);
        amplitude *= 0.5;
        frequency *= 2.0;
    }
    return value;
}

// Cloud density function with multiple layers
float cloudDensity(float3 pos, float time, constant CloudUniforms& uniforms) {
    // Base cloud layer
    float3 windOffset = float3(time * 0.1, 0.0, time * 0.05) * uniforms.animationSpeed;
    float3 samplePos = pos * uniforms.cloudScale + windOffset;
    
    // Multiple frequency layers for detail
    float lowFreq = fbm3d(samplePos * 0.8, 4);
    float midFreq = fbm3d(samplePos * 2.4, 3);
    float highFreq = fbm3d(samplePos * 7.2, 2);
    
    // Worley noise for cellular structure
    float worley = worley3d(samplePos * 1.5);
    
    // Combine layers with realistic cloud formation
    float baseShape = smoothstep(0.1, 0.9, lowFreq + 0.3);
    float detail = midFreq * 0.5 + highFreq * 0.25;
    float erosion = worley * 0.4;
    
    // Cloud type variation (cumulus-like structures)
    float density = baseShape * (1.0 + detail - erosion);
    
    // Altitude falloff for realistic cloud layers
    float altitude = pos.y;
    float altitudeFalloff = smoothstep(0.0, 0.3, altitude) * smoothstep(1.0, 0.7, altitude);
    
    return clamp(density * altitudeFalloff, 0.0, 1.0);
}

// Henyey-Greenstein phase function for realistic light scattering
float henyeyGreenstein(float cosTheta, float g) {
    float g2 = g * g;
    return (1.0 - g2) / (4.0 * 3.14159 * pow(1.0 + g2 - 2.0 * g * cosTheta, 1.5));
}

// Beer's law for light attenuation
float beerLaw(float density, float extinctionCoeff) {
    return exp(-density * extinctionCoeff);
}

// Multiple scattering approximation
float multipleScattering(float density, float lightEnergy) {
    float scatter1 = lightEnergy * beerLaw(density, 1.0);
    float scatter2 = lightEnergy * 0.5 * beerLaw(density, 0.5);
    return scatter1 + scatter2;
}

// Ray marching function for volumetric clouds
float4 marchClouds(float3 rayOrigin, float3 rayDirection, float maxDistance, 
                   float time, constant CloudUniforms& uniforms) {
    
    const int maxSteps = 32;
    const float stepSize = maxDistance / float(maxSteps);
    
    float3 lightDir = normalize(float3(0.5, 0.8, 0.3)); // Sun direction
    float3 accumulatedColor = float3(0.0);
    float accumulatedAlpha = 0.0;
    
    for (int i = 0; i < maxSteps; i++) {
        if (accumulatedAlpha >= 0.95) break; // Early exit for opaque clouds
        
        float3 samplePos = rayOrigin + rayDirection * (float(i) * stepSize);
        float density = cloudDensity(samplePos, time, uniforms);
        
        if (density > 0.01) {
            // Light marching for shadows
            float lightAccumulation = 0.0;
            const int lightSteps = 6;
            for (int j = 0; j < lightSteps; j++) {
                float3 lightSamplePos = samplePos + lightDir * (float(j) * stepSize * 0.5);
                lightAccumulation += cloudDensity(lightSamplePos, time, uniforms);
            }
            
            // Calculate lighting
            float lightTransmission = beerLaw(lightAccumulation, 0.8);
            float scattering = henyeyGreenstein(dot(rayDirection, lightDir), 0.3);
            float lightEnergy = lightTransmission * scattering;
            
            // Cloud color with multiple scattering
            float3 cloudColor = mix(
                float3(0.6, 0.7, 0.8),  // Shadow color
                float3(1.0, 0.95, 0.8), // Lit color
                multipleScattering(density, lightEnergy)
            );
            
            // Alpha blending
            float alpha = density * (1.0 - accumulatedAlpha);
            accumulatedColor += cloudColor * alpha;
            accumulatedAlpha += alpha;
        }
    }
    
    return float4(accumulatedColor, accumulatedAlpha);
}

// Ultra advanced fragment shader - simplified for performance
fragment float4 cloud_fragment_ultra(VertexOut in [[stage_in]],
                                     constant CloudUniforms& uniforms [[buffer(0)]]) {
    
    float2 p = in.texCoord;
    float2 uv = p * float2(uniforms.resolution.x / uniforms.resolution.y, 1.0);
    float time = uniforms.time * speed * uniforms.animationSpeed * 0.3;
    
    // Use advanced 2D noise instead of expensive 3D ray marching
    float q = fbm_advanced(uv * cloudscale * uniforms.cloudScale * 0.5, time);
    
    // Enhanced cloud formation with curl noise
    float r = 0.0;
    uv *= cloudscale * uniforms.cloudScale;
    uv -= q - time * 0.4;
    float weight = 0.7;
    for (int i = 0; i < 4; i++) { // Reduced from 8 to 4 iterations
        float2 curl = curl_noise(uv) * 0.03;
        r += abs(weight * noise(uv + curl));
        uv = m * uv + time * 0.15;
        weight *= 0.7;
    }
    
    // Detailed cloud structure
    float f = 0.0;
    uv = p * float2(uniforms.resolution.x / uniforms.resolution.y, 1.0);
    uv *= cloudscale * uniforms.cloudScale;
    uv -= q - time * 0.2;
    weight = 0.6;
    for (int i = 0; i < 4; i++) { // Reduced from 8 to 4 iterations
        float2 curl = curl_noise(uv) * 0.02;
        f += weight * noise(uv + curl);
        uv = m * uv + time * 0.08;
        weight *= 0.65;
    }
    
    f *= r + f * 0.8;
    
    // Enhanced sky colors with atmospheric scattering
    float3 skycolour1 = float3(0.08, 0.20, 0.60); // Deep zenith
    float3 skycolour2 = float3(0.40, 0.55, 0.85); // Horizon
    float3 skycolour3 = float3(0.25, 0.35, 0.75); // Mid atmosphere
    
    float gradient = smoothstep(0.0, 1.0, p.y);
    float3 skycolour = mix(skycolour2, mix(skycolour3, skycolour1, gradient * 0.8), gradient);
    
    // Advanced cloud coloring with simulated sub-surface scattering
    float subsurface = smoothstep(0.3, 0.8, f);
    float3 cloudcolour_base = float3(0.92, 0.94, 0.98);
    float3 cloudcolour_lit = float3(1.0, 0.96, 0.88);
    float3 cloudcolour = mix(cloudcolour_base, cloudcolour_lit, subsurface) * 
                        clamp((clouddark * 0.6 + cloudlight * 1.4 * f), 0.0, 1.0);
    
    // Volumetric density with better falloff
    float density = cloudcover * 0.6 + cloudalpha * 0.85 * f * r;
    
    // Advanced blending with atmospheric perspective
    float3 result = mix(skycolour, 
                       clamp(skytint * 0.8 * skycolour + cloudcolour, 0.0, 1.0), 
                       smoothstep(0.0, 1.3, density));
    
    // Apply tone mapping for more realistic look
    result = result / (result + 0.8);
    result = pow(result, float3(1.0/2.0)); // Lighter gamma for brighter appearance
    
    // Fully opaque like original Shadertoy
    return float4(result, 1.0);
}

// Temporal anti-aliasing vertex shader
vertex VertexOut cloud_vertex_ultra(uint vertexID [[vertex_id]],
                                    constant CloudUniforms& uniforms [[buffer(0)]]) {
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
    
    // Add temporal jitter for anti-aliasing
    float2 jitter = float2(
        fract(sin(uniforms.time * 12.9898) * 43758.5453),
        fract(sin(uniforms.time * 78.233) * 43758.5453)
    ) * (2.0 / uniforms.resolution) - (1.0 / uniforms.resolution);
    
    VertexOut out;
    out.position = float4(quadPositions[vertexID] + jitter, 0.0, 1.0);
    out.texCoord = quadTexCoords[vertexID];
    out.screenPos = quadPositions[vertexID];
    return out;
}
