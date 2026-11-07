// Camera motion vectors for MetalFX's temporal scaler (nvn_mtl.m tsr_encode, DM_UPSCALER=metalfx-temporal; the math is dm/gfx/nvn/nvn_tsr.h, tsr_motion_uv).
// One thread a pixel of the content (at the textures' origin): the pixel centre in this frame's Metal NDC with its scene depth, through reproj (this frame's jittered
// view-projection inverted, then the previous frame's unjittered one), gives where the surface was. The motion is that place minus the pixel's unjittered place, in UV units
// (MetalFX's motionVectorScale is the content size), pointing to the previous position. Camera motion only: whatever moves in the world gets the motion of a static surface there.
// Statistics (flags & 2): the previous depth at the reprojected place against the distance the surface should have had there (a wrong matrix, row or sign shows as tens of percent
// of the pixels disagreeing while the camera turns over a still scene; edges and disocclusions give a few), the mean motion and the pixels that left the frame.
#include <metal_stdlib>
using namespace metal;
struct tsr_mv_args {
    float4x4 reproj;        // Metal NDC (x, y, depth, 1) of this frame (jittered) -> the previous frame's clip position (unjittered)
    float2 jit, jit_prev;   // this frame's and the previous frame's jitter in NDC
    uint2 size, prev_size;  // the content this frame and the previous frame (pixels at the origin)
    float ysign, tol;       // ysign +1: NDC +y is row 0 (upper-left window origin), -1: lower left; tol: relative distance disagreement that counts
    uint flags;             // 1: the previous depth is valid; 2: statistics
    float maxd;             // statistics only where the surface is nearer (D32F depth with GL's mapping loses relative precision with distance)
    float4 lin, lin_prev;   // view distance from Metal depth d: lin.x / (d * lin.y + lin.z), this frame and the previous one
};
enum { TSR_ST_PIX, TSR_ST_MVQ, TSR_ST_CHECKED, TSR_ST_BAD, TSR_ST_OFF };   // stats[]: pixels, sum of |motion| in quarter pixels, pixels compared, disagreeing, reprojected outside the frame
kernel void tsr_mv(depth2d<float, access::read> depth [[texture(0)]], depth2d<float, access::read> prev_depth [[texture(1)]], texture2d<half, access::write> motion [[texture(2)]],
                   constant tsr_mv_args &a [[buffer(0)]], device atomic_uint *stats [[buffer(1)]], uint2 g [[thread_position_in_grid]]) {
    uint pix = 0, mvq = 0, checked = 0, bad = 0, off = 0;
    if (g.x < a.size.x && g.y < a.size.y) {
        float d = depth.read(g);
        float2 uv = (float2(g) + 0.5f) / float2(a.size);
        float2 ndc = float2(uv.x * 2.0f - 1.0f, a.ysign * (1.0f - uv.y * 2.0f));
        float4 pc = a.reproj * float4(ndc, d, 1.0f);
        bool front = pc.w > 1e-20f;   // behind the previous camera: no motion
        float2 pn = front ? pc.xy / pc.w : ndc - a.jit;
        float2 mn = pn - (ndc - a.jit);
        float2 mv = clamp(float2(0.5f * mn.x, -0.5f * a.ysign * mn.y), -2.0f, 2.0f);
        motion.write(half4(half2(mv), 0.0h, 0.0h), g);
        if (a.flags & 2u) {
            pix = 1; mvq = uint(min(length(mv * float2(a.size)), 255.0f) * 4.0f);
            if ((a.flags & 1u) && front && d < 1.0f) {
                float2 pj = pn + a.jit_prev;   // where the previous (jittered) depth has the surface
                float2 puv = float2(0.5f + 0.5f * pj.x, 0.5f - 0.5f * a.ysign * pj.y);
                float de = a.lin.x / (d * a.lin.y + a.lin.z) * pc.w;   // the distance the previous camera should have seen (pc.w = w_prev / w_now)
                if (any(puv < 0.0f) || any(puv >= 1.0f)) off = 1;
                else if (de < a.maxd) {
                    uint2 pp = min(uint2(puv * float2(a.prev_size)), a.prev_size - 1u);
                    float pd = prev_depth.read(pp);
                    float dg = a.lin_prev.x / (pd * a.lin_prev.y + a.lin_prev.z);
                    checked = 1; bad = abs(dg - de) > a.tol * abs(de) ? 1u : 0u;
                }
            }
        }
    }
    if (a.flags & 2u) {
        uint s0 = simd_sum(pix), s1 = simd_sum(mvq), s2 = simd_sum(checked), s3 = simd_sum(bad), s4 = simd_sum(off);
        if (simd_is_first()) {
            if (s0) atomic_fetch_add_explicit(&stats[TSR_ST_PIX], s0, memory_order_relaxed);
            if (s1) atomic_fetch_add_explicit(&stats[TSR_ST_MVQ], s1, memory_order_relaxed);
            if (s2) atomic_fetch_add_explicit(&stats[TSR_ST_CHECKED], s2, memory_order_relaxed);
            if (s3) atomic_fetch_add_explicit(&stats[TSR_ST_BAD], s3, memory_order_relaxed);
            if (s4) atomic_fetch_add_explicit(&stats[TSR_ST_OFF], s4, memory_order_relaxed);
        }
    }
}
