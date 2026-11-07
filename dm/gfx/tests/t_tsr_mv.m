// GPU test of the temporal upscaler's motion pass (dm/gfx/msl/tsr.metal, as nvn_mtl.m tsr_encode binds it) against the CPU math it implements (dm/gfx/nvn/nvn_tsr.h tsr_motion_uv):
// - a camera that turns 1.5 deg and steps forward over a uniform depth: every pixel's motion within 0.02 px of the CPU's (half-float output), the statistics counting every pixel;
// - a still camera rendered with jitter, previous depth equal: no motion anywhere, every near pixel compared and none disagreeing;
// - the same with the previous depth much farther: every compared pixel disagrees (the check can fail).
#import <Metal/Metal.h>
#include <stdio.h>
#include <string.h>
#include "../nvn/host_msl.h"
#include "../nvn/nvn_tsr.h"

typedef struct { float reproj[16]; float jit[2], jit_prev[2]; uint32_t size[2], prev_size[2]; float ysign, tol; uint32_t flags; float maxd; float lin[4], lin_prev[4]; } tsr_mv_args;   // nvn_mtl.m's
enum { W = 96, H = 54 };
static int fail;
static void ok(const char *name, int cond) { fail += !cond; printf("%-96s %s\n", name, cond ? "ok" : "FAILED"); }

static void persp_gl(float p[16], double vfov_deg, double aspect, double n, double f) {
    memset(p, 0, 64); double t = 1 / tan(vfov_deg * M_PI / 360);
    p[0] = (float)(t / aspect); p[5] = (float)t; p[10] = (float)(-(f + n) / (f - n)); p[11] = (float)(-2 * f * n / (f - n)); p[14] = -1;
}
static void view(float v[12], double px, double py, double pz, double yaw) {
    double y = yaw * M_PI / 180, f[3] = {sin(y), 0, -cos(y)}, r[3] = {cos(y), 0, sin(y)}, u[3] = {0, 1, 0}, pos[3] = {px, py, pz};
    double rows[3][3] = {{r[0], r[1], r[2]}, {u[0], u[1], u[2]}, {-f[0], -f[1], -f[2]}};
    for (int i = 0; i < 3; i++) { double t = 0; for (int k = 0; k < 3; k++) { v[i * 4 + k] = (float)rows[i][k]; t -= rows[i][k] * pos[k]; } v[i * 4 + 3] = (float)t; }
}
static void cam_make(tsr_cam *c, const float v[12], const float p[16]) {
    memcpy(c->v, v, 48); memcpy(c->p, p, 64);
    double P[16], V[16], PV[16]; tsr_f2d(p, P, 16); tsr_v4(v, V); tsr_mul4(P, V, PV);
    for (int i = 0; i < 16; i++) c->vp[i] = (float)PV[i];
}
static id<MTLTexture> depth_tex(id<MTLDevice> dev, id<MTLCommandQueue> q, float d) {   // a Depth32Float texture cleared to d
    MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatDepth32Float width:W height:H mipmapped:NO];
    td.storageMode = MTLStorageModePrivate; td.usage = MTLTextureUsageShaderRead | MTLTextureUsageRenderTarget;
    id<MTLTexture> t = [dev newTextureWithDescriptor:td];
    MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
    rp.depthAttachment.texture = t; rp.depthAttachment.loadAction = MTLLoadActionClear; rp.depthAttachment.storeAction = MTLStoreActionStore; rp.depthAttachment.clearDepth = d;
    id<MTLCommandBuffer> cb = [q commandBuffer]; [[cb renderCommandEncoderWithDescriptor:rp] endEncoding]; [cb commit]; [cb waitUntilCompleted];
    return t;
}
// One run of the kernel: motion (UV, two halves a pixel) into mv, statistics into st
static void run(id<MTLDevice> dev, id<MTLCommandQueue> q, id<MTLComputePipelineState> ps, id<MTLTexture> dc, id<MTLTexture> dp, const tsr_mv_args *a, __fp16 *mv, uint32_t st[8]) {
    MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRG16Float width:W height:H mipmapped:NO];
    td.storageMode = MTLStorageModeShared; td.usage = MTLTextureUsageShaderWrite | MTLTextureUsageShaderRead;
    id<MTLTexture> mt = [dev newTextureWithDescriptor:td];
    id<MTLBuffer> ab = [dev newBufferWithBytes:a length:sizeof *a options:MTLResourceStorageModeShared], sb = [dev newBufferWithLength:32 options:MTLResourceStorageModeShared];
    memset(sb.contents, 0, 32);
    id<MTLCommandBuffer> cb = [q commandBuffer]; id<MTLComputeCommandEncoder> ce = [cb computeCommandEncoder];
    [ce setComputePipelineState:ps]; [ce setTexture:dc atIndex:0]; [ce setTexture:dp atIndex:1]; [ce setTexture:mt atIndex:2]; [ce setBuffer:ab offset:0 atIndex:0]; [ce setBuffer:sb offset:0 atIndex:1];
    [ce dispatchThreadgroups:MTLSizeMake((W + 15) / 16, (H + 15) / 16, 1) threadsPerThreadgroup:MTLSizeMake(16, 16, 1)];
    [ce endEncoding]; [cb commit]; [cb waitUntilCompleted];
    [mt getBytes:mv bytesPerRow:W * 4 fromRegion:MTLRegionMake2D(0, 0, W, H) mipmapLevel:0];
    memcpy(st, sb.contents, 32);
}
static void args_make(tsr_mv_args *a, const double R[16], const float pcur[16], const float pprev[16], float ox, float oy, uint32_t flags) {
    memset(a, 0, sizeof *a);
    for (int r = 0; r < 4; r++) for (int q = 0; q < 4; q++) a->reproj[q * 4 + r] = (float)R[r * 4 + q];
    a->jit[0] = ox; a->jit[1] = oy; a->size[0] = a->prev_size[0] = W; a->size[1] = a->prev_size[1] = H;
    a->ysign = 1; a->tol = 0.02f; a->maxd = 500; a->flags = flags;
    tsr_lin(pcur, 0, a->lin); tsr_lin(pprev, 0, a->lin_prev);
}

int main(void) { @autoreleasepool {
    id<MTLDevice> dev = MTLCreateSystemDefaultDevice(); NSError *err = nil;
    id<MTLLibrary> lib = host_msl_lib(dev, nil, "tsr", &err);
    id<MTLFunction> fn = lib ? [lib newFunctionWithName:@"tsr_mv"] : nil;
    id<MTLComputePipelineState> ps = fn ? [dev newComputePipelineStateWithFunction:fn error:&err] : nil;
    if (!ps) { printf("no tsr_mv pipeline: %s\n", err.localizedDescription.UTF8String); return 1; }
    id<MTLCommandQueue> q = [dev newCommandQueue];
    float P[16], V0[12], V1[12]; persp_gl(P, 50, (double)W / H, 0.1, 25000);
    const float D = 0.97f;   // about 3.3 units away
    id<MTLTexture> dcur = depth_tex(dev, q, D), dsame = depth_tex(dev, q, D), dfar = depth_tex(dev, q, 0.9999f);
    static __fp16 mv[W * H * 2]; uint32_t st[8]; tsr_mv_args a; double R[16];

    // 1) a turn and a step: the kernel against tsr_motion_uv at every pixel
    tsr_cam c0, c1; view(V0, 2, 1, 3, 10); cam_make(&c0, V0, P); view(V1, 2.05, 1, 2.9, 11.5); cam_make(&c1, V1, P);
    tsr_reproj(c0.vp, c1.vp, 0, R); args_make(&a, R, c1.p, c0.p, 0, 0, 2);
    run(dev, q, ps, dcur, dsame, &a, mv, st);
    double worst = 0, sum = 0;
    for (int y = 0; y < H; y++) for (int x = 0; x < W; x++) {
        double nx = (x + 0.5) / W * 2 - 1, ny = 1 - (y + 0.5) / H * 2, mu, mvv; tsr_motion_uv(R, nx, ny, D, 0, 0, 1, &mu, &mvv);
        double gx = (double)mv[2 * (y * W + x)], gy = (double)mv[2 * (y * W + x) + 1];
        worst = fmax(worst, fmax(fabs(gx - mu) * W, fabs(gy - mvv) * H)); sum += sqrt(mu * mu * W * W + mvv * mvv * H * H); }
    printf("    turn and step: mean |motion| %.2f px, worst difference %.4f px\n", sum / (W * H), worst);
    ok("turn and step: the kernel's motion matches the CPU's within 0.02 px at every pixel", worst < 0.02);
    ok("turn and step: there is motion to match (mean above 0.5 px)", sum / (W * H) > 0.5);
    ok("statistics count every pixel", st[0] == W * H);

    // 2) a still camera rendered with jitter, the previous depth the same: no motion, no disagreement
    float ox = 2 * 0.3f / W, oy = -2 * -0.2f / H; tsr_cam cj = c1; tsr_jitter_rows(cj.vp, ox, oy); tsr_jitter_rows(cj.p, ox, oy);
    tsr_reproj(c1.vp, cj.vp, 0, R); args_make(&a, R, c1.p, c1.p, ox, oy, 3);
    run(dev, q, ps, dcur, dsame, &a, mv, st);
    worst = 0; for (int i = 0; i < W * H * 2; i++) worst = fmax(worst, fabs((double)mv[i]) * (i & 1 ? H : W));
    ok("still camera with jitter: no motion anywhere (below 0.01 px)", worst < 0.01);
    ok("still camera with jitter: every pixel compared with the previous depth or reprojected just outside", st[2] + st[4] == W * H);
    ok("still camera with jitter: none disagrees", st[3] == 0);
    ok("still camera with jitter: only a border row or column within the jitter left the frame", st[4] <= W + H);

    // 3) the same with the previous depth much farther: every compared pixel disagrees
    run(dev, q, ps, dcur, dfar, &a, mv, st);
    ok("previous depth far away: every compared pixel disagrees", st[2] > 0 && st[3] == st[2]);

    printf("%s\n", fail ? "FAILED" : "all passed");
    return fail != 0;
} }
