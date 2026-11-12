// The present: the frame drawn into the drawable, cropped (nvn_mtl.m present_pipeline)
#include <metal_stdlib>
using namespace metal;
struct V { float4 p [[position]]; float2 uv; };
vertex V vs(uint id [[vertex_id]]) { float2 uv = float2((id << 1) & 2, id & 2); V o; o.p = float4(uv * float2(2, -2) + float2(-1, 1), 0, 1); o.uv = uv; return o; }
struct Crop { float4 rect; float4 edge; };
fragment float4 fs(V in [[stage_in]], texture2d<float> t [[texture(0)]], sampler s [[sampler(0)]], constant Crop& c [[buffer(0)]]) { return t.sample(s, clamp(in.uv * c.rect.zw + c.rect.xy, c.edge.xy, c.edge.zw)); }
// DM_PRESENT_SHARPEN: the same pass with a contrast-adaptive sharpen (the shape of FSR 1's RCAS: a five-tap cross one source texel apart, the negative lobe limited by the
// local minimum and maximum so nothing rings or clips; the present samples stored bytes, so it works on the encoded values as RCAS expects). sharp.x: strength 0-1, sharp.yz: one texel
struct CropS { float4 rect; float4 edge; float4 sharp; };
fragment float4 fs_sharp(V in [[stage_in]], texture2d<float> t [[texture(0)]], sampler s [[sampler(0)]], constant CropS& c [[buffer(0)]]) {
    float2 uv = in.uv * c.rect.zw + c.rect.xy, px = c.sharp.yz;
    float4 e4 = t.sample(s, clamp(uv, c.edge.xy, c.edge.zw));
    float3 e = e4.rgb;
    float3 b = t.sample(s, clamp(uv + float2(0, -px.y), c.edge.xy, c.edge.zw)).rgb, d = t.sample(s, clamp(uv + float2(-px.x, 0), c.edge.xy, c.edge.zw)).rgb;
    float3 f = t.sample(s, clamp(uv + float2(px.x, 0), c.edge.xy, c.edge.zw)).rgb, h = t.sample(s, clamp(uv + float2(0, px.y), c.edge.xy, c.edge.zw)).rgb;
    float3 mn = min(min(min(b, d), min(f, h)), e), mx = max(max(max(b, d), max(f, h)), e);
    float3 hit_min = mn / (4.0 * mx + 1e-4), hit_max = (1.0 - mx) / (4.0 * mn - 4.0 - 1e-4);
    float3 lobe_c = max(-hit_min, hit_max);
    float lobe = max(-0.1875, min(max(lobe_c.r, max(lobe_c.g, lobe_c.b)), 0.0)) * c.sharp.x;
    return float4(saturate((lobe * (b + d + f + h) + e) / (4.0 * lobe + 1.0)), e4.a);
}
