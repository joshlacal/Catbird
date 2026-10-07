#include <metal_stdlib>
using namespace metal;

// Login-screen sky: soft drifting cumulus over a blue gradient.
// Written for Catbird from scratch; replaces the Shadertoy-derived CloudShader.
// Cost is a handful of analytic gaussian lobes per pixel plus two taps of a
// small tileable noise texture (built at runtime by SkyView), so it stays
// cool enough to run at 30fps / half resolution indefinitely.

struct SkyBlobsVertexOut { float4 position [[position]]; float2 uv; };
struct SkyBlobsUniforms { float2 resolution; float time; float dark; };

vertex SkyBlobsVertexOut sky_blobs_vertex(uint vid [[vertex_id]]) {
  float2 pos[4] = { float2(-1, -1), float2(1, -1), float2(-1, 1), float2(1, 1) };
  float2 uv[4] = { float2(0, 1), float2(1, 1), float2(0, 0), float2(1, 0) };
  SkyBlobsVertexOut o;
  o.position = float4(pos[vid], 0, 1);
  o.uv = uv[vid];
  return o;
}

constant int kSkyClouds = 8;

// x0 (in units of screen height), y centre (uv), half-width, half-height,
// drift speed (heights/s), opacity, phase.  Big clouds live near the top and
// bottom; the middle third (where the login form sits) gets thin ones.
constant float4 kSkyCloudA[kSkyClouds] = {
  // x0,    y,     rx,    ry
  float4(0.05, 0.14, 0.28, 0.095),
  float4(0.70, 0.27, 0.20, 0.075),
  float4(0.35, 0.45, 0.18, 0.045),
  float4(0.95, 0.58, 0.14, 0.040),
  float4(0.15, 0.74, 0.24, 0.085),
  float4(0.80, 0.87, 0.32, 0.110),
  float4(0.50, 0.99, 0.30, 0.100),
  float4(1.10, 0.05, 0.20, 0.045),
};
constant float4 kSkyCloudB[kSkyClouds] = {
  // speed, opacity, phase, wispiness (0 = cumulus, 1 = torn/stratus)
  float4(0.0065, 0.95, 0.0, 0),
  float4(0.0050, 0.85, 1.7, 0),
  float4(0.0040, 0.60, 3.1, 1),
  float4(0.0045, 0.60, 4.4, 1),
  float4(0.0075, 0.90, 2.2, 0),
  float4(0.0090, 1.00, 5.3, 0),
  float4(0.0085, 0.95, 0.9, 0),
  float4(0.0055, 0.80, 3.8, 0),
};

static inline float skyblobs_noise(float4 n) {
  // 4 octaves already baked into RGBA; weight low octaves more.
  return dot(n, float4(0.50, 0.27, 0.15, 0.08));
}

fragment float4 sky_blobs_fragment(SkyBlobsVertexOut in [[stage_in]],
                              constant SkyBlobsUniforms& u [[buffer(0)]],
                              texture2d<float> noiseTex [[texture(0)]],
                              sampler noiseSmp [[sampler(0)]]) {
  float aspect = u.resolution.x / u.resolution.y;     // ~0.46 on iPhone
  float2 p = float2(in.uv.x * aspect, in.uv.y);        // height-normalised
  float t = u.time;

  // ---- noise in the wind frame (2 taps, different scale/drift) ----------
  float2 wind = float2(0.0068 * t, 0.0);
  // tap 1: broad billows (R cell ~0.17 h); tap 2: fine curls, rotated so the
  // two lattices never line up, evolving vertically so shapes churn.
  float2 q1 = (p - wind) * float2(0.62, 0.85) + float2(0.13, 0.37);
  float2 pr = float2(p.x * 0.866 - p.y * 0.5, p.x * 0.5 + p.y * 0.866);
  float2 q2 = (pr - wind * 0.9) * 2.1 + float2(0.61, 0.09) + float2(0.0, 0.006 * t);
  float4 t1 = noiseTex.sample(noiseSmp, q1);
  float4 t2 = noiseTex.sample(noiseSmp, q2);
  float n1 = skyblobs_noise(t1);
  float n2 = skyblobs_noise(t2);
  // 8-ish octave fbm, contrast-stretched (sum of value noise is narrow)
  float nd = ((n1 - 0.5) * 0.7 + (n2 - 0.5) * 0.45) * 3.2;

  // ---- sky gradient --------------------------------------------------------
  float y = in.uv.y;
  float3 skyTop, skyBot, cloudLit, cloudShade;
  if (u.dark > 0.5) {
    skyTop     = float3(0.035, 0.065, 0.170);
    skyBot     = float3(0.015, 0.030, 0.090);
    cloudLit   = float3(0.42, 0.47, 0.62);
    cloudShade = float3(0.13, 0.16, 0.27);
  } else {
    skyTop     = float3(0.33, 0.55, 0.90);
    skyBot     = float3(0.13, 0.30, 0.72);
    cloudLit   = float3(0.99, 0.995, 1.0);
    cloudShade = float3(0.64, 0.72, 0.90);
  }
  float3 col = mix(skyTop, skyBot, smoothstep(0.0, 1.0, y));
  // soft sun/moon glow from the upper right
  float2 gd = p - float2(aspect * 0.95, -0.05);
  float glow = exp(-dot(gd, gd) * 6.0);
  col += glow * (u.dark > 0.5 ? float3(0.05, 0.07, 0.12) : float3(0.16, 0.16, 0.12));

  // ---- sparse stars (dark only): one hash per ~14px cell, drawn under clouds --
  if (u.dark > 0.5) {
    float2 sp = in.uv * float2(u.resolution.x / u.resolution.y, 1.0) * 140.0;
    float2 cell = floor(sp);
    float sh = fract(sin(dot(cell, float2(127.1, 311.7))) * 43758.5453);
    float2 so = fract(float2(sh * 7.13, sh * 3.71)) - 0.5;
    float sd = length(fract(sp) - 0.5 - so * 0.6);
    float star = step(0.965, sh) * smoothstep(0.22, 0.0, sd)
               * (0.6 + 0.4 * sin(t * 0.8 + sh * 60.0))
               * (1.0 - smoothstep(0.35, 0.85, y));
    col += star * 0.55 * float3(0.85, 0.9, 1.0);
  }

  // ---- soft high veil: amorphous low-contrast haze between the puffs -------
  float veil = smoothstep(0.05, 0.95, nd + 0.15 - 0.25 * exp(-(y - 0.5) * (y - 0.5) * 25.0));
  col = mix(col, mix(cloudShade, cloudLit, 0.6), veil * 0.22);

  // ---- clouds: back-to-front over-compositing ----------------------------------
  const float W = aspect + 0.85;                      // wrap width
  for (int i = 0; i < kSkyClouds; ++i) {
    float4 A = kSkyCloudA[i];
    float4 B = kSkyCloudB[i];
    float breathe = sin(t * 0.045 + B.z);
    float cx = fract((A.x + B.x * t) / W) * W - 0.42;
    float2 c = float2(cx, A.y + 0.006 * sin(t * 0.03 + B.z * 2.0));
    float2 d = (p - c) / A.zw;
    // cheap cull: lobes sit within ~0.7 of centre and fall to ~0 by r~2.1,
    // so pixels outside this box can't be touched by this cloud
    if (abs(d.x) > 2.1 || abs(d.y) > 2.1) continue;
    d.y += d.x * 0.10 * sin(B.z * 1.9);               // per-cloud tilt
    float side = sin(B.z * 3.7);                        // per-cloud lobe layout
    // flatten the base: below centre falls off faster
    d.y *= d.y > 0.0 ? mix(1.45, 1.0, B.w) : 1.0;
    // three lobes: left shoulder, tall crown, right shoulder (slowly morphing)
    float2 l0 = d - float2(-0.50, 0.12 + 0.10 * breathe);
    float2 l1 = d - float2( 0.30 * side + 0.10 * breathe, -0.32 + 0.05 * side);
    float2 l2 = d - float2( 0.55, 0.06 - 0.09 * breathe);
    float g = exp(-dot(l0, l0) * 2.6) * 0.85
            + exp(-dot(l1, l1) * 2.2)
            + exp(-dot(l2, l2) * 3.0) * 0.75;
    // billowed edge: noise perturbs the threshold
    // erosion is gated by the blob so noise can't spawn puffs in open sky,
    // and is strongest on the edges, weaker in the solid core
    float gate = smoothstep(0.0, 0.22, g);
    float field = g + nd * gate * (0.40 + 0.60 * smoothstep(1.1, 0.25, g)) * (1.0 + 0.9 * B.w);
    float a = smoothstep(0.26, 0.86 + 0.35 * B.w, field) * B.y;
    if (a < 0.002) continue;
    // lighting: lit crown, shaded flat base, noise-based self-shadowing
    float vert = clamp(0.55 - d.y * 0.45, 0.0, 1.0);
    float lit = clamp(vert * 0.7 + nd * 0.55 + 0.25, 0.0, 1.0);
    float3 cc = mix(cloudShade, cloudLit, lit);
    // thin edges let the sky tint through
    float thick = smoothstep(0.30, 1.2, field);
    cc = mix(mix(col, cc, 0.65), cc, thick);
    col = mix(col, cc, a);
  }

  // keep the centre (form area) a touch calmer
  float mid = exp(-((y - 0.5) * (y - 0.5)) * 30.0);
  col *= 1.0 - 0.06 * mid * (1.0 - u.dark);

  // ---- dither -------------------------------------------------------------------
  float2 fp = in.position.xy;
  float h = fract(52.9829189 * fract(dot(fp, float2(0.06711056, 0.00583715))));
  col += (h - 0.5) / 255.0;
  return float4(saturate(col), 1.0);
}
