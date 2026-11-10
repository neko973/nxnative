// Which bits of a game barrier make the next draw pass wait for everything (DM_NVN_BARRIER_GAME_BITS), and the counter behind DM_NVN_BARRIER_WHY. No GPU work: the decision is a function of the bits
// and the switch. The make rule runs it with the switches default and off; the expectations follow the environment it is run in
#include "../nvn/nvn_mtl.m"
void *front_metal_layer(void) { return NULL; }
module_t *module_of(const void *p) { (void)p; return NULL; }
module_t *g_mod; int g_nmod;
void svc_thread_dump(void) {}
uint64_t now_ns(void) { return bp_now(); }
static int checks, failed;
#define CHECK(c, label) do { checks++; if (!(c)) { failed++; fprintf(stderr, "FAIL: %s\n", label); } } while (0)
int main(void) { @autoreleasepool {
    const char *gb = getenv("DM_NVN_BARRIER_GAME_BITS"), *why = getenv("DM_NVN_BARRIER_WHY");
    int wide = !(gb && !strcmp(gb, "0")), why_on = !(why && !strcmp(why, "0"));   // wide: the default rule, only ORDER_PRIMITIVES and ORDER_INDIRECT_DATA wait for everything
    enum { P = NVN_BARRIER_ORDER_PRIMITIVES_BIT, F = NVN_BARRIER_ORDER_FRAGMENTS_BIT, FT = NVN_BARRIER_ORDER_FRAGMENTS_TILED_BIT, I = NVN_BARRIER_ORDER_INDIRECT_DATA_BIT,
           IT = NVN_BARRIER_INVALIDATE_TEXTURE_BIT, IS = NVN_BARRIER_INVALIDATE_SHADER_BIT, ID = NVN_BARRIER_INVALIDATE_TEXTURE_DESCRIPTOR_BIT, IZ = NVN_BARRIER_INVALIDATE_ZCULL_BIT };
    static const struct { unsigned bits; int narrow, wide; const char *what; } t[] = {
        {0,           0, 0, "no bits"},
        {F,           0, 0, "ORDER_FRAGMENTS"},
        {FT,          0, 0, "ORDER_FRAGMENTS_TILED"},
        {F | IT,      0, 0, "0x12, what Ocarina of Time issues about 80 times a frame"},
        {IT | ID | IZ, 0, 0, "texture, descriptor and zcull invalidation"},
        {P,           1, 1, "ORDER_PRIMITIVES"},
        {I,           1, 1, "ORDER_INDIRECT_DATA"},
        {P | F | IT,  1, 1, "ORDER_PRIMITIVES with fragments and a texture invalidation"},
        {P | F | I | IT, 1, 1, "0x1b"},
        {0xff,        1, 1, "every bit"},
        {IS,          1, 0, "INVALIDATE_SHADER alone: the one bit the two rules differ on"},
        {F | IS,      1, 0, "ORDER_FRAGMENTS with INVALIDATE_SHADER"},
        {F | IT | IS, 1, 0, "0x32"},
        {F | IS | I,  1, 1, "INVALIDATE_SHADER with ORDER_INDIRECT_DATA"},
    };
    for (size_t i = 0; i < sizeof t / sizeof *t; i++) {
        char label[160]; snprintf(label, sizeof label, "%s (bits %#x): needs everything = %d", t[i].what, t[i].bits, wide ? t[i].wide : t[i].narrow);
        CHECK(game_barrier_needs_full(t[i].bits) == (wide ? t[i].wide : t[i].narrow), label);
    }
    // the counter: off leaves the stats line out; on hands over the five counters, the last being the passes begun beside the ones before
    uint64_t w[5] = {9, 9, 9, 9, 9};
    CHECK(mtl_barrier_why(w) == why_on, "DM_NVN_BARRIER_WHY decides whether the stats line exists");
    if (why_on) {
        for (int i = 0; i < 5; i++) CHECK(w[i] == 0, "no pass began yet: every counter is 0");
        g_bar_why[0] = 3; g_bar_why[1] = 5; g_bar_why[2] = 7; g_bar_why[3] = 11; g_bar_overlap = 13;
        CHECK(mtl_barrier_why(w) == 1 && w[0] == 3 && w[1] == 5 && w[2] == 7 && w[3] == 11 && w[4] == 13, "the counters are handed over as kept, overlap last");
    }
    printf("t_barrier_bits (GAME_BITS %s, WHY %s): %d checks, %d failed\n", wide ? "wide" : "narrow", why_on ? "on" : "off", checks, failed);
    return failed != 0;
} }
