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
        // Optimized Rho and Pi
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

    // Challenge is 32 bytes (4 uint64)
    uint64_t *challenge64 = (uint64_t*)challenge;
    s[0] ^= challenge64[0];
    s[1] ^= challenge64[1];
    s[2] ^= challenge64[2];
    s[3] ^= challenge64[3];

    // Nonce is 32 bytes (uint256), but we treat it as 8 bytes in this simplified kernel for speed
    // and padding. Real Keccak-256 for 64 bytes total input.
    s[4] ^= nonce; 
    // Padding for Keccak-256 (64 bytes input -> 136 bytes rate)
    s[8] ^= 0x01; 
    s[16] ^= 0x8000000000000000ULL;

    keccakf(s);

    // Compare with difficulty (first 8 bytes for quick check)
    uint64_t *diff64 = (uint64_t*)difficulty;
    // Note: Ethereum difficulty check is usually BigInt < Target. 
    // Here we do a simplified check.
    if (s[0] < diff64[0]) {
        atomicExch(found_flag, 1);
        *found_nonce = nonce;
    }
}

int main(int argc, char **argv) {
    if (argc < 4) return 1;
    
    std::string challenge_hex = argv[1];
    std::string difficulty_hex = argv[2];
    uint64_t start_nonce = std::stoull(argv[3]);

    uint8_t h_challenge[32], h_difficulty[32];
    // Convert hex to bytes (simplified)
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
    int blocks = 1024 * 64; // Adjust based on GPU

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
        // Optionally output hashrate to stderr
    }

    cudaFree(d_challenge);
    cudaFree(d_difficulty);
    cudaFree(d_found_nonce);
    cudaFree(d_found_flag);

    return 0;
}
