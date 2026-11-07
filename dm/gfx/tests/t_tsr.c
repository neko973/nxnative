// CPU tests of the temporal upscaler's camera math (dm/gfx/nvn/nvn_tsr.h; nvn_mtl.m tsr_*, dm/gfx/msl/tsr.metal): which uniform block is the main view, the motion vectors a
// camera move gives (expected values from the geometry: a 1 degree turn moves the picture's centre by tan(1 deg) x P00 in NDC, 7.19 px at 683 px wide), that a jittered frame of a
// still camera has no motion, that the jitter moves the picture by the pixels MetalFX is told, that a block is patched once a frame and never accumulates jitter, the cut tests,
// and that the float math the GPU does stays within a hundredth of a pixel of the double math far from the world origin.
#include "../nvn/nvn_tsr.h"
#include <stdio.h>
#include <stdlib.h>

static int fail, total;
static void ok(const char *name, int cond) { total++; fail += !cond; printf("%-86s %s\n", name, cond ? "ok" : "FAILED"); }
static void near_(const char *name, double got, double want, double tol) {
    total++; int good = fabs(got - want) <= tol; fail += !good;
    printf("%-86s %s (got %.6g, want %.6g ± %.2g)\n", name, good ? "ok" : "FAILED", got, want, tol);
}

// A GL perspective projection (clip z -w..w), row-major
static void persp_gl(float p[16], double vfov_deg, double aspect, double n, double f) {
    memset(p, 0, 64); double t = 1 / tan(vfov_deg * M_PI / 360);
    p[0] = (float)(t / aspect); p[5] = (float)t; p[10] = (float)(-(f + n) / (f - n)); p[11] = (float)(-2 * f * n / (f - n)); p[14] = -1;
}
static void ortho_gl(float p[16], double w, double h, double n, double f) {
    memset(p, 0, 64); p[0] = (float)(2 / w); p[5] = (float)(2 / h); p[10] = (float)(-2 / (f - n)); p[11] = (float)(-(f + n) / (f - n)); p[15] = 1;
}
// V for a camera at pos, turned yaw degrees to its right about +y and pitch degrees up (looking down -z at 0, 0)
static void view(float v[12], double px, double py, double pz, double yaw, double pitch) {
    double y = yaw * M_PI / 180, pi = pitch * M_PI / 180;
    double f[3] = {sin(y) * cos(pi), sin(pi), -cos(y) * cos(pi)};   // forward
    double r[3] = {cos(y), 0, sin(y)};                               // right
    double u[3] = {r[1] * f[2] - r[2] * f[1], r[2] * f[0] - r[0] * f[2], r[0] * f[1] - r[1] * f[0]};   // up = right x forward
    double rows[3][3] = {{r[0], r[1], r[2]}, {u[0], u[1], u[2]}, {-f[0], -f[1], -f[2]}}, pos[3] = {px, py, pz};
    for (int i = 0; i < 3; i++) { double t = 0; for (int k = 0; k < 3; k++) { v[i * 4 + k] = (float)rows[i][k]; t -= rows[i][k] * pos[k]; } v[i * 4 + 3] = (float)t; }
}
static void cam_make(tsr_cam *c, const float v[12], const float p[16]) {
    memcpy(c->v, v, 48); memcpy(c->p, p, 64);
    double P[16], V[16], PV[16]; tsr_f2d(p, P, 16); tsr_v4(v, V); tsr_mul4(P, V, PV);
    for (int i = 0; i < 16; i++) c->vp[i] = (float)PV[i];
}
static void block_make(float *blk, const tsr_cam *c) { memset(blk, 0, TSR_BLOCK_SIZE); memcpy(blk + TSR_OFF_V, c->v, 48); memcpy(blk + TSR_OFF_VP, c->vp, 64); memcpy(blk + TSR_OFF_P, c->p, 64); }
// A world point's Metal NDC (x, y, depth) through vp (GL clip z mapped as the translator does)
static void project(const float vp[16], const double X[3], double ndc[3]) {
    double c[4]; for (int r = 0; r < 4; r++) c[r] = vp[r * 4] * X[0] + vp[r * 4 + 1] * X[1] + vp[r * 4 + 2] * X[2] + vp[r * 4 + 3];
    ndc[0] = c[0] / c[3]; ndc[1] = c[1] / c[3]; ndc[2] = (0.5 * c[2] + 0.5 * c[3]) / c[3];
}
// The pixel position (x right, y down) of NDC in a w x h target with the upper-left origin
static void to_px(const double ndc[3], int w, int h, double *x, double *y) { *x = (ndc[0] + 1) * 0.5 * w; *y = (1 - ndc[1]) * 0.5 * h; }

int main(void) {
    const int CW = 683, CH = 384; const double ASPECT = 16.0 / 9;
    float P[16], Po[16], Pc[16], V0[12], V1[12];
    persp_gl(P, 50, ASPECT, 0.1, 25000);

    // ---------- Halton (2, 3) ----------
    near_("halton base 2, index 1..3: 1/2", tsr_halton(1, 2), 0.5, 1e-7);
    near_("halton base 2, index 2: 1/4", tsr_halton(2, 2), 0.25, 1e-7);
    near_("halton base 2, index 3: 3/4", tsr_halton(3, 2), 0.75, 1e-7);
    near_("halton base 3, index 1: 1/3", tsr_halton(1, 3), 1.0 / 3, 1e-7);
    near_("halton base 3, index 2: 2/3", tsr_halton(2, 3), 2.0 / 3, 1e-7);
    near_("halton base 3, index 3: 1/9", tsr_halton(3, 3), 1.0 / 9, 1e-7);

    // ---------- Projection facts and classification ----------
    tsr_proj_info pi; tsr_proj_info_of(P, 0, &pi);
    near_("forest projection: vertical FOV 50 deg", pi.vfov_deg, 50, 1e-3);
    near_("forest projection: aspect 16:9", pi.aspect, ASPECT, 1e-5);
    near_("forest projection: near 0.1", pi.near_, 0.1, 1e-4);
    ok("forest projection: far about 25000 (float P)", fabs(pi.far_ - 25000) < 300);
    ok("forest projection: depth not reversed", !pi.reversed);
    near_("P00 of a 50 deg, 16:9 projection is 1.20629 (the dumps' VP / V ratio)", P[0], 1.20629, 2e-5);
    { float Pr[16]; memset(Pr, 0, 64); double t = 1 / tan(25 * M_PI / 180); Pr[0] = (float)(t / ASPECT); Pr[5] = (float)t; Pr[11] = 0.1f; Pr[14] = -1;   // infinite reversed Z, near=0 mode: d = n / D
      tsr_proj_info_of(Pr, 1, &pi); ok("an infinite reversed-Z projection (near=0 mode) reads as reversed", pi.reversed); }
    { float lin[3]; tsr_lin(P, 0, lin); double worst = 0;
      for (double D = 0.2; D < 1000; D *= 1.7) { float d = (float)tsr_depth_at(P, 0, D), back = lin[0] / (d * lin[1] + lin[2]); worst = fmax(worst, fabs(back / D - 1)); }
      ok("view distance from float Metal depth (tsr_lin, in float as the kernel) within 0.2% out to 1000 units (GL mode)", worst < 2e-3);
      printf("    (worst relative error %.2g)\n", worst); }
    view(V0, 3.1, 1.6, -2.2, 24, -8);
    tsr_cam main_; cam_make(&main_, V0, P);
    ok("main camera classifies as the main view (16:9 render target)", tsr_classify(&main_, ASPECT, 0.02) == TSR_CLS_OK);
    ok("main camera against a 170x96 HiZ viewport (aspect within 2%)", tsr_classify(&main_, 170.0 / 96, 0.02) == TSR_CLS_OK);
    ortho_gl(Po, 40, 40, 1, 500); tsr_cam casc; cam_make(&casc, V0, Po);
    ok("a shadow cascade (orthographic) is not the main view", tsr_classify(&casc, ASPECT, 0.02) == TSR_CLS_NOT_PERSP);
    persp_gl(Pc, 90, 1, 0.1, 1000); tsr_cam probe; cam_make(&probe, V0, Pc);
    ok("a cube probe face (90 deg, 1:1) fails the 16:9 aspect", tsr_classify(&probe, ASPECT, 0.02) == TSR_CLS_ASPECT);
    tsr_cam off = main_; off.p[2] = 0.01f; ok("an off-centre projection (P02 = 0.01) is refused", tsr_classify(&off, ASPECT, 0.02) == TSR_CLS_OFFCENTRE);
    tsr_cam mis = main_; view(V1, 30, 1.6, -2.2, 24, -8); memcpy(mis.v, V1, 48); ok("VP that is not P x V (rows misread) is refused", tsr_classify(&mis, ASPECT, 0.02) == TSR_CLS_VP_MISMATCH);
    tsr_cam nan_ = main_; nan_.vp[3] = NAN; ok("a non-finite block is refused", tsr_classify(&nan_, ASPECT, 0.02) == TSR_CLS_BAD);
    { float *blk = calloc(1, TSR_BLOCK_SIZE); block_make(blk, &main_); tsr_cam rd; tsr_cam_read(blk, &rd);
      ok("tsr_cam_read takes rows 0-2 (V), 3-6 (VP), 7-10 (P) of the block", !memcmp(rd.v, main_.v, 48) && !memcmp(rd.vp, main_.vp, 64) && !memcmp(rd.p, main_.p, 64)); free(blk); }

    // ---------- Motion ----------
    double R[16], mu, mv;
    ok("reproj of a still camera", tsr_reproj(main_.vp, main_.vp, 0, R));
    { double worst = 0; for (double x = -0.9; x <= 0.9; x += 0.3) for (double d = 0.5; d < 1; d += 0.07) { tsr_motion_uv(R, x, -x * 0.5, d, 0, 0, 1, &mu, &mv); worst = fmax(worst, fmax(fabs(mu * CW), fabs(mv * CH))); }
      ok("a still camera gives no motion anywhere (< 1e-4 px)", worst < 1e-4); }
    // a 1 degree turn to the right: the surface now at the centre was 7.19 px to the right (its motion points there: +x)
    tsr_cam yaw1; view(V1, 3.1, 1.6, -2.2, 25, -8); cam_make(&yaw1, V1, P);
    { tsr_cam y0; view(V0, 3.1, 1.6, -2.2, 24, 0); cam_make(&y0, V0, P); view(V1, 3.1, 1.6, -2.2, 25, 0); cam_make(&yaw1, V1, P);
      tsr_reproj(y0.vp, yaw1.vp, 0, R);
      for (double d = 0.9; d < 1; d += 0.04) { tsr_motion_uv(R, 0, 0, d, 0, 0, 1, &mu, &mv);
        char nm[96]; snprintf(nm, sizeof nm, "1 deg turn right, centre pixel, depth %.2f: +7.19 px (tan 1 deg x P00 x 683 / 2)", d);
        near_(nm, mu * CW, tan(M_PI / 180) * P[0] * CW / 2, 0.01); }
      tsr_motion_uv(R, 0, 0, 0.95, 0, 0, 1, &mu, &mv); near_("1 deg turn right, centre pixel: no vertical motion", mv * CH, 0, 1e-3); }
    // walking forward: a point right of the centre was nearer the centre before (its motion points left), the centre does not move
    { tsr_cam a, b; view(V0, 0, 0, 0, 0, 0); cam_make(&a, V0, P); view(V1, 0, 0, -0.5, 0, 0); cam_make(&b, V1, P); tsr_reproj(a.vp, b.vp, 0, R);
      double X[3] = {1.0, 0.3, -6.0}, n1[3], n0[3]; project(b.vp, X, n1); project(a.vp, X, n0);
      tsr_motion_uv(R, n1[0], n1[1], n1[2], 0, 0, 1, &mu, &mv);
      double x1, y1, x0, y0; to_px(n1, CW, CH, &x1, &y1); to_px(n0, CW, CH, &x0, &y0);
      near_("walking forward: motion of a point right of the centre is its previous pixel minus its pixel (x)", mu * CW, x0 - x1, 1e-3);
      near_("walking forward: the same in y (y down)", mv * CH, y0 - y1, 1e-3);
      ok("walking forward: that point's motion points back toward the centre (x < 0)", mu < 0);
      tsr_motion_uv(R, 0, 0, n1[2], 0, 0, 1, &mu, &mv); ok("walking forward: the centre does not move", fabs(mu * CW) < 1e-4 && fabs(mv * CH) < 1e-4); }

    // ---------- Jitter ----------
    { float jx = 0.31f, jy = -0.22f, ox = 2 * jx / CW, oy = -2 * jy / CH, bx, by;
      tsr_jitter_px(ox, oy, CW, CH, 1, &bx, &by); near_("pixel jitter back from the NDC offset: x", bx, jx, 1e-6); near_("pixel jitter back from the NDC offset: y", by, jy, 1e-6);
      tsr_cam j = main_; tsr_jitter_rows(j.vp, ox, oy); tsr_jitter_rows(j.p, ox, oy);
      double X[3] = {5.0, 1.0, -9.0}, nu[3], nj[3], xu, yu, xj, yj; project(main_.vp, X, nu); project(j.vp, X, nj); to_px(nu, CW, CH, &xu, &yu); to_px(nj, CW, CH, &xj, &yj);
      near_("the jittered projection moves the picture by +jitter (x right): what MetalFX is told", xj - xu, jx, 1e-3);
      near_("... and by +jitter in y (y down)", yj - yu, jy, 1e-3);
      near_("the jitter leaves depth alone", nj[2], nu[2], 1e-9);
      { double P2[16], V2[16], PV2[16]; tsr_f2d(j.p, P2, 16); tsr_v4(j.v, V2); tsr_mul4(P2, V2, PV2); double e = 0; for (int i = 0; i < 16; i++) e = fmax(e, fabs(PV2[i] - j.vp[i]));
        ok("jittered VP stays P x V (the depth prepass through VP and the colour pass through V, P agree)", e < 1e-4); }
      tsr_reproj(main_.vp, j.vp, 0, R); double worst = 0;
      for (double x = -0.9; x <= 0.9; x += 0.3) for (double d = 0.6; d < 1; d += 0.1) { tsr_motion_uv(R, x, 0.4 * x, d, ox, oy, 1, &mu, &mv); worst = fmax(worst, fmax(fabs(mu * CW), fabs(mv * CH))); }
      ok("a still camera rendered with jitter has no motion (the jitter is taken out, < 1e-3 px)", worst < 1e-3);
      tsr_motion_uv(R, nj[0], nj[1], nj[2], ox, oy, 1, &mu, &mv); ok("... also at a jittered sample of a real point", fabs(mu * CW) < 1e-3 && fabs(mv * CH) < 1e-3); }

    // ---------- The patch in the block ----------
    { float *blk = calloc(1, TSR_BLOCK_SIZE); block_make(blk, &main_); tsr_patch_rec r = {0}; uint64_t A = 0x7c32bce500ull;
      float ox = 0.0007f, oy = -0.0011f;
      int k = tsr_patch_block(blk, &r, A, 1, ox, oy);
      ok("first patch of a frame jitters the block", k == TSR_PATCH_DONE);
      ok("rows 2 and 3 of VP and P are unchanged by the jitter", !memcmp(blk + TSR_OFF_VP + 8, main_.vp + 8, 32) && !memcmp(blk + TSR_OFF_P + 8, main_.p + 8, 32));
      ok("V (rows 0-2) is untouched", !memcmp(blk, main_.v, 48));
      near_("VP row 0 gained ox x VP row 3", blk[TSR_OFF_VP + 3], main_.vp[3] + ox * main_.vp[15], 1e-6);
      ok("the same frame patches once (a binding met again in a replay)", tsr_patch_block(blk, &r, A, 1, ox, oy) == TSR_PATCH_SKIPPED && !memcmp(blk + TSR_OFF_VP, r.vp_j, 64));
      tsr_cam jc; tsr_cam_read(blk, &jc); ok("a jittered block no longer classifies as centred (so it is restored before it is read)", tsr_classify(&jc, ASPECT, 0.02) == TSR_CLS_OFFCENTRE);
      k = tsr_patch_block(blk, &r, A, 2, -ox, 0.5f * oy);
      ok("next frame, block not rewritten by the game: restored first (VP and P)", (k & TSR_PATCH_RESTORED_VP) && (k & TSR_PATCH_RESTORED_P));
      ok("... and its unjittered copy is the game's (no jitter added up)", !memcmp(r.vp_u, main_.vp, 64) && !memcmp(r.p_u, main_.p, 64));
      near_("... the new jitter on the game's matrix", blk[TSR_OFF_VP + 3], main_.vp[3] - ox * main_.vp[15], 1e-6);
      block_make(blk, &yaw1); k = tsr_patch_block(blk, &r, A, 3, ox, oy);
      ok("next frame, block rewritten by the game: nothing restored, the new matrix taken", k == TSR_PATCH_DONE && !memcmp(r.vp_u, yaw1.vp, 64));
      k = tsr_restore_stale(blk, &r); ok("restoring a block that still holds our jitter gives the game's matrices back", k == (TSR_PATCH_RESTORED_VP | TSR_PATCH_RESTORED_P) && !memcmp(blk + TSR_OFF_VP, yaw1.vp, 64) && !memcmp(blk + TSR_OFF_P, yaw1.p, 64));
      free(blk); }

    // ---------- Cuts ----------
    { tsr_delta d; tsr_cam a, b; view(V0, 1, 1, 1, 10, 0); cam_make(&a, V0, P);
      view(V1, 1, 1, 1, 11, 0); cam_make(&b, V1, P); tsr_cam_delta(&a, &b, &d); near_("a 1 deg turn measures 1 deg", d.turn_deg, 1, 1e-3); ok("a 1 deg turn is no cut", !tsr_is_cut(&d, 20, 2, 0.15));
      view(V1, 1, 1, 1, 45, 0); cam_make(&b, V1, P); tsr_cam_delta(&a, &b, &d); ok("a 35 deg turn in one frame is a cut", tsr_is_cut(&d, 20, 2, 0.15));
      view(V1, 1, 1, 6, 10, 0); cam_make(&b, V1, P); tsr_cam_delta(&a, &b, &d); near_("a 5 unit jump measures 5", d.move, 5, 1e-4); ok("a 5 unit jump is a cut (2 allowed)", tsr_is_cut(&d, 20, 2, 0.15));
      view(V1, 1, 1, 1.1, 10, 0); cam_make(&b, V1, P); tsr_cam_delta(&a, &b, &d); ok("0.1 units (running) is no cut", !tsr_is_cut(&d, 20, 2, 0.15));
      float Pz[16]; persp_gl(Pz, 62, ASPECT, 0.1, 25000); view(V1, 1, 1, 1, 10, 0); cam_make(&b, V1, Pz); tsr_cam_delta(&a, &b, &d); ok("a 50 -> 62 deg FOV jump is a cut", tsr_is_cut(&d, 20, 2, 0.15)); }

    // ---------- Picking the main view by role ----------
    { tsr_cand c[4]; memset(c, 0, sizeof c); int di = -1;
      c[0].addr = 1; c[0].cam = casc; c[0].cls = tsr_classify(&casc, 0, 0); for (int i = 0; i < 50; i++) tsr_cand_note(&c[0], 603762, 1600, 1600, 1);
      c[1].addr = 2; c[1].cam = main_; c[1].cls = tsr_classify(&main_, 0, 0);
      for (int i = 0; i < 600; i++) tsr_cand_note(&c[1], 603649, 683, 384, 1);
      for (int i = 0; i < 40; i++) tsr_cand_note(&c[1], 603757, 170, 96, 1);
      for (int i = 0; i < 12; i++) tsr_cand_note(&c[1], 603752, 683, 384, 1);
      c[2].addr = 3; c[2].cam = main_; c[2].cls = TSR_CLS_OK; tsr_cand_note(&c[2], 603769, 341, 192, 1); tsr_cand_note(&c[2], 603649, 683, 384, 1);   // the half-resolution view: same camera
      c[3].addr = 4; c[3].cam = probe; c[3].cls = tsr_classify(&probe, 0, 0); tsr_cand_note(&c[3], 14668, 128, 128, 1);
      int i = tsr_pick(c, 4, 683, 384, 0.02, &di);
      ok("the main view is the block with the most draws into the input-sized depth (not the half-res view)", i == 1 && c[1].d[di].ser == 603649);
      ok("the main view's draw count", c[1].draws == 652);
      ok("no candidate: TSR_PICK_NONE", tsr_pick(c, 0, 683, 384, 0.02, &di) == TSR_PICK_NONE);
      ok("only a shadow cascade: TSR_PICK_NO_CLASS", tsr_pick(c, 1, 683, 384, 0.02, &di) == TSR_PICK_NO_CLASS);
      ok("no depth of the input's size (DRS input 911x512): TSR_PICK_NO_DEPTH", tsr_pick(c, 4, 911, 512, 0.02, &di) == TSR_PICK_NO_DEPTH);
      tsr_cand big = c[1]; big.nd = 0; for (int k = 0; k < 9; k++) tsr_cand_note(&big, 77, 2048, 1152, 1);
      ok("a larger depth of the same shape holds the content at its origin: taken", tsr_pick(&big, 1, 683, 384, 0.02, &di) == 0);
      tsr_cand fmt = c[1]; fmt.nd = 0; for (int k = 0; k < 9; k++) tsr_cand_note(&fmt, 78, 683, 384, 0);
      ok("a depth that is not Depth32Float is not taken", tsr_pick(&fmt, 1, 683, 384, 0.02, &di) == TSR_PICK_NO_DEPTH); }

    // ---------- Float on the GPU far from the origin ----------
    { tsr_cam a, b; view(V0, 812.4, 31.7, -1544.9, 33, -6); cam_make(&a, V0, P); view(V1, 812.5, 31.7, -1544.8, 34.2, -6.1); cam_make(&b, V1, P);
      float jx = 0.4f, jy = 0.1f, ox = 2 * jx / CW, oy = -2 * jy / CH; tsr_cam bj = b; tsr_jitter_rows(bj.vp, ox, oy);
      tsr_reproj(a.vp, bj.vp, 0, R); float Rf[16]; for (int i = 0; i < 16; i++) Rf[i] = (float)R[i];
      double worst = 0;
      for (double x = -0.95; x <= 0.95; x += 0.19) for (double d = 0.95; d < 1.0; d += 0.0049) {
          double y = -0.6 * x; tsr_motion_uv(R, x, y, d, ox, oy, 1, &mu, &mv);
          float v4[4] = {(float)x, (float)y, (float)d, 1}, pc[4]; for (int r = 0; r < 4; r++) pc[r] = Rf[r * 4] * v4[0] + Rf[r * 4 + 1] * v4[1] + Rf[r * 4 + 2] * v4[2] + Rf[r * 4 + 3] * v4[3];
          if (!(pc[3] > 0)) continue;
          float fu = 0.5f * (pc[0] / pc[3] - ((float)x - ox)), fv = -0.5f * (pc[1] / pc[3] - ((float)y - oy));
          worst = fmax(worst, fmax(fabs((fu - mu) * CW), fabs((fv - mv) * CH))); }
      ok("float reprojection (as the kernel does) within 0.01 px of double, 1.5 km from the origin", worst < 0.01);
      printf("    (worst float error %.5f px)\n", worst); }

    printf("%d / %d passed\n", total - fail, total);
    return fail != 0;
}
