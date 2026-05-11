#include <node_api.h>
#include <stdint.h>
#include <string.h>

// Keccak-f[1600] constants and permutation
const uint64_t keccakf_rndc[24] = {
    0x0000000000000001, 0x0000000000008082, 0x800000000000808a, 0x8000000080008000,
    0x000000000000808b, 0x0000000080000001, 0x8000000080008081, 0x8000000000008009,
    0x000000000000008a, 0x0000000000000088, 0x0000000080008009, 0x000000008000000a,
    0x000000008000808b, 0x800000000000008b, 0x8000000000008089, 0x8000000000008003,
    0x8000000000008002, 0x8000000000000080, 0x000000000000800a, 0x800000008000000a,
    0x8000000080008081, 0x8000000000008080, 0x0000000080000001, 0x8000000080008008
};

const int keccakf_rotc[24] = {
    1,  3,  6,  10, 15, 21, 28, 36, 45, 55, 2,  14,
    27, 41, 56, 8,  25, 43, 62, 18, 39, 61, 20, 44
};

const int keccakf_piln[24] = {
    10, 7,  11, 17, 18, 3,  5,  16, 8,  21, 24, 4,
    15, 23, 19, 13, 12, 2,  20, 14, 22, 9,  6,  1
};

#define ROL64(a, offset) ((offset != 0) ? ((((uint64_t)a) << offset) ^ (((uint64_t)a) >> (64 - offset))) : a)

void keccakf(uint64_t s[25]) {
    int i, j, round;
    uint64_t t, bc[5];
    for (round = 0; round < 24; round++) {
        for (i = 0; i < 5; i++) bc[i] = s[i] ^ s[i + 5] ^ s[i + 10] ^ s[i + 15] ^ s[i + 20];
        for (i = 0; i < 5; i++) {
            t = bc[(i + 4) % 5] ^ ROL64(bc[(i + 1) % 5], 1);
            for (j = 0; j < 25; j += 5) s[j + i] ^= t;
        }
        t = s[1];
        for (i = 0; i < 24; i++) {
            j = keccakf_piln[i];
            bc[0] = s[j];
            s[j] = ROL64(t, keccakf_rotc[i]);
            t = bc[0];
        }
        for (j = 0; j < 25; j += 5) {
            for (i = 0; i < 5; i++) bc[i] = s[j + i];
            for (i = 0; i < 5; i++) s[j + i] ^= (~bc[(i + 1) % 5]) & bc[(i + 2) % 5];
        }
        s[0] ^= keccakf_rndc[round];
    }
}

// Keccak-256 for exactly 64 bytes of input
void keccak256_64bytes(const uint8_t *in, uint8_t *md) {
    uint64_t s[25];
    memset(s, 0, sizeof(s));
    
    // Process the 64 bytes (which fits in the 136-byte rate block)
    uint8_t t[136];
    memset(t, 0, sizeof(t));
    memcpy(t, in, 64);
    
    // Keccak-256 padding
    t[64] = 0x01;
    t[135] |= 0x80;
    
    // XOR state
    for (int i = 0; i < 17; i++) {
        uint64_t val = 0;
        for (int j = 0; j < 8; j++) val |= ((uint64_t)t[i * 8 + j]) << (8 * j);
        s[i] ^= val;
    }
    
    // Permute
    keccakf(s);
    
    // Squeeze out 32 bytes
    for (int i = 0; i < 4; i++) {
        uint64_t val = s[i];
        for (int j = 0; j < 8; j++) {
            md[i * 8 + j] = (uint8_t)(val & 0xFF);
            val >>= 8;
        }
    }
}

// N-API function: mineLoop(buffer, difficultyBytes, iterations)
napi_value MineLoop(napi_env env, napi_callback_info info) {
    size_t argc = 3;
    napi_value args[3];
    napi_get_cb_info(env, info, &argc, args, NULL, NULL);

    void* buffer_data;
    size_t buffer_len;
    napi_get_buffer_info(env, args[0], &buffer_data, &buffer_len); // 64 bytes

    void* diff_data;
    size_t diff_len;
    napi_get_buffer_info(env, args[1], &diff_data, &diff_len); // 32 bytes

    uint32_t iterations;
    napi_get_value_uint32(env, args[2], &iterations);

    uint8_t* buffer = (uint8_t*)buffer_data;
    uint8_t* diff = (uint8_t*)diff_data;
    uint8_t hash[32];

    for (uint32_t it = 0; it < iterations; it++) {
        keccak256_64bytes(buffer, hash);

        // Compare hash with diff (byte by byte)
        bool isLess = false;
        for (int i = 0; i < 32; i++) {
            if (hash[i] < diff[i]) {
                isLess = true;
                break;
            } else if (hash[i] > diff[i]) {
                break;
            }
        }

        if (isLess) {
            napi_value result;
            napi_create_int32(env, 1, &result);
            return result;
        }

        // Increment nonce (buffer[32..63] big-endian)
        for (int i = 63; i >= 32; i--) {
            if (buffer[i] < 255) {
                buffer[i]++;
                break;
            }
            buffer[i] = 0;
        }
    }

    napi_value result;
    napi_create_int32(env, 0, &result);
    return result;
}

napi_value Init(napi_env env, napi_value exports) {
    napi_value fn;
    napi_create_function(env, NULL, 0, MineLoop, NULL, &fn);
    napi_set_named_property(env, exports, "mineLoop", fn);
    return exports;
}

NAPI_MODULE(NODE_GYP_MODULE_NAME, Init)
