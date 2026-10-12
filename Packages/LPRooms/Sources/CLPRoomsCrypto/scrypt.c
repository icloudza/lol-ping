// scrypt, RFC 7914: PBKDF2-HMAC-SHA256 around ROMix over Salsa20/8. Written for the one use rooms have for it
// (N = 2^15, r = 8, p = 1: 32 MB, about a tenth of a second), not as a general-purpose library.

#define __STDC_WANT_LIB_EXT1__ 1

#include "lprooms_crypto.h"

#include <CommonCrypto/CommonHMAC.h>
#include <stdlib.h>
#include <string.h>

static inline uint32_t le32dec(const uint8_t *p) {
    return (uint32_t)p[0] | ((uint32_t)p[1] << 8) | ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
}

static inline void le32enc(uint8_t *p, uint32_t x) {
    p[0] = (uint8_t)x;
    p[1] = (uint8_t)(x >> 8);
    p[2] = (uint8_t)(x >> 16);
    p[3] = (uint8_t)(x >> 24);
}

static void pbkdf2_sha256(const uint8_t *pw, size_t pw_len, const uint8_t *salt, size_t salt_len,
                          uint32_t iterations, uint8_t *out, size_t out_len) {
    uint8_t u[CC_SHA256_DIGEST_LENGTH], t[CC_SHA256_DIGEST_LENGTH], counter[4];
    for (uint32_t block = 1; out_len > 0; block++) {
        counter[0] = (uint8_t)(block >> 24);
        counter[1] = (uint8_t)(block >> 16);
        counter[2] = (uint8_t)(block >> 8);
        counter[3] = (uint8_t)block;
        CCHmacContext ctx;
        CCHmacInit(&ctx, kCCHmacAlgSHA256, pw, pw_len);
        CCHmacUpdate(&ctx, salt, salt_len);
        CCHmacUpdate(&ctx, counter, 4);
        CCHmacFinal(&ctx, u);
        memcpy(t, u, sizeof t);
        for (uint32_t i = 1; i < iterations; i++) {
            CCHmac(kCCHmacAlgSHA256, pw, pw_len, u, sizeof u, u);
            for (size_t k = 0; k < sizeof t; k++) t[k] ^= u[k];
        }
        size_t take = out_len < sizeof t ? out_len : sizeof t;
        memcpy(out, t, take);
        out += take;
        out_len -= take;
    }
}

#define ROTL(a, b) (((a) << (b)) | ((a) >> (32 - (b))))

static void salsa20_8(uint32_t b[16]) {
    uint32_t x0 = b[0], x1 = b[1], x2 = b[2], x3 = b[3], x4 = b[4], x5 = b[5], x6 = b[6], x7 = b[7];
    uint32_t x8 = b[8], x9 = b[9], x10 = b[10], x11 = b[11], x12 = b[12], x13 = b[13], x14 = b[14], x15 = b[15];
    for (int i = 0; i < 8; i += 2) {
        // Columns.
        x4 ^= ROTL(x0 + x12, 7);   x8 ^= ROTL(x4 + x0, 9);    x12 ^= ROTL(x8 + x4, 13);   x0 ^= ROTL(x12 + x8, 18);
        x9 ^= ROTL(x5 + x1, 7);    x13 ^= ROTL(x9 + x5, 9);   x1 ^= ROTL(x13 + x9, 13);   x5 ^= ROTL(x1 + x13, 18);
        x14 ^= ROTL(x10 + x6, 7);  x2 ^= ROTL(x14 + x10, 9);  x6 ^= ROTL(x2 + x14, 13);   x10 ^= ROTL(x6 + x2, 18);
        x3 ^= ROTL(x15 + x11, 7);  x7 ^= ROTL(x3 + x15, 9);   x11 ^= ROTL(x7 + x3, 13);   x15 ^= ROTL(x11 + x7, 18);
        // Rows.
        x1 ^= ROTL(x0 + x3, 7);    x2 ^= ROTL(x1 + x0, 9);    x3 ^= ROTL(x2 + x1, 13);    x0 ^= ROTL(x3 + x2, 18);
        x6 ^= ROTL(x5 + x4, 7);    x7 ^= ROTL(x6 + x5, 9);    x4 ^= ROTL(x7 + x6, 13);    x5 ^= ROTL(x4 + x7, 18);
        x11 ^= ROTL(x10 + x9, 7);  x8 ^= ROTL(x11 + x10, 9);  x9 ^= ROTL(x8 + x11, 13);   x10 ^= ROTL(x9 + x8, 18);
        x12 ^= ROTL(x15 + x14, 7); x13 ^= ROTL(x12 + x15, 9); x14 ^= ROTL(x13 + x12, 13); x15 ^= ROTL(x14 + x13, 18);
    }
    b[0] += x0;   b[1] += x1;   b[2] += x2;   b[3] += x3;   b[4] += x4;   b[5] += x5;   b[6] += x6;   b[7] += x7;
    b[8] += x8;   b[9] += x9;   b[10] += x10; b[11] += x11; b[12] += x12; b[13] += x13; b[14] += x14; b[15] += x15;
}

static inline void blkxor(uint32_t *dst, const uint32_t *src, size_t words) {
    for (size_t i = 0; i < words; i++) dst[i] ^= src[i];
}

/// BlockMix: `in` and `out` are 2r blocks of 16 words; `x` is 16 words of scratch.
static void blockmix(const uint32_t *in, uint32_t *out, uint32_t *x, size_t r) {
    memcpy(x, &in[(2 * r - 1) * 16], 64);
    for (size_t i = 0; i < 2 * r; i += 2) {
        blkxor(x, &in[i * 16], 16);
        salsa20_8(x);
        memcpy(&out[i * 8], x, 64);
        blkxor(x, &in[i * 16 + 16], 16);
        salsa20_8(x);
        memcpy(&out[i * 8 + r * 16], x, 64);
    }
}

static inline uint64_t integerify(const uint32_t *b, size_t r) {
    const uint32_t *x = &b[(2 * r - 1) * 16];
    return ((uint64_t)x[1] << 32) | x[0];
}

/// ROMix on one 128r-byte block. `v` holds N blocks of 32r words, `xy` 64r + 16 words.
static void romix(uint8_t *b, size_t r, uint64_t n, uint32_t *v, uint32_t *xy) {
    const size_t words = 32 * r;
    uint32_t *x = xy, *y = &xy[words], *z = &xy[2 * words];
    for (size_t k = 0; k < words; k++) x[k] = le32dec(&b[4 * k]);
    for (uint64_t i = 0; i < n; i += 2) {
        memcpy(&v[i * words], x, words * 4);
        blockmix(x, y, z, r);
        memcpy(&v[(i + 1) * words], y, words * 4);
        blockmix(y, x, z, r);
    }
    for (uint64_t i = 0; i < n; i += 2) {
        uint64_t j = integerify(x, r) & (n - 1);
        blkxor(x, &v[j * words], words);
        blockmix(x, y, z, r);
        j = integerify(y, r) & (n - 1);
        blkxor(y, &v[j * words], words);
        blockmix(y, x, z, r);
    }
    for (size_t k = 0; k < words; k++) le32enc(&b[4 * k], x[k]);
}

int lp_scrypt(const uint8_t *password, size_t password_len, const uint8_t *salt, size_t salt_len,
              uint64_t n, uint32_t r, uint32_t p, uint8_t *out, size_t out_len) {
    if (n < 2 || (n & (n - 1)) != 0 || r == 0 || p == 0 || out_len == 0) return 0;
    // Bounds that keep every size below in range; rooms use 32 MB.
    if ((uint64_t)r * p >= (1u << 30) || r > 1024 || n > (1ull << 24)) return 0;
    const size_t block = 128 * (size_t)r;
    uint8_t *b = malloc(block * p);
    uint32_t *v = malloc(block * (size_t)n);
    uint32_t *xy = malloc(block * 2 + 64);
    int ok = 0;
    if (b && v && xy) {
        pbkdf2_sha256(password, password_len, salt, salt_len, 1, b, block * p);
        for (uint32_t i = 0; i < p; i++) romix(&b[i * block], r, n, v, xy);
        pbkdf2_sha256(password, password_len, b, block * p, 1, out, out_len);
        ok = 1;
    }
    if (b) memset_s(b, block * p, 0, block * p);
    if (xy) memset_s(xy, block * 2 + 64, 0, block * 2 + 64);
    free(b);
    free(v);
    free(xy);
    return ok;
}
