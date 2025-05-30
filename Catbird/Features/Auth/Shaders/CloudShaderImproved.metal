#include <metal_stdlib>
using namespace metal;

// Hyperrealistic cloud shader based on "Clouds" by drift
// Original: https://www.shadertoy.com/view/4tdSWr
// Adapted for Metal and optimized for iPhone 120fps with enhanced realism

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
    float3 padding;
};

// Constants from original shader with tweaks for 120fps
constant float cloudscale_improved = 1.1;
constant float speed_improved = 0.015;  // Halved for slower, more realistic animation at 120fps
constant float clouddark_improved = 0.5;
constant float cloudlight_improved = 0.3;
constant float cloudcover_improved = 0.2;
constant float cloudalpha_improved = 8.0;
constant float skytint_improved = 0.5;

// Darker, more realistic sky colors
constant float3 skycolour1_light_improved = float3(0.15, 0.3, 0.5);    // Darker blue for light mode
constant float3 skycolour2_light_improved = float3(0.3, 0.5, 0.85);    // Medium blue
constant float3 skycolour1_dark_improved = float3(0.02, 0.05, 0.15);   // Very dark blue for dark mode
constant float3 skycolour2_dark_improved = float3(0.05, 0.1, 0.25);     // Dark blue

// Rotation matrix for cloud evolution
constant float2x2 m_improved = float2x2(1.6, 1.2, -1.2, 1.6);

// Hash function from original shader
float2 hash_improved(float2 p) {
    p = float2(dot(p, float2(127.1, 311.7)), 
               dot(p, float2(269.5, 183.3)));
    return -1.0 + 2.0 * fract(sin(p) * 43758.5453123);
}

// Simplex noise implementation
float noise_improved(float2 p) {
    const float K1 = 0.366025404; // (sqrt(3)-1)/2;
    const float K2 = 0.211324865; // (3-sqrt(3))/6;
    
    float2 i = floor(p + (p.x + p.y) * K1);
    float2 a = p - i + (i.x + i.y) * K2;
    float2 o = (a.x > a.y) ? float2(1.0, 0.0) : float2(0.0, 1.0);
    float2 b = a - o + K2;
    float2 c = a - 1.0 + 2.0 * K2;
    
    float3 h = max(0.5 - float3(dot(a, a), dot(b, b), dot(c, c)), 0.0);
    float3 n = h * h * h * h * float3(dot(a, hash_improved(i + 0.0)), 
                                      dot(b, hash_improved(i + o)), 
                                      dot(c, hash_improved(i + 1.0)));
    return dot(n, float3(70.0));
}

// Fractal Brownian Motion
float fbm_improved(float2 n) {
    float total = 0.0;
    float amplitude = 0.1;
    
    // Optimized to 5 octaves for 120fps while maintaining quality
    for (int i = 0; i < 5; i++) {
        total += noise_improved(n) * amplitude;
        n = m_improved * n;
        amplitude *= 0.4;
    }
    return total;
}


vertex VertexOut cloud_vertex_improved(uint vertexID [[vertex_id]]) {
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

fragment float4 cloud_fragment_improved(VertexOut in [[stage_in]],
                                       constant CloudUniforms& uniforms [[buffer(0)]]) {
    float2 p = in.texCoord;
    float2 uv = p * float2(uniforms.resolution.x / uniforms.resolution.y, 1.0);
    
    // Time with animation speed control (speed constant already adjusted for 120fps)
    float time = uniforms.time * speed_improved * uniforms.animationSpeed;
    
    // Initial noise offset
    float q = fbm_improved(uv * cloudscale_improved * 0.5);
    
    // ---- From original shader: calculate all the noise components ----
    
    // Ridged noise shape
    float r = 0.0;
    float2 uv_ridged = uv * cloudscale_improved;
    uv_ridged -= q - time;
    float weight = 0.8;
    for (int i = 0; i < 6; i++) {
        r += abs(weight * noise_improved(uv_ridged));
        uv_ridged = m_improved * uv_ridged + time;
        weight *= 0.7;
    }
    
    // Noise shape
    float f = 0.0;
    float2 uv_smooth = p * float2(uniforms.resolution.x / uniforms.resolution.y, 1.0);
    uv_smooth *= cloudscale_improved;
    uv_smooth -= q - time;
    weight = 0.7;
    for (int i = 0; i < 6; i++) {
        f += weight * noise_improved(uv_smooth);
        uv_smooth = m_improved * uv_smooth + time;
        weight *= 0.6;
    }
    
    f *= r + f;
    
    // Noise colour
    float c = 0.0;
    float time_color = time * 2.0;
    float2 uv_color = p * float2(uniforms.resolution.x / uniforms.resolution.y, 1.0);
    uv_color *= cloudscale_improved * 2.0;
    uv_color -= q - time_color;
    weight = 0.4;
    for (int i = 0; i < 5; i++) {
        c += weight * noise_improved(uv_color);
        uv_color = m_improved * uv_color + time_color;
        weight *= 0.6;
    }
    
    // Noise ridge colour
    float c1 = 0.0;
    float time_ridge = time * 3.0;
    float2 uv_ridge = p * float2(uniforms.resolution.x / uniforms.resolution.y, 1.0);
    uv_ridge *= cloudscale_improved * 3.0;
    uv_ridge -= q - time_ridge;
    weight = 0.4;
    for (int i = 0; i < 5; i++) {
        c1 += abs(weight * noise_improved(uv_ridge));
        uv_ridge = m_improved * uv_ridge + time_ridge;
        weight *= 0.6;
    }
    
    c += c1;
    
    // ---- End of original shader calculations ----
    
    // Sky gradient with darker blues
    float3 skycolour1 = uniforms.isDarkMode ? skycolour1_dark_improved : skycolour1_light_improved;
    float3 skycolour2 = uniforms.isDarkMode ? skycolour2_dark_improved : skycolour2_light_improved;
    float3 skycolour = mix(skycolour2, skycolour1, p.y);
    
    // Cloud color from original shader
    float3 cloudcolour = float3(1.1, 1.1, 0.9) * clamp((clouddark_improved + cloudlight_improved * c), 0.0, 1.0);
    
    // Final mixing from original shader
    f = cloudcover_improved + cloudalpha_improved * f * r;
    float3 result = mix(skycolour, clamp(skytint_improved * skycolour + cloudcolour, 0.0, 1.0), clamp(f + c, 0.0, 1.0));
    
    // Enhancements for hyperrealism
    
    // Atmospheric perspective - distant clouds are lighter and bluer
    float distance = 1.0 - p.y;
    result = mix(result, float3(0.7, 0.8, 0.9), distance * 0.3);
    
    // Subtle vignette for depth
    float vignette = 1.0 - length(in.screenPos) * 0.1;
    result *= vignette;
    
    // Enhanced tone mapping for better dynamic range
    result = float3(1.0) - exp(-result * 1.2); // Exposure tone mapping
    result = pow(result, float3(1.0/2.2));      // Gamma correction
    
    return float4(saturate(result), uniforms.opacity);
}
