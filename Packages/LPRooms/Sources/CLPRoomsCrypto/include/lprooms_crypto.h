#ifndef LPROOMS_CRYPTO_H
#define LPROOMS_CRYPTO_H

#include <stddef.h>
#include <stdint.h>

// The two primitives rooms need that Apple's frameworks don't ship: scrypt (RFC 7914) for the room key, and
// BIP-340 Schnorr signatures over secp256k1 for Nostr events. Everything returns 1 on success and 0 on failure.

/// scrypt(password, salt, N, r, p) -> out. N must be a power of two greater than 1. Needs 128 * r * N bytes of memory.
int lp_scrypt(const uint8_t *password, size_t password_len,
              const uint8_t *salt, size_t salt_len,
              uint64_t n, uint32_t r, uint32_t p,
              uint8_t *out, size_t out_len);

/// The x-only public key of a 32-byte secret key. Fails when the key is 0 or not below the curve order.
int lp_schnorr_pubkey(const uint8_t secret_key[32], uint8_t pubkey[32]);

/// BIP-340 signature of `msg` (any length; Nostr signs a 32-byte event id). `aux` is 32 bytes of fresh randomness.
int lp_schnorr_sign(const uint8_t secret_key[32], const uint8_t *msg, size_t msg_len,
                    const uint8_t aux[32], uint8_t sig[64]);

/// 1 when `sig` is a valid BIP-340 signature of `msg` under the x-only `pubkey`.
int lp_schnorr_verify(const uint8_t pubkey[32], const uint8_t *msg, size_t msg_len, const uint8_t sig[64]);

/// For the tests: checks the field arithmetic's fast path against the plain one on carry-heavy inputs.
int lp_selftest_field(void);

#endif
