// BIP-340 Schnorr signatures over secp256k1, for signing Nostr events. The keys are throwaway (a new one on every
// join, protecting nothing: relays just insist on a signature), so this favours being small and checkable over
// being fast or constant-time. Do not reuse it for keys that matter.

#define __STDC_WANT_LIB_EXT1__ 1

#include "lprooms_crypto.h"

#include <CommonCrypto/CommonDigest.h>
#include <string.h>

typedef unsigned __int128 u128;

/// 256 bits, least significant limb first.
typedef struct { uint64_t v[4]; } u256;

/// A modulus m = 2^256 - c.
typedef struct { u256 m, c; } modulus;

// Field prime p = 2^256 - 2^32 - 977.
static const modulus FP = {
    {{0xFFFFFFFEFFFFFC2FULL, 0xFFFFFFFFFFFFFFFFULL, 0xFFFFFFFFFFFFFFFFULL, 0xFFFFFFFFFFFFFFFFULL}},
    {{0x00000001000003D1ULL, 0, 0, 0}},
};
// Group order n.
static const modulus FN = {
    {{0xBFD25E8CD0364141ULL, 0xBAAEDCE6AF48A03BULL, 0xFFFFFFFFFFFFFFFEULL, 0xFFFFFFFFFFFFFFFFULL}},
    {{0x402DA1732FC9BEBFULL, 0x4551231950B75FC4ULL, 1, 0}},
};
static const u256 GX = {{0x59F2815B16F81798ULL, 0x029BFCDB2DCE28D9ULL, 0x55A06295CE870B07ULL, 0x79BE667EF9DCBBACULL}};
static const u256 GY = {{0x9C47D08FFB10D4B8ULL, 0xFD17B448A6855419ULL, 0x5DA4FBFC0E1108A8ULL, 0x483ADA7726A3C465ULL}};
static const u256 ZERO = {{0, 0, 0, 0}};
static const u256 ONE = {{1, 0, 0, 0}};

static int is_zero(const u256 *a) { return (a->v[0] | a->v[1] | a->v[2] | a->v[3]) == 0; }

static int cmp(const u256 *a, const u256 *b) {
    for (int i = 3; i >= 0; i--) {
        if (a->v[i] != b->v[i]) return a->v[i] < b->v[i] ? -1 : 1;
    }
    return 0;
}

static uint64_t add_raw(u256 *r, const u256 *a, const u256 *b) {
    u128 carry = 0;
    for (int i = 0; i < 4; i++) {
        carry += (u128)a->v[i] + b->v[i];
        r->v[i] = (uint64_t)carry;
        carry >>= 64;
    }
    return (uint64_t)carry;
}

static uint64_t sub_raw(u256 *r, const u256 *a, const u256 *b) {
    uint64_t borrow = 0;
    for (int i = 0; i < 4; i++) {
        u128 d = (u128)a->v[i] - b->v[i] - borrow;
        r->v[i] = (uint64_t)d;
        borrow = (uint64_t)(d >> 64) & 1;
    }
    return borrow;
}

static void mul_raw(uint64_t r[8], const u256 *a, const u256 *b) {
    memset(r, 0, 8 * sizeof(uint64_t));
    for (int i = 0; i < 4; i++) {
        u128 carry = 0;
        for (int j = 0; j < 4; j++) {
            carry += (u128)a->v[i] * b->v[j] + r[i + j];
            r[i + j] = (uint64_t)carry;
            carry >>= 64;
        }
        r[i + 4] = (uint64_t)carry;
    }
}

/// 512 bits → below m. 2^256 ≡ c, so the high half folds down as high * c until nothing is left of it.
static void reduce(u256 *r, uint64_t x[8], const modulus *f) {
    for (;;) {
        u256 hi = {{x[4], x[5], x[6], x[7]}};
        if (is_zero(&hi)) break;
        uint64_t t[8];
        mul_raw(t, &hi, &f->c);
        u128 carry = 0;
        for (int i = 0; i < 8; i++) {
            carry += (u128)t[i] + (i < 4 ? x[i] : 0);
            x[i] = (uint64_t)carry;
            carry >>= 64;
        }
    }
    u256 lo = {{x[0], x[1], x[2], x[3]}};
    while (cmp(&lo, &f->m) >= 0) sub_raw(&lo, &lo, &f->m);
    *r = lo;
}

static void mod_add(u256 *r, const u256 *a, const u256 *b, const modulus *f) {
    u256 s;
    if (add_raw(&s, a, b)) add_raw(&s, &s, &f->c); // a + b - 2^256 + c = a + b - m, which is below m
    else if (cmp(&s, &f->m) >= 0) sub_raw(&s, &s, &f->m);
    *r = s;
}

static void mod_sub(u256 *r, const u256 *a, const u256 *b, const modulus *f) {
    u256 d;
    if (sub_raw(&d, a, b)) add_raw(&d, &d, &f->m);
    *r = d;
}

/// The same for the field prime, whose c fits in one limb: this is where nearly all the time goes.
static void reduce_p(u256 *r, const uint64_t x[8]) {
    const uint64_t c = 0x00000001000003D1ULL;
    u256 t;
    u128 carry = 0;
    for (int i = 0; i < 4; i++) {
        carry += (u128)x[i] + (u128)x[i + 4] * c;
        t.v[i] = (uint64_t)carry;
        carry >>= 64;
    }
    // What spilled past 2^256 (under 2^34) folds down once more; that can spill by one at most, and then not again.
    carry = (u128)(uint64_t)carry * c;
    for (int i = 0; i < 4; i++) {
        carry += t.v[i];
        t.v[i] = (uint64_t)carry;
        carry >>= 64;
    }
    if (carry) add_raw(&t, &t, &FP.c);
    if (cmp(&t, &FP.m) >= 0) sub_raw(&t, &t, &FP.m);
    *r = t;
}

static void mod_mul(u256 *r, const u256 *a, const u256 *b, const modulus *f) {
    uint64_t t[8];
    mul_raw(t, a, b);
    if (f == &FP) reduce_p(r, t);
    else reduce(r, t, f);
}

static void mod_pow(u256 *r, const u256 *a, const u256 *e, const modulus *f) {
    u256 acc = ONE, base = *a;
    for (int i = 255; i >= 0; i--) {
        mod_mul(&acc, &acc, &acc, f);
        if ((e->v[i / 64] >> (i % 64)) & 1) mod_mul(&acc, &acc, &base, f);
    }
    *r = acc;
}

static void from_bytes(u256 *r, const uint8_t b[32]) {
    for (int i = 0; i < 4; i++) {
        uint64_t limb = 0;
        for (int k = 0; k < 8; k++) limb = (limb << 8) | b[(3 - i) * 8 + k];
        r->v[i] = limb;
    }
}

static void to_bytes(uint8_t b[32], const u256 *a) {
    for (int i = 0; i < 4; i++) {
        for (int k = 0; k < 8; k++) b[(3 - i) * 8 + k] = (uint8_t)(a->v[i] >> (56 - 8 * k));
    }
}

// Field shorthands.
static void fadd(u256 *r, const u256 *a, const u256 *b) { mod_add(r, a, b, &FP); }
static void fsub(u256 *r, const u256 *a, const u256 *b) { mod_sub(r, a, b, &FP); }
static void fmul(u256 *r, const u256 *a, const u256 *b) { mod_mul(r, a, b, &FP); }

/// Jacobian coordinates; z = 0 is the point at infinity.
typedef struct { u256 x, y, z; } point;

static void point_double(point *r, const point *p) {
    if (is_zero(&p->z) || is_zero(&p->y)) {
        r->x = ONE; r->y = ONE; r->z = ZERO;
        return;
    }
    u256 a, b, c, d, e, f, t;
    fmul(&a, &p->x, &p->x);
    fmul(&b, &p->y, &p->y);
    fmul(&c, &b, &b);
    fadd(&t, &p->x, &b);
    fmul(&t, &t, &t);
    fsub(&t, &t, &a);
    fsub(&t, &t, &c);
    fadd(&d, &t, &t);          // d = 2((x + b)^2 - a - c)
    fadd(&e, &a, &a);
    fadd(&e, &e, &a);          // e = 3a
    fmul(&f, &e, &e);
    u256 x3, y3, z3;
    fadd(&t, &d, &d);
    fsub(&x3, &f, &t);         // x3 = e^2 - 2d
    fsub(&t, &d, &x3);
    fmul(&y3, &e, &t);
    fadd(&c, &c, &c);
    fadd(&c, &c, &c);
    fadd(&c, &c, &c);          // 8c
    fsub(&y3, &y3, &c);        // y3 = e(d - x3) - 8c
    fmul(&z3, &p->y, &p->z);
    fadd(&z3, &z3, &z3);       // z3 = 2yz
    r->x = x3; r->y = y3; r->z = z3;
}

static void point_add(point *r, const point *p, const point *q) {
    if (is_zero(&p->z)) { *r = *q; return; }
    if (is_zero(&q->z)) { *r = *p; return; }
    u256 z1z1, z2z2, u1, u2, s1, s2, h, rr, hh, hhh, v, t;
    fmul(&z1z1, &p->z, &p->z);
    fmul(&z2z2, &q->z, &q->z);
    fmul(&u1, &p->x, &z2z2);
    fmul(&u2, &q->x, &z1z1);
    fmul(&s1, &p->y, &q->z);
    fmul(&s1, &s1, &z2z2);
    fmul(&s2, &q->y, &p->z);
    fmul(&s2, &s2, &z1z1);
    fsub(&h, &u2, &u1);
    fsub(&rr, &s2, &s1);
    if (is_zero(&h)) {
        if (is_zero(&rr)) { point_double(r, p); return; }
        r->x = ONE; r->y = ONE; r->z = ZERO; // p = -q
        return;
    }
    fmul(&hh, &h, &h);
    fmul(&hhh, &hh, &h);
    fmul(&v, &u1, &hh);
    u256 x3, y3, z3;
    fmul(&x3, &rr, &rr);
    fsub(&x3, &x3, &hhh);
    fsub(&x3, &x3, &v);
    fsub(&x3, &x3, &v);        // x3 = r^2 - h^3 - 2v
    fsub(&t, &v, &x3);
    fmul(&y3, &rr, &t);
    fmul(&t, &s1, &hhh);
    fsub(&y3, &y3, &t);        // y3 = r(v - x3) - s1 h^3
    fmul(&z3, &p->z, &q->z);
    fmul(&z3, &z3, &h);        // z3 = z1 z2 h
    r->x = x3; r->y = y3; r->z = z3;
}

static void point_mul(point *r, const u256 *k, const point *p) {
    point acc = {ONE, ONE, ZERO};
    for (int i = 255; i >= 0; i--) {
        point_double(&acc, &acc);
        if ((k->v[i / 64] >> (i % 64)) & 1) point_add(&acc, &acc, p);
    }
    *r = acc;
}

/// 0 for the point at infinity.
static int to_affine(u256 *x, u256 *y, const point *p) {
    if (is_zero(&p->z)) return 0;
    u256 e, zi, zi2, zi3;
    sub_raw(&e, &FP.m, &(u256){{2, 0, 0, 0}});
    mod_pow(&zi, &p->z, &e, &FP); // Fermat: z^(p-2) = 1/z
    fmul(&zi2, &zi, &zi);
    fmul(&zi3, &zi2, &zi);
    fmul(x, &p->x, &zi2);
    fmul(y, &p->y, &zi3);
    return 1;
}

static void tagged_hash(uint8_t out[32], const char *tag, const uint8_t *parts[], const size_t lens[], int count) {
    uint8_t th[32];
    CC_SHA256(tag, (CC_LONG)strlen(tag), th);
    CC_SHA256_CTX ctx;
    CC_SHA256_Init(&ctx);
    CC_SHA256_Update(&ctx, th, 32);
    CC_SHA256_Update(&ctx, th, 32);
    for (int i = 0; i < count; i++) CC_SHA256_Update(&ctx, parts[i], (CC_LONG)lens[i]);
    CC_SHA256_Final(out, &ctx);
}

/// d·G as affine x and y, for 0 < d < n.
static int base_mul(u256 *x, u256 *y, const u256 *d) {
    if (is_zero(d) || cmp(d, &FN.m) >= 0) return 0;
    point g = {GX, GY, ONE}, r;
    point_mul(&r, d, &g);
    return to_affine(x, y, &r);
}

int lp_schnorr_pubkey(const uint8_t secret_key[32], uint8_t pubkey[32]) {
    u256 d, x, y;
    from_bytes(&d, secret_key);
    if (!base_mul(&x, &y, &d)) return 0;
    to_bytes(pubkey, &x);
    return 1;
}

int lp_schnorr_sign(const uint8_t secret_key[32], const uint8_t *msg, size_t msg_len,
                    const uint8_t aux[32], uint8_t sig[64]) {
    u256 d, px, py;
    from_bytes(&d, secret_key);
    if (!base_mul(&px, &py, &d)) return 0;
    if (py.v[0] & 1) sub_raw(&d, &FN.m, &d);

    uint8_t dbytes[32], pbytes[32], t[32], rnd[32];
    to_bytes(dbytes, &d);
    to_bytes(pbytes, &px);
    tagged_hash(t, "BIP0340/aux", (const uint8_t *[]){aux}, (const size_t[]){32}, 1);
    for (int i = 0; i < 32; i++) t[i] ^= dbytes[i];
    tagged_hash(rnd, "BIP0340/nonce", (const uint8_t *[]){t, pbytes, msg}, (const size_t[]){32, 32, msg_len}, 3);

    u256 k, rx, ry;
    from_bytes(&k, rnd);
    while (cmp(&k, &FN.m) >= 0) sub_raw(&k, &k, &FN.m);
    if (!base_mul(&rx, &ry, &k)) return 0;
    if (ry.v[0] & 1) sub_raw(&k, &FN.m, &k);

    uint8_t rbytes[32], ebytes[32];
    to_bytes(rbytes, &rx);
    tagged_hash(ebytes, "BIP0340/challenge", (const uint8_t *[]){rbytes, pbytes, msg}, (const size_t[]){32, 32, msg_len}, 3);
    u256 e, s;
    from_bytes(&e, ebytes);
    while (cmp(&e, &FN.m) >= 0) sub_raw(&e, &e, &FN.m);
    mod_mul(&s, &e, &d, &FN);
    mod_add(&s, &s, &k, &FN);

    memcpy(sig, rbytes, 32);
    to_bytes(sig + 32, &s);
    memset_s(dbytes, sizeof dbytes, 0, sizeof dbytes);
    memset_s(t, sizeof t, 0, sizeof t);
    memset_s(rnd, sizeof rnd, 0, sizeof rnd);
    // A signature that doesn't verify would leak nothing here, but it would be a bug worth catching before a relay does.
    return lp_schnorr_verify(pbytes, msg, msg_len, sig);
}

int lp_schnorr_verify(const uint8_t pubkey[32], const uint8_t *msg, size_t msg_len, const uint8_t sig[64]) {
    u256 px, py, r, s;
    from_bytes(&px, pubkey);
    from_bytes(&r, sig);
    from_bytes(&s, sig + 32);
    if (cmp(&px, &FP.m) >= 0 || cmp(&r, &FP.m) >= 0 || cmp(&s, &FN.m) >= 0) return 0;

    // lift_x: the point with this x and an even y. p ≡ 3 (mod 4), so a square root is c^((p+1)/4).
    u256 c, e, y2;
    fmul(&c, &px, &px);
    fmul(&c, &c, &px);
    fadd(&c, &c, &(u256){{7, 0, 0, 0}});
    add_raw(&e, &FP.m, &ONE); // p + 1 fits: p is odd and below 2^256 - 1
    for (int i = 0; i < 4; i++) e.v[i] = (e.v[i] >> 2) | (i < 3 ? e.v[i + 1] << 62 : 0);
    mod_pow(&py, &c, &e, &FP);
    fmul(&y2, &py, &py);
    if (cmp(&y2, &c) != 0) return 0;
    if (py.v[0] & 1) sub_raw(&py, &FP.m, &py);

    uint8_t ebytes[32];
    tagged_hash(ebytes, "BIP0340/challenge", (const uint8_t *[]){sig, pubkey, msg}, (const size_t[]){32, 32, msg_len}, 3);
    from_bytes(&e, ebytes);
    while (cmp(&e, &FN.m) >= 0) sub_raw(&e, &e, &FN.m);

    // R = s·G - e·P
    point g = {GX, GY, ONE}, p = {px, py, ONE}, sg, ep, sum;
    if (!is_zero(&e)) sub_raw(&e, &FN.m, &e);
    point_mul(&sg, &s, &g);
    point_mul(&ep, &e, &p);
    point_add(&sum, &sg, &ep);
    u256 rx, ry;
    if (!to_affine(&rx, &ry, &sum)) return 0;
    return (ry.v[0] & 1) == 0 && cmp(&rx, &r) == 0;
}

int lp_selftest_field(void) {
    // Every mix of awkward limbs, where carries chain and folds spill: the fast reduction must agree with the plain one.
    static const uint64_t limbs[5] = {0, 1, 0xFFFFFFFFFFFFFFFFULL, 0xFFFFFFFEFFFFFC2FULL, 0x8000000000000000ULL};
    uint32_t pick[8] = {0};
    for (;;) {
        uint64_t x[8], y[8];
        for (int i = 0; i < 8; i++) x[i] = y[i] = limbs[pick[i]];
        u256 fast, plain;
        reduce_p(&fast, x);
        reduce(&plain, y, &FP);
        if (cmp(&fast, &plain) != 0 || cmp(&fast, &FP.m) >= 0) return 0;
        int i = 0;
        while (i < 8 && ++pick[i] == 5) pick[i++] = 0;
        if (i == 8) break;
    }
    // (p - 1)^2 = 1, and n - 1 squared the same way, through the public multiply.
    u256 a, r;
    sub_raw(&a, &FP.m, &ONE);
    mod_mul(&r, &a, &a, &FP);
    if (cmp(&r, &ONE) != 0) return 0;
    sub_raw(&a, &FN.m, &ONE);
    mod_mul(&r, &a, &a, &FN);
    return cmp(&r, &ONE) == 0;
}
