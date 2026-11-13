// Mac-only motion of Switch Joy-Cons (the first Switch's, paired in macOS's Bluetooth settings). macOS reads their buttons and sticks from report 0x30 but never switches the
// sensor on, and GameController gives a "Joy-Con (L/R)" no GCMotion at all: every report's IMU bytes are zero (measured on a left and a right Joy-Con, macOS 27: 0 of 260
// reports with data, 186 of 198 once asked). So the host asks for the sensor itself: one output report 0x01 with subcommand 0x40 = 1 (enable the IMU) and neutral rumble, on
// its nonexclusive HID handle; macOS keeps the device, its buttons and its rumble. The reports are then read as the Pro Controller's (motion_pro.h: the same layout and sensor).
// Axes: a left Joy-Con's are the Pro Controller's; a right Joy-Con's sensor is turned half a turn about the long axis, so its raw y and z are negated (as SDL and Linux
// hid-nintendo do), which in the Switch frame negates x and z (jc_motion_side).
// Gyro offsets: at rest a Joy-Con's raw rates are a few degrees per second off zero (measured: 2.0, -3.6, -1.5 on a right one), which a game that aims by the rates shows as a
// slow creep. The console subtracts the factory calibration, so the host reads it first: subcommand 0x10 (SPI read) of 24 bytes at 0x6020, whose third triple is the gyro's
// origin, answered in an input report 0x21 (data from byte 20); the sensor is asked for once that answer is in, or after half a second without one (then no offsets).
// Routing: GameController shows a left and a right Joy-Con as one controller with no HID identity, so only one such controller with one right Joy-Con is paired without
// guessing (DM_MOTION_JOYCON_SIDE=L: one left); its sensor is that player's six-axis sensor (dm_motion_set_hid). A single Joy-Con held sideways is not read.
// The sensor is switched off again when the game loses the input (and so when it quits in the ordinary way). DM_MOTION=0 or DM_MOTION_HID=0 turns all of this off.
// All callbacks run on the main run loop, as motion_pro_mac.h's.
#pragma once
#include "motion_pro.h"

enum { JC_PID_LEFT = 0x2006, JC_PID_RIGHT = 0x2007, JC_ASK_AFTER = 120, JC_ASK_MAX = 5,   // ask again after 120 empty reports (about 2 s), 5 times at most
       JC_CAL_WAIT = 30, JC_CAL_MAX = 700 };   // reports to wait for the calibration; the largest offset believed, in counts (49 degrees/s)
// The player a Joy-Con's sensor drives: one Joy-Con of the wanted side and one "Joy-Con (L/R)" controller, or none (-1)
static inline int jc_motion_player(int devices, int controllers, int player) { return devices == 1 && controllers == 1 ? player : -1; }
// A sample decoded as a Pro Controller's (motion_pro.h), for the Joy-Con it came from
static inline void jc_motion_side(pro_motion_sample *s, int pid) {
    if (pid != JC_PID_RIGHT) return;
    s->acc[0] = -s->acc[0]; s->acc[2] = -s->acc[2]; s->rot[0] = -s->rot[0]; s->rot[2] = -s->rot[2];
}
// Output report 0x01: packet number, neutral rumble for both motors, a subcommand and its arguments. on 0 / 1: subcommand 0x40, the IMU off / on;
// on < 0: subcommand 0x10, read the factory calibration of the sensor (24 bytes of SPI flash at 0x6020)
static inline void jc_motion_request(uint8_t out[49], uint8_t seq, int on) {
    static const uint8_t head[10] = {0x01, 0, 0x00, 0x01, 0x40, 0x40, 0x00, 0x01, 0x40, 0x40};
    for (int i = 0; i < 49; i++) out[i] = i < 10 ? head[i] : 0;
    out[1] = seq & 0xf;
    if (on < 0) { out[10] = 0x10; out[11] = 0x20; out[12] = 0x60; out[15] = 0x18; }
    else { out[10] = 0x40; out[11] = on ? 1 : 0; }
}
// The gyro's origin (raw counts at rest, x y z) from the answer to that read; 0 for any other report or an origin beyond belief
static inline int jc_motion_cal(const uint8_t *r, size_t len, int16_t origin[3]) {
    if (len < 44 || r[0] != 0x21 || r[14] != 0x10 || r[15] != 0x20 || r[16] != 0x60 || r[17] || r[18] || r[19] != 0x18) return 0;
    for (int i = 0; i < 3; i++) {
        int16_t v = (int16_t)((uint16_t)r[32 + 2 * i] | (uint16_t)r[33 + 2 * i] << 8);
        if (v > JC_CAL_MAX || v < -JC_CAL_MAX) return 0;
        origin[i] = v;
    }
    return 1;
}
// The origin taken off a sample decoded as a Pro Controller's (its rates are -y, x, z of the raw ones; before jc_motion_side)
static inline void jc_motion_origin(pro_motion_sample *s, const int16_t origin[3]) {
    const float rad = 0.070f * (float)M_PI / 180.f;
    s->rot[0] += origin[1] * rad; s->rot[1] -= origin[0] * rad; s->rot[2] -= origin[2] * rad;
}

#ifndef JC_MOTION_PURE   // the test takes only the functions above (t_motion_joycon.c)
#import <IOKit/hid/IOHIDManager.h>
#import <GameController/GCSyntheticDeviceKeys.h>
#include "dm_input.h"
#include <stdlib.h>
typedef struct jc_device { IOHIDDeviceRef hid; int pid, empty, asked, said, cal; int16_t origin[3]; uint8_t seq, report[512]; pro_motion motion; struct jc_device *next; } jc_device;
static IOHIDManagerRef g_jc_manager;
static jc_device *g_jc_devices, *g_jc_bound;
static int g_jc_player = -1, g_jc_active = 1, g_jc_controllers, g_jc_slot = -1, g_jc_side = JC_PID_RIGHT;
static void (*g_jc_changed)(void);

static void jc_imu(jc_device *d, int on) {
    uint8_t o[49]; jc_motion_request(o, d->seq++, on);
    IOReturn r = IOHIDDeviceSetReport(d->hid, kIOHIDReportTypeOutput, 0x01, o, sizeof o);
    if (on > 0) d->asked++;
    d->empty = 0;
    if (r != kIOReturnSuccess && !d->said) { d->said = 1; LOG("[RED] Joy-Con raw motion: a request to the Joy-Con failed (0x%x)", r); }
}
static void jc_begin(jc_device *d) { d->motion = (pro_motion){0}; d->asked = 0; jc_imu(d, d->cal ? 1 : -1); }   // the calibration first, once
static void jc_route(void) {
    int n = 0; jc_device *one = NULL;
    for (jc_device *d = g_jc_devices; d; d = d->next) if (d->pid == g_jc_side) { n++; one = d; }
    int p = jc_motion_player(n, g_jc_controllers, g_jc_slot);
    jc_device *d = p >= 0 ? one : NULL;
    if (d == g_jc_bound && p == g_jc_player) return;
    if (g_jc_player >= 0) dm_motion_clear_hid(g_jc_player);
    if (g_jc_bound && g_jc_bound != d && g_jc_bound->motion.seen) jc_imu(g_jc_bound, 0);
    g_jc_bound = d; g_jc_player = p;
    if (!d) return;
    LOG("[hid] Joy-Con raw motion: player %d, the %s Joy-Con's sensor (report 0x30, switched on by the host)", p + 1, d->pid == JC_PID_RIGHT ? "right" : "left");
    if (g_jc_active) jc_begin(d);
}
static void dm_motion_joycon_players(int controllers, int slot) { g_jc_controllers = controllers; g_jc_slot = slot; jc_route(); }
static void dm_motion_joycon_active(int active) {
    if (active == g_jc_active) return;
    g_jc_active = active;
    if (!g_jc_bound) return;
    if (active) jc_begin(g_jc_bound); else { g_jc_bound->motion = (pro_motion){0}; jc_imu(g_jc_bound, 0); }
    if (!active && g_jc_player >= 0) dm_motion_clear_hid(g_jc_player);
}
static void jc_report(void *ctx, IOReturn result, void *sender, IOHIDReportType type, uint32_t report_id, uint8_t *r, CFIndex len) {
    (void)sender;
    jc_device *d = ctx;
    if (result != kIOReturnSuccess || type != kIOHIDReportTypeInput || len < 49 || !g_jc_active || d != g_jc_bound) return;
    if (report_id == 0x21 && !d->cal && jc_motion_cal(r, (size_t)len, d->origin)) {
        d->cal = 1; LOG("[hid] Joy-Con raw motion: gyro origin %d %d %d counts (factory calibration)", d->origin[0], d->origin[1], d->origin[2]);
        if (!d->asked) jc_imu(d, 1);
        return;
    }
    if (report_id != 0x30) return;
    pro_motion_sample s[3];
    int was = d->motion.live, n = pro_motion_decode(&d->motion, r, (size_t)len, now_ns(), s);
    if (!d->motion.live) {   // no data yet: the request was lost, or macOS set the Joy-Con up again after it
        if (++d->empty < (d->asked ? JC_ASK_AFTER : JC_CAL_WAIT)) return;
        if (!d->asked && !d->cal) LOG("[hid] Joy-Con raw motion: no calibration answer; its gyro is used without offsets");
        if (d->asked < JC_ASK_MAX) jc_imu(d, 1);
        else if (d->asked == JC_ASK_MAX) { d->asked++; d->empty = 0; LOG("[RED] Joy-Con raw motion: no sensor data after %d requests; this Joy-Con has no motion", JC_ASK_MAX); }
        return;
    }
    if (!was) LOG("[hid] Joy-Con raw motion: sensor data arriving (player %d)", g_jc_player + 1);
    for (int i = 0; i < n; i++) { if (d->cal) jc_motion_origin(&s[i], d->origin); jc_motion_side(&s[i], d->pid); dm_motion_set_hid(g_jc_player, s[i].acc, s[i].rot, s[i].ns); }
}
static void jc_found(void *ctx, IOReturn result, void *sender, IOHIDDeviceRef hid) {
    (void)ctx; (void)sender;
    if (result != kIOReturnSuccess || IOHIDDeviceGetProperty(hid, CFSTR(kIOHIDGCSyntheticDeviceKey)) == kCFBooleanTrue) return;
    for (jc_device *d = g_jc_devices; d; d = d->next) if (d->hid == hid) return;
    jc_device *d = calloc(1, sizeof *d); if (!d) { LOG("[RED] Joy-Con raw motion: cannot allocate device state"); return; }
    CFTypeRef pid = IOHIDDeviceGetProperty(hid, CFSTR(kIOHIDProductIDKey));
    if (pid && CFGetTypeID(pid) == CFNumberGetTypeID()) CFNumberGetValue(pid, kCFNumberIntType, &d->pid);
    d->hid = (IOHIDDeviceRef)CFRetain(hid); d->next = g_jc_devices; g_jc_devices = d;
    IOHIDDeviceRegisterInputReportCallback(hid, d->report, sizeof d->report, jc_report, d);
    if (g_jc_changed) g_jc_changed(); else jc_route();
}
static void jc_removed(void *ctx, IOReturn result, void *sender, IOHIDDeviceRef hid) {
    (void)ctx; (void)result; (void)sender;
    jc_device **link = &g_jc_devices;
    while (*link && (*link)->hid != hid) link = &(*link)->next;
    if (!*link) return;
    jc_device *d = *link; *link = d->next;
    IOHIDDeviceRegisterInputReportCallback(hid, d->report, sizeof d->report, NULL, NULL);   // while its buffer and context still exist
    if (d == g_jc_bound) { g_jc_bound = NULL; if (g_jc_player >= 0) dm_motion_clear_hid(g_jc_player); g_jc_player = -1; }
    if (g_jc_changed) g_jc_changed(); else jc_route();
    CFRelease(d->hid); free(d);
}
static void dm_motion_joycon_start(void (*changed)(void)) {
    const char *e = getenv("DM_MOTION"); if (e && !atoi(e)) return;
    e = getenv("DM_MOTION_HID"); if (e && !atoi(e)) return;
    e = getenv("DM_MOTION_JOYCON_SIDE"); if (e && (*e == 'L' || *e == 'l')) g_jc_side = JC_PID_LEFT;
    g_jc_changed = changed;
    g_jc_manager = IOHIDManagerCreate(kCFAllocatorDefault, kIOHIDOptionsTypeNone); if (!g_jc_manager) return;
    IOHIDManagerSetDeviceMatchingMultiple(g_jc_manager, (__bridge CFArrayRef)@[@{@kIOHIDVendorIDKey: @0x057E, @kIOHIDProductIDKey: @(JC_PID_LEFT)},
                                                                              @{@kIOHIDVendorIDKey: @0x057E, @kIOHIDProductIDKey: @(JC_PID_RIGHT)}]);
    IOHIDManagerRegisterDeviceMatchingCallback(g_jc_manager, jc_found, NULL);
    IOHIDManagerRegisterDeviceRemovalCallback(g_jc_manager, jc_removed, NULL);
    IOHIDManagerScheduleWithRunLoop(g_jc_manager, CFRunLoopGetMain(), kCFRunLoopCommonModes);
    IOReturn r = IOHIDManagerOpen(g_jc_manager, kIOHIDOptionsTypeNone);   // nonexclusive: macOS keeps the device
    if (r != kIOReturnSuccess) {
        LOG("[RED] Joy-Con raw motion: cannot open HID (0x%x); Joy-Cons have no motion", r);
        IOHIDManagerUnscheduleFromRunLoop(g_jc_manager, CFRunLoopGetMain(), kCFRunLoopCommonModes);
        CFRelease(g_jc_manager); g_jc_manager = NULL;
    }
}
#endif
