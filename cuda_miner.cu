#include <iostream>
#include <vector>
#include <string>
#include <cuda_runtime.h>
#include <device_launch_parameters.h>

typedef unsigned char uint8_t;
typedef unsigned long long uint64_t;

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

    // Use a byte buffer for exact layout matching Solidity
    uint8_t msg[136];
    for (int i = 0; i < 136; i++) msg[i] = 0;

    // Bytes 0-31: Challenge
    for (int i = 0; i < 32; i++) msg[i] = challenge[i];

    // Bytes 32-63: Nonce (uint256 Big-Endian)
    // We populate only the last 8 bytes since our nonce is uint64
    msg[63] = (uint8_t)(nonce & 0xFF);
    msg[62] = (uint8_t)((nonce >> 8) & 0xFF);
    msg[61] = (uint8_t)((nonce >> 16) & 0xFF);
    msg[60] = (uint8_t)((nonce >> 24) & 0xFF);
    msg[59] = (uint8_t)((nonce >> 32) & 0xFF);
    msg[58] = (uint8_t)((nonce >> 40) & 0xFF);
    msg[57] = (uint8_t)((nonce >> 48) & 0xFF);
    msg[56] = (uint8_t)((nonce >> 56) & 0xFF);

    // Keccak-256 Padding
    msg[64] = 0x01;
    msg[135] = 0x80;

    // XOR byte buffer into lanes
    for (int i = 0; i < 17; i++) {
        uint64_t lane = 0;
        for (int j = 0; j < 8; j++) lane |= ((uint64_t)msg[i * 8 + j] << (j * 8));
        s[i] ^= lane;
    }

    keccakf(s);

    // Extract result hash bytes
    uint8_t hash[32];
    for (int i = 0; i < 4; i++) {
        uint64_t lane = s[i];
        for (int j = 0; j < 8; j++) hash[i * 8 + j] = (uint8_t)((lane >> (j * 8)) & 0xFF);
    }

    // Compare hash < difficulty (Big-Endian 256-bit)
    bool isLess = false;
    for (int i = 0; i < 32; i++) {
        if (hash[i] < difficulty[i]) { isLess = true; break; }
        if (hash[i] > difficulty[i]) { break; }
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
        h_challenge[i] = std::stoi(challenge_hex.substr(i * 2, 2), nullptr, 16);
        h_difficulty[i] = std::stoi(difficulty_hex.substr(i * 2, 2), nullptr, 16);
    }
    uint8_t *d_challenge, *d_difficulty;
    uint64_t *d_found_nonce;
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
            uint64_t h_found_nonce;
            cudaMemcpy(&h_found_nonce, d_found_nonce, sizeof(uint64_t), cudaMemcpyDeviceToHost);
            std::cout << h_found_nonce << std::endl;
            break;
        }
        start_nonce += (uint64_t)blocks * threads;
    }
    cudaFree(d_challenge); cudaFree(d_difficulty); cudaFree(d_found_nonce); cudaFree(d_found_flag);
    return 0;
}
