#define JC_MOTION_PURE
#include "../motion_joycon_mac.h"
#include <assert.h>
#include <stdio.h>
#include <string.h>

static int near(float a, float b) { return fabsf(a - b) < 1e-5f; }
int main(void) {
    // One Joy-Con of the wanted side and one "Joy-Con (L/R)" controller, nothing else
    assert(jc_motion_player(1, 1, 2) == 2 && jc_motion_player(2, 1, 0) < 0 && jc_motion_player(1, 2, 0) < 0 && jc_motion_player(0, 1, 0) < 0);
    // The requests: the IMU on and off, the calibration read
    uint8_t o[49]; memset(o, 0xee, sizeof o);
    jc_motion_request(o, 0x13, 1);
    static const uint8_t on[12] = {0x01, 0x03, 0x00, 0x01, 0x40, 0x40, 0x00, 0x01, 0x40, 0x40, 0x40, 0x01};
    assert(!memcmp(o, on, 12)); for (int i = 12; i < 49; i++) assert(!o[i]);
    jc_motion_request(o, 4, 0); assert(o[1] == 4 && o[10] == 0x40 && o[11] == 0);
    jc_motion_request(o, 5, -1);
    static const uint8_t spi[6] = {0x10, 0x20, 0x60, 0x00, 0x00, 0x18};
    assert(!memcmp(o + 10, spi, 6) && !o[16]);
    // The answer to the read: the gyro's origin is the third triple of the data, which starts at byte 20
    uint8_t r[49] = {0x21}; int16_t g[3] = {7, 7, 7};
    r[13] = 0x90; r[14] = 0x10; r[15] = 0x20; r[16] = 0x60; r[19] = 0x18;
    r[32] = 24; r[34] = 0xcf; r[35] = 0xff; r[36] = 0xee; r[37] = 0xff;   // 24, -49, -18: a right Joy-Con's
    assert(jc_motion_cal(r, sizeof r, g) && g[0] == 24 && g[1] == -49 && g[2] == -18);
    r[14] = 0x40; assert(!jc_motion_cal(r, sizeof r, g)); r[14] = 0x10;   // the answer to another subcommand
    r[15] = 0x26; assert(!jc_motion_cal(r, sizeof r, g)); r[15] = 0x20;   // another address
    r[0] = 0x30; assert(!jc_motion_cal(r, sizeof r, g)); r[0] = 0x21;
    assert(!jc_motion_cal(r, 43, g));
    r[33] = 0x40; assert(!jc_motion_cal(r, sizeof r, g)); r[33] = 0;   // an origin beyond belief (erased flash): none
    // At rest the raw rates are the origin: the decoded sample, less the origin, is zero. Raw 24, -49, -18 decode to rates 49, 24, -18 counts
    const float rad = 0.070f * (float)M_PI / 180.f;
    pro_motion_sample s = {{0.25f, 0.5f, -0.75f}, {49 * rad, 24 * rad, -18 * rad}, 0};
    jc_motion_origin(&s, g); assert(near(s.rot[0], 0) && near(s.rot[1], 0) && near(s.rot[2], 0));
    // A left Joy-Con keeps the Pro Controller's axes; a right one's x and z are the other way round, acceleration and rates alike
    pro_motion_sample l = {{0.25f, 0.5f, -0.75f}, {1, 2, 3}, 0}, q = l;
    jc_motion_side(&l, JC_PID_LEFT); assert(l.acc[0] == 0.25f && l.acc[2] == -0.75f && l.rot[0] == 1 && l.rot[2] == 3);
    jc_motion_side(&q, JC_PID_RIGHT); assert(q.acc[0] == -0.25f && q.acc[1] == 0.5f && q.acc[2] == 0.75f && q.rot[0] == -1 && q.rot[1] == 2 && q.rot[2] == -3);
    puts("t_motion_joycon ok");
    return 0;
}
