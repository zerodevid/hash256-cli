#include <iostream>
#include <vector>
#include <string>
#include <cuda_runtime.h>
#include <device_launch_parameters.h>

typedef unsigned char uint8_t;
typedef unsigned long long uint64_t;

// Keccak-f[1600] constants
__constant__ uint64_t d_keccakf_rndc[24] = {
    0x0000000000000001, 0x0000000000008082, 0x800000000000808a, 0x8000000080008000,
    0x000000000000808b, 0x0000000080000001, 0x8000000080008081, 0x8000000000008009,
    0x000000000000008a, 0x0000000000000088, 0x0000000080008009, 0x000000008000000a,
    0x000000008000808b, 0x800000000000008b, 0x8000000000008089, 0x8000000000008003,
    0x8000000000008002, 0x8000000000000080, 0x000000000000800a, 0x800000008000000a,
    0x8000000080008081, 0x8000000000008080, 0x0000000080000001, 0x8000000080008008
};

#define ROL64(a, offset) ((a << offset) ^ (a >> (64 - offset)))

// Byte swap for uint64_t to handle Big-Endian conversion
__device__ inline uint64_t bswap64(uint64_t val) {
    return __byte_perm(val, 0, 0x0123) | (__byte_perm(val >> 32, 0, 0x0123) << 32);
}
// Correct byte swap using intrinsic
__device__ inline uint64_t swap64(uint64_t x) {
    return ((x << 56) | ((x << 40) & 0xff000000000000ULL) | ((x << 24) & 0xff0000000000ULL) | ((x << 8) & 0xff00000000ULL) | ((x >> 8) & 0xff000000ULL) | ((x >> 24) & 0xff0000ULL) | ((x >> 40) & 0xff00ULL) | (x >> 56));
}

__device__ void keccakf(uint64_t s[25]) {
    int i, j, round;
    uint64_t t, bc[5];
    for (round = 0; round < 24; round++) {
        for (i = 0; i < 5; i++) bc[i] = s[i] ^ s[i + 5] ^ s[i + 10] ^ s[i + 15] ^ s[i + 20];
        for (i = 0; i < 5; i++) {
            t = bc[(i + 4) % 5] ^ ROL64(bc[(i + 1) % 5], 1);
            for (j = 0; j < 25; j += 5) s[j + i] ^= t;
        }
        t = s[1];
        s[1] = ROL64(s[6], 44); s[6] = ROL64(s[9], 20); s[9] = ROL64(s[22], 61); s[22] = ROL64(s[14], 39);
        s[14] = ROL64(s[20], 18); s[20] = ROL64(s[2], 62); s[2] = ROL64(s[12], 43); s[12] = ROL64(s[13], 25);
        s[13] = ROL64(s[19], 8); s[19] = ROL64(s[23], 56); s[23] = ROL64(s[15], 41); s[15] = ROL64(s[4], 27);
        s[4] = ROL64(s[24], 14); s[24] = ROL64(s[21], 2); s[21] = ROL64(s[8], 55); s[8] = ROL64(s[16], 45);
        s[16] = ROL64(s[5], 36); s[5] = ROL64(s[3], 28); s[3] = ROL64(s[18], 21); s[18] = ROL64(s[17], 15);
        s[17] = ROL64(s[11], 10); s[11] = ROL64(s[7], 7); s[7] = ROL64(s[10], 3); s[10] = t;

        for (j = 0; j < 25; j += 5) {
            for (i = 0; i < 5; i++) bc[i] = s[j + i];
            for (i = 0; i < 5; i++) s[j + i] ^= (~bc[(i + 1) % 5]) & bc[(i + 2) % 5];
        }
        s[0] ^= d_keccakf_rndc[round];
    }
}

__global__ void mine_kernel(uint8_t *challenge, uint8_t *difficulty, uint64_t start_nonce, uint64_t *found_nonce, int *found_flag) {
    uint64_t nonce = start_nonce + blockIdx.x * blockDim.x + threadIdx.x;
    uint64_t s[25];
    for (int i = 0; i < 25; i++) s[i] = 0;

    // Challenge (32 bytes) - Copy directly as 64-bit lanes (Little-Endian to Little-Endian XOR)
    uint64_t *challenge64 = (uint64_t*)challenge;
    s[0] ^= challenge64[0];
    s[1] ^= challenge64[1];
    s[2] ^= challenge64[2];
    s[3] ^= challenge64[3];

    // Nonce (32 bytes uint256 in Solidity)
    // Solidity: abi.encode(challenge, nonce) -> challenge[32] || nonce[32] (Big-Endian)
    // Lane 4, 5, 6 will be 0 for a uint64 nonce
    // Lane 7 gets the big-endian nonce
    s[7] ^= swap64(nonce);

    // Padding for Keccak-256 (64 bytes input -> 136 bytes rate)
    s[8] ^= 0x01; 
    s[16] ^= 0x8000000000000000ULL;

    keccakf(s);

    // Final Hash check (Big-Endian result in s[0..3])
    // Contract check: hash < difficulty (uint256 comparison)
    uint64_t *diff64 = (uint64_t*)difficulty;
    
    // We need to compare s[0..3] as Big-Endian uint256
    // To compare easily, we swap back to little-endian host order for comparison
    uint64_t h0 = swap64(s[0]);
    uint64_t h1 = swap64(s[1]);
    uint64_t h2 = swap64(s[2]);
    uint64_t h3 = swap64(s[3]);

    uint64_t d0 = swap64(diff64[0]);
    uint64_t d1 = swap64(diff64[1]);
    uint64_t d2 = swap64(diff64[2]);
    uint64_t d3 = swap64(diff64[3]);

    // Comparison of 256-bit Big-Endian integers (Most significant word first)
    bool isLess = false;
    if (h0 < d0) isLess = true;
    else if (h0 == d0) {
        if (h1 < d1) isLess = true;
        else if (h1 == d1) {
            if (h2 < d2) isLess = true;
            else if (h2 == d2) {
                if (h3 < d3) isLess = true;
            }
        }
    }

    if (isLess) {
        if (atomicExch(found_flag, 1) == 0) {
            *found_nonce = nonce;
        }
    }
}

int main(int argc, char **argv) {
    if (argc < 4) return 1;
    
    std::string challenge_hex = argv[1];
    std::string difficulty_hex = argv[2];
    uint64_t start_nonce = std::stoull(argv[3]);

    uint8_t h_challenge[32], h_difficulty[32];
    for (int i = 0; i < 32; i++) {
        h_challenge[i] = std::stoi(challenge_hex.substr(i*2, 2), nullptr, 16);
        h_difficulty[i] = std::stoi(difficulty_hex.substr(i*2, 2), nullptr, 16);
    }

    uint8_t *d_challenge, *d_difficulty;
    uint64_t *d_found_nonce, h_found_nonce;
    int *d_found_flag, h_found_flag = 0;

    cudaMalloc(&d_challenge, 32);
    cudaMalloc(&d_difficulty, 32);
    cudaMalloc(&d_found_nonce, sizeof(uint64_t));
    cudaMalloc(&d_found_flag, sizeof(int));

    cudaMemcpy(d_challenge, h_challenge, 32, cudaMemcpyHostToDevice);
    cudaMemcpy(d_difficulty, h_difficulty, 32, cudaMemcpyHostToDevice);
    cudaMemset(d_found_flag, 0, sizeof(int));

    int threads = 256;
    int blocks = 1024 * 64; 

    while (true) {
        mine_kernel<<<blocks, threads>>>(d_challenge, d_difficulty, start_nonce, d_found_nonce, d_found_flag);
        cudaDeviceSynchronize();
        
        cudaMemcpy(&h_found_flag, d_found_flag, sizeof(int), cudaMemcpyDeviceToHost);
        if (h_found_flag) {
            cudaMemcpy(&h_found_nonce, d_found_nonce, sizeof(uint64_t), cudaMemcpyDeviceToHost);
            std::cout << h_found_nonce << std::endl;
            break;
        }
        start_nonce += (uint64_t)blocks * threads;
    }

    cudaFree(d_challenge);
    cudaFree(d_difficulty);
    cudaFree(d_found_nonce);
    cudaFree(d_found_flag);

    return 0;
}
