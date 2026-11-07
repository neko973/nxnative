// The camera math of the temporal upscaler (nvn_mtl.m tsr_*, DM_UPSCALER=metalfx-temporal), in plain C so dm/gfx/tests/t_tsr.c checks it on the CPU.
// Ocarina of Time (Switch 2) keeps its camera in one 13568-byte per-view uniform block, bound at uniform slot 0 of the vertex, fragment, task and mesh stages: rows of 16 bytes,
// row-major, clip = M · v. Rows 0-2 are the view matrix V (3x4), rows 3-6 the view-projection VP, rows 7-10 the projection P. The block holds no previous matrix and the game
// renders no motion vectors and no jitter, so the host keeps the previous VP itself and writes camera motion from the scene depth (dm/gfx/msl/tsr.metal).
// Every matrix here is row-major: m[r * 4 + c].
#pragma once
#include <math.h>
#include <stdint.h>
#include <string.h>

enum { TSR_BLOCK_SIZE = 13568 };                                     // the per-view block
enum { TSR_OFF_V = 0, TSR_OFF_VP = 12, TSR_OFF_P = 28 };             // in floats: rows 0, 3 and 7

typedef struct { float v[12], vp[16], p[16]; } tsr_cam;             // as the game wrote them (unjittered)
static inline void tsr_cam_read(const float *blk, tsr_cam *c) { memcpy(c->v, blk + TSR_OFF_V, 48); memcpy(c->vp, blk + TSR_OFF_VP, 64); memcpy(c->p, blk + TSR_OFF_P, 64); }

// ---------- 4x4 in double ----------
static inline void tsr_mul4(const double a[16], const double b[16], double o[16]) {
    double t[16];
    for (int r = 0; r < 4; r++) for (int c = 0; c < 4; c++) { double s = 0; for (int k = 0; k < 4; k++) s += a[r * 4 + k] * b[k * 4 + c]; t[r * 4 + c] = s; }
    memcpy(o, t, sizeof t);
}
// Gauss-Jordan with partial pivoting; 0 when (near) singular
static inline int tsr_inv4(const double m[16], double o[16]) {
    double a[4][8];
    for (int r = 0; r < 4; r++) for (int c = 0; c < 4; c++) { a[r][c] = m[r * 4 + c]; a[r][c + 4] = r == c; }
    double scale = 0; for (int i = 0; i < 16; i++) scale = fmax(scale, fabs(m[i]));
    if (!(scale > 0)) return 0;
    for (int c = 0; c < 4; c++) {
        int p = c; for (int r = c + 1; r < 4; r++) if (fabs(a[r][c]) > fabs(a[p][c])) p = r;
        if (!(fabs(a[p][c]) > scale * 1e-12)) return 0;
        if (p != c) for (int k = 0; k < 8; k++) { double t = a[c][k]; a[c][k] = a[p][k]; a[p][k] = t; }
        double d = 1.0 / a[c][c]; for (int k = 0; k < 8; k++) a[c][k] *= d;
        for (int r = 0; r < 4; r++) if (r != c) { double f = a[r][c]; if (f != 0) for (int k = 0; k < 8; k++) a[r][k] -= f * a[c][k]; }
    }
    for (int r = 0; r < 4; r++) for (int c = 0; c < 4; c++) o[r * 4 + c] = a[r][c + 4];
    return 1;
}
static inline void tsr_f2d(const float *f, double *d, int n) { for (int i = 0; i < n; i++) d[i] = f[i]; }
// V (3x4) as a 4x4 with the row 0, 0, 0, 1
static inline void tsr_v4(const float v[12], double o[16]) { tsr_f2d(v, o, 12); o[12] = o[13] = o[14] = 0; o[15] = 1; }

// ---------- What a block's projection is ----------
// Metal depth from clip z: the translator maps GL clip z (-w..w) to Metal's 0..w as z' = z / 2 + w / 2 unless the game set NVN's near=0 depth mode (depth_zero), when clip z is taken as it is
static inline void tsr_rmat(int depth_zero, double r[16]) { memset(r, 0, 16 * sizeof *r); r[0] = r[5] = r[15] = 1; r[10] = depth_zero ? 1 : 0.5; r[11] = depth_zero ? 0 : 0.5; }
enum { TSR_CLS_OK, TSR_CLS_NOT_PERSP, TSR_CLS_OFFCENTRE, TSR_CLS_VP_MISMATCH, TSR_CLS_ASPECT, TSR_CLS_BAD };
static inline const char *tsr_cls_name(int k) {
    static const char *n[] = {"main-view candidate", "not a perspective projection (a shadow cascade?)", "off-centre projection", "VP is not P x V (other rows?)", "aspect is not the render target's", "not finite"};
    return k >= 0 && k <= TSR_CLS_BAD ? n[k] : "?";
}
// The main camera: P's last row (0, 0, -1, 0) (perspective), no off-centre terms, VP = P x V (the rows are the ones we think), and P11 / P00 the render aspect (want_aspect, 0: not checked)
static inline int tsr_classify(const tsr_cam *c, double want_aspect, double aspect_tol) {
    for (int i = 0; i < 16; i++) if (!isfinite(c->p[i]) || !isfinite(c->vp[i]) || (i < 12 && !isfinite(c->v[i]))) return TSR_CLS_BAD;
    const float *p = c->p;
    if (fabsf(p[12]) > 1e-5f || fabsf(p[13]) > 1e-5f || fabsf(p[14] + 1) > 1e-4f || fabsf(p[15]) > 1e-5f || !(fabsf(p[0]) > 1e-6f) || !(fabsf(p[5]) > 1e-6f)) return TSR_CLS_NOT_PERSP;
    if (fabsf(p[2]) > 1e-4f || fabsf(p[6]) > 1e-4f || fabsf(p[1]) > 1e-5f || fabsf(p[4]) > 1e-5f) return TSR_CLS_OFFCENTRE;
    double P[16], V[16], PV[16]; tsr_f2d(p, P, 16); tsr_v4(c->v, V); tsr_mul4(P, V, PV);
    double mx = 1, err = 0; for (int i = 0; i < 16; i++) { mx = fmax(mx, fabs(PV[i])); err = fmax(err, fabs(PV[i] - c->vp[i])); }
    if (err > 1e-3 * mx) return TSR_CLS_VP_MISMATCH;
    if (want_aspect > 0 && fabs(fabs((double)p[5] / p[0]) / want_aspect - 1) > aspect_tol) return TSR_CLS_ASPECT;
    return TSR_CLS_OK;
}
typedef struct { double vfov_deg, aspect, near_, far_; int reversed; } tsr_proj_info;
// Metal depth of the point at view distance D on the axis
static inline double tsr_depth_at(const float p[16], int depth_zero, double D) {
    double z = p[10] * -D + p[11], w = p[14] * -D + p[15];
    double zm = depth_zero ? z : 0.5 * z + 0.5 * w;
    return w != 0 ? zm / w : 0;
}
static inline void tsr_proj_info_of(const float p[16], int depth_zero, tsr_proj_info *o) {
    o->vfov_deg = 2 * atan(1.0 / fabs((double)p[5])) * 180 / M_PI; o->aspect = fabs((double)p[5] / p[0]);
    double a = p[10], b = p[11];   // GL: P22 = -(f + n) / (f - n), P23 = -2fn / (f - n); near=0 (D3D-style): P22 = -f / (f - n), P23 = -fn / (f - n)
    if (depth_zero) { o->near_ = b / a; o->far_ = b / (a + 1); } else { o->near_ = b / (a - 1); o->far_ = b / (a + 1); }
    double n = isfinite(o->near_) && fabs(o->near_) > 0 ? fabs(o->near_) : 0.1;   // an infinite reversed projection has no finite near from this form
    o->reversed = tsr_depth_at(p, depth_zero, 4 * n) > tsr_depth_at(p, depth_zero, 64 * n);   // farther is smaller: reversed Z
}
// The view distance D from Metal depth d is lin[0] / (d * lin[1] + lin[2]) (for P's last row (0, 0, -1, 0))
static inline void tsr_lin(const float p[16], int depth_zero, float lin[3]) {
    if (depth_zero) { lin[0] = p[11]; lin[1] = 1; lin[2] = p[10]; }      // d = -P22 + P23 / D
    else { lin[0] = p[11]; lin[1] = 2; lin[2] = p[10] - 1; }            // d = (-P22 + P23 / D) / 2 + 1 / 2
}

// ---------- Jitter ----------
static inline float tsr_halton(int i, int b) { float f = 1, r = 0; while (i > 0) { f /= (float)b; r += f * (float)(i % b); i /= b; } return r; }
// The clip position moved by (ox, oy) x w in NDC: rows 0 and 1 of VP and of P each get o x row 3 (the vertex shaders take V then P, or VP; the mesh shaders VP), so x and y move and z, w stay
static inline void tsr_jitter_rows(float m[16], float ox, float oy) { for (int c = 0; c < 4; c++) { m[c] += ox * m[12 + c]; m[4 + c] += oy * m[12 + c]; } }
// Pixel jitter for MetalFX from the NDC offset: x right, y down in the colour texture (ysign +1: NDC +y is row 0, the upper-left window origin; -1: lower left)
static inline void tsr_jitter_px(float ox, float oy, int cw, int ch, float ysign, float *jx, float *jy) { *jx = ox * (float)cw * 0.5f; *jy = -ysign * oy * (float)ch * 0.5f; }
// The patch of one block in guest memory, kept per address. A block still holding the jitter of an earlier frame (the game drew from it again without writing it) is restored first,
// each matrix on its own, so jitter never adds up; the same frame patches once (the replay may meet a binding more than once)
typedef struct { uint64_t addr, frame; float vp_u[16], p_u[16], vp_j[16], p_j[16]; float ox, oy; int live; } tsr_patch_rec;
enum { TSR_PATCH_SKIPPED = 0, TSR_PATCH_DONE = 1, TSR_PATCH_RESTORED_VP = 2, TSR_PATCH_RESTORED_P = 4 };
static inline int tsr_restore_stale(float *blk, tsr_patch_rec *r) {
    if (!r->live) return 0;
    int k = 0;
    if (!memcmp(blk + TSR_OFF_VP, r->vp_j, 64)) { memcpy(blk + TSR_OFF_VP, r->vp_u, 64); k |= TSR_PATCH_RESTORED_VP; }
    if (!memcmp(blk + TSR_OFF_P, r->p_j, 64)) { memcpy(blk + TSR_OFF_P, r->p_u, 64); k |= TSR_PATCH_RESTORED_P; }
    r->live = 0;
    return k;
}
static inline int tsr_patch_block(float *blk, tsr_patch_rec *r, uint64_t addr, uint64_t frame, float ox, float oy) {
    if (r->live && r->addr == addr && r->frame == frame) return TSR_PATCH_SKIPPED;
    int k = r->live && r->addr == addr ? tsr_restore_stale(blk, r) : 0;
    memcpy(r->vp_u, blk + TSR_OFF_VP, 64); memcpy(r->p_u, blk + TSR_OFF_P, 64);
    memcpy(r->vp_j, r->vp_u, 64); memcpy(r->p_j, r->p_u, 64);
    tsr_jitter_rows(r->vp_j, ox, oy); tsr_jitter_rows(r->p_j, ox, oy);
    memcpy(blk + TSR_OFF_VP, r->vp_j, 64); memcpy(blk + TSR_OFF_P, r->p_j, 64);
    r->addr = addr; r->frame = frame; r->ox = ox; r->oy = oy; r->live = 1;
    return k | TSR_PATCH_DONE;
}

// ---------- Motion ----------
// reproj = VP_prev (unjittered) x inverse(R x VP_cur (jittered, as it rasterized)): Metal NDC (x, y, depth, 1) of this frame to the previous frame's clip position, near identity
// for small camera moves (so float on the GPU is enough even with world coordinates in the hundreds)
static inline int tsr_reproj(const float vp_prev[16], const float vpj_cur[16], int depth_zero, double o[16]) {
    double R[16], A[16], B[16], Ai[16]; tsr_rmat(depth_zero, R); tsr_f2d(vpj_cur, B, 16); tsr_mul4(R, B, A);
    if (!tsr_inv4(A, Ai)) return 0;
    tsr_f2d(vp_prev, B, 16); tsr_mul4(B, Ai, o);
    return 1;
}
// MetalFX's motion vector of a pixel, in UV units (motionVectorScale = the content size): from the pixel to where its surface was in the previous frame, both without jitter
// (an object that moved 10 px right and down has -10, -10 px). ndc: the pixel centre in this frame's NDC; d: its Metal depth; (ox, oy): this frame's jitter in NDC
static inline int tsr_motion_uv(const double reproj[16], double ndcx, double ndcy, double d, double ox, double oy, double ysign, double *mu, double *mv) {
    double v[4] = {ndcx, ndcy, d, 1}, pc[4];
    for (int r = 0; r < 4; r++) pc[r] = reproj[r * 4] * v[0] + reproj[r * 4 + 1] * v[1] + reproj[r * 4 + 2] * v[2] + reproj[r * 4 + 3] * v[3];
    if (!(pc[3] > 1e-20)) { *mu = *mv = 0; return 0; }   // behind the previous camera
    double dx = pc[0] / pc[3] - (ndcx - ox), dy = pc[1] / pc[3] - (ndcy - oy);
    *mu = 0.5 * dx; *mv = -0.5 * ysign * dy;
    return 1;
}

// ---------- Camera cuts ----------
// Camera position and forward direction from V = [R | t] (view = R x world + t): position -R^T t, forward -row 2 (the camera looks down -z)
static inline void tsr_pose(const float v[12], double pos[3], double fwd[3]) {
    for (int i = 0; i < 3; i++) { pos[i] = -(v[i] * v[3] + v[4 + i] * v[7] + v[8 + i] * v[11]); fwd[i] = -v[8 + i]; }
    double n = sqrt(fwd[0] * fwd[0] + fwd[1] * fwd[1] + fwd[2] * fwd[2]); if (n > 0) for (int i = 0; i < 3; i++) fwd[i] /= n;
}
typedef struct { double turn_deg, move, fov_ratio; } tsr_delta;
static inline void tsr_cam_delta(const tsr_cam *a, const tsr_cam *b, tsr_delta *o) {
    double pa[3], fa[3], pb[3], fb[3]; tsr_pose(a->v, pa, fa); tsr_pose(b->v, pb, fb);
    double dot = fa[0] * fb[0] + fa[1] * fb[1] + fa[2] * fb[2]; dot = dot > 1 ? 1 : dot < -1 ? -1 : dot;
    o->turn_deg = acos(dot) * 180 / M_PI;
    o->move = sqrt((pa[0] - pb[0]) * (pa[0] - pb[0]) + (pa[1] - pb[1]) * (pa[1] - pb[1]) + (pa[2] - pb[2]) * (pa[2] - pb[2]));
    o->fov_ratio = fabs((double)b->p[5]) > 0 ? fabs((double)a->p[5] / b->p[5]) : 0;
}
// A cut (history useless): a turn past max_turn degrees in one frame, a move past max_move units, or the FOV changing by more than max_fov (relative)
static inline int tsr_is_cut(const tsr_delta *d, double max_turn, double max_move, double max_fov) {
    return !isfinite(d->turn_deg) || !isfinite(d->move) || d->turn_deg > max_turn || d->move > max_move || !(d->fov_ratio > 0) || fabs(d->fov_ratio - 1) > max_fov;
}

// ---------- Which block is the main view (by role) ----------
// Each block seen at slot 0 with the per-view size this frame, with the depth attachments of the passes its draws went to. At the upscaler dispatch the main view is the candidate
// that classifies as the main camera for the input's aspect and has the most draws into a Depth32Float attachment holding the upscaler input's content at its origin (the scene depth:
// at least the input's size, of its shape)
enum { TSR_CAND_DEPTHS = 4 };
typedef struct { uint64_t ser; uint32_t w, h, draws; int fmt_ok; } tsr_cand_depth;
typedef struct { uint64_t addr; tsr_cam cam; int cls; uint32_t draws; tsr_cand_depth d[TSR_CAND_DEPTHS]; int nd; } tsr_cand;
static inline void tsr_cand_note(tsr_cand *c, uint64_t ser, uint32_t w, uint32_t h, int fmt_ok) {
    c->draws++;
    if (!ser) return;
    for (int i = 0; i < c->nd; i++) if (c->d[i].ser == ser) { c->d[i].draws++; return; }
    if (c->nd < TSR_CAND_DEPTHS) { c->d[c->nd++] = (tsr_cand_depth){ser, w, h, 1, fmt_ok}; return; }
    int lo = 0; for (int i = 1; i < c->nd; i++) if (c->d[i].draws < c->d[lo].draws) lo = i;   // the least drawn makes room
    if (c->d[lo].draws <= 1) c->d[lo] = (tsr_cand_depth){ser, w, h, 1, fmt_ok};
}
enum { TSR_PICK_NONE = -1, TSR_PICK_NO_CLASS = -2, TSR_PICK_NO_DEPTH = -3 };
// → the candidate's index (*depth_i: its depth entry), or a TSR_PICK_* reason
static inline int tsr_pick(const tsr_cand *c, int n, uint32_t cw, uint32_t ch, double aspect_tol, int *depth_i) {
    int best = -1, bd = -1, cls_ok = 0; uint32_t bn = 0;
    double want = ch ? (double)cw / ch : 0;
    for (int i = 0; i < n; i++) {
        if (c[i].cls != TSR_CLS_OK || tsr_classify(&c[i].cam, want, aspect_tol) != TSR_CLS_OK) continue;
        cls_ok = 1;
        for (int k = 0; k < c[i].nd; k++) { const tsr_cand_depth *e = &c[i].d[k];
            int shape = e->h && want > 0 && fabs((double)e->w / e->h / want - 1) < aspect_tol;
            if (e->fmt_ok && e->w >= cw && e->h >= ch && shape && e->draws > bn) { bn = e->draws; best = i; bd = k; } }
    }
    if (best < 0) return !n ? TSR_PICK_NONE : !cls_ok ? TSR_PICK_NO_CLASS : TSR_PICK_NO_DEPTH;
    *depth_i = bd; return best;
}
