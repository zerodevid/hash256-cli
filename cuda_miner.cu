#include <iostream>
#include <vector>
#include <string>
#include <cuda_runtime.h>
#include <device_launch_parameters.h>
#include <chrono>
#include <cstdint>

__constant__ uint64_t d_keccakf_rndc[24] = {
    0x0000000000000001, 0x0000000000008082, 0x800000000000808a, 0x8000000080008000,
    0x000000000000808b, 0x0000000080000001, 0x8000000080008081, 0x8000000000008009,
    0x000000000000008a, 0x0000000000000088, 0x0000000080008009, 0x000000008000000a,
    0x000000008000808b, 0x800000000000008b, 0x8000000000008089, 0x8000000000008003,
    0x8000000000008002, 0x8000000000000080, 0x000000000000800a, 0x800000008000000a,
    0x8000000080008081, 0x8000000000008080, 0x0000000080000001, 0x8000000080008008
};

#define ROL64(a, offset) (((a) << (offset)) ^ ((a) >> (64 - (offset))))

__device__ __forceinline__ void keccakf(uint64_t s[25]) {
    int round;
    uint64_t t, bc[5];
    #pragma unroll 24
    for (round = 0; round < 24; round++) {
        bc[0] = s[0] ^ s[5] ^ s[10] ^ s[15] ^ s[20];
        bc[1] = s[1] ^ s[6] ^ s[11] ^ s[16] ^ s[21];
        bc[2] = s[2] ^ s[7] ^ s[12] ^ s[17] ^ s[22];
        bc[3] = s[3] ^ s[8] ^ s[13] ^ s[18] ^ s[23];
        bc[4] = s[4] ^ s[9] ^ s[14] ^ s[19] ^ s[24];

        t = bc[4] ^ ROL64(bc[1], 1);
        s[0] ^= t; s[5] ^= t; s[10] ^= t; s[15] ^= t; s[20] ^= t;
        t = bc[0] ^ ROL64(bc[2], 1);
        s[1] ^= t; s[6] ^= t; s[11] ^= t; s[16] ^= t; s[21] ^= t;
        t = bc[1] ^ ROL64(bc[3], 1);
        s[2] ^= t; s[7] ^= t; s[12] ^= t; s[17] ^= t; s[22] ^= t;
        t = bc[2] ^ ROL64(bc[4], 1);
        s[3] ^= t; s[8] ^= t; s[13] ^= t; s[18] ^= t; s[23] ^= t;
        t = bc[3] ^ ROL64(bc[0], 1);
        s[4] ^= t; s[9] ^= t; s[14] ^= t; s[19] ^= t; s[24] ^= t;

        t = s[1];
        s[1] = ROL64(s[6], 44); s[6] = ROL64(s[9], 20); s[9] = ROL64(s[22], 61); s[22] = ROL64(s[14], 39);
        s[14] = ROL64(s[20], 18); s[20] = ROL64(s[2], 62); s[2] = ROL64(s[12], 43); s[12] = ROL64(s[13], 25);
        s[13] = ROL64(s[19], 8); s[19] = ROL64(s[23], 56); s[23] = ROL64(s[15], 41); s[15] = ROL64(s[4], 27);
        s[4] = ROL64(s[24], 14); s[24] = ROL64(s[21], 2); s[21] = ROL64(s[8], 55); s[8] = ROL64(s[16], 45);
        s[16] = ROL64(s[5], 36); s[5] = ROL64(s[3], 28); s[3] = ROL64(s[18], 21); s[18] = ROL64(s[17], 15);
        s[17] = ROL64(s[11], 10); s[11] = ROL64(s[7], 7); s[7] = ROL64(s[10], 3); s[10] = t;

        bc[0] = s[0]; bc[1] = s[1]; bc[2] = s[2]; bc[3] = s[3]; bc[4] = s[4];
        s[0] ^= (~bc[1]) & bc[2]; s[1] ^= (~bc[2]) & bc[3]; s[2] ^= (~bc[3]) & bc[4]; s[3] ^= (~bc[4]) & bc[0]; s[4] ^= (~bc[0]) & bc[1];

        bc[0] = s[5]; bc[1] = s[6]; bc[2] = s[7]; bc[3] = s[8]; bc[4] = s[9];
        s[5] ^= (~bc[1]) & bc[2]; s[6] ^= (~bc[2]) & bc[3]; s[7] ^= (~bc[3]) & bc[4]; s[8] ^= (~bc[4]) & bc[0]; s[9] ^= (~bc[0]) & bc[1];

        bc[0] = s[10]; bc[1] = s[11]; bc[2] = s[12]; bc[3] = s[13]; bc[4] = s[14];
        s[10] ^= (~bc[1]) & bc[2]; s[11] ^= (~bc[2]) & bc[3]; s[12] ^= (~bc[3]) & bc[4]; s[13] ^= (~bc[4]) & bc[0]; s[14] ^= (~bc[0]) & bc[1];

        bc[0] = s[15]; bc[1] = s[16]; bc[2] = s[17]; bc[3] = s[18]; bc[4] = s[19];
        s[15] ^= (~bc[1]) & bc[2]; s[16] ^= (~bc[2]) & bc[3]; s[17] ^= (~bc[3]) & bc[4]; s[18] ^= (~bc[4]) & bc[0]; s[19] ^= (~bc[0]) & bc[1];

        bc[0] = s[20]; bc[1] = s[21]; bc[2] = s[22]; bc[3] = s[23]; bc[4] = s[24];
        s[20] ^= (~bc[1]) & bc[2]; s[21] ^= (~bc[2]) & bc[3]; s[22] ^= (~bc[3]) & bc[4]; s[23] ^= (~bc[4]) & bc[0]; s[24] ^= (~bc[0]) & bc[1];

        s[0] ^= d_keccakf_rndc[round];
    }
}

__global__ void mine_kernel(uint64_t c0, uint64_t c1, uint64_t c2, uint64_t c3,
                            uint64_t d0, uint64_t d1, uint64_t d2, uint64_t d3,
                            uint64_t start_nonce, uint64_t *found_nonce, int *found_flag) {
    uint64_t nonce = start_nonce + blockIdx.x * blockDim.x + threadIdx.x;
    
    uint64_t s[25] = {0};
    
    s[0] = c0;
    s[1] = c1;
    s[2] = c2;
    s[3] = c3;
    
    s[7] = __builtin_bswap64(nonce);
    
    s[8] = 0x01;
    s[16] = 0x8000000000000000ULL;

    keccakf(s);

    uint64_t h0 = __builtin_bswap64(s[0]);
    if (h0 < d0) goto found;
    if (h0 > d0) return;
    
    {
        uint64_t h1 = __builtin_bswap64(s[1]);
        if (h1 < d1) goto found;
        if (h1 > d1) return;
        
        uint64_t h2 = __builtin_bswap64(s[2]);
        if (h2 < d2) goto found;
        if (h2 > d2) return;
        
        uint64_t h3 = __builtin_bswap64(s[3]);
        if (h3 < d3) goto found;
    }
    
    return;

found:
    if (atomicExch(found_flag, 1) == 0) {
        *found_nonce = nonce;
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
    
    uint64_t c[4] = {0};
    for(int i=0; i<4; i++) {
        for(int j=0; j<8; j++) {
            c[i] |= ((uint64_t)h_challenge[i*8 + j] << (j * 8));
        }
    }
    
    uint64_t d[4] = {0};
    for(int i=0; i<4; i++) {
        for(int j=0; j<8; j++) {
            d[i] = (d[i] << 8) | h_difficulty[i*8 + j];
        }
    }

    uint64_t *d_found_nonce;
    int *d_found_flag, h_found_flag = 0;
    cudaMalloc(&d_found_nonce, sizeof(uint64_t));
    cudaMalloc(&d_found_flag, sizeof(int));
    cudaMemset(d_found_flag, 0, sizeof(int));
    
    int threads = 256;
    int blocks = 1024 * 128; // Increased from 64 to 128 for higher GPU occupancy
    
    auto start_time = std::chrono::high_resolution_clock::now();
    int iteration = 0;
    
    while (true) {
        mine_kernel<<<blocks, threads>>>(c[0], c[1], c[2], c[3],
                                         d[0], d[1], d[2], d[3],
                                         start_nonce, d_found_nonce, d_found_flag);
        cudaDeviceSynchronize();
        cudaMemcpy(&h_found_flag, d_found_flag, sizeof(int), cudaMemcpyDeviceToHost);
        
        if (h_found_flag) {
            uint64_t h_found_nonce;
            cudaMemcpy(&h_found_nonce, d_found_nonce, sizeof(uint64_t), cudaMemcpyDeviceToHost);
            std::cout << h_found_nonce << std::endl;
            break;
        }

        iteration++;
        if (iteration % 50 == 0) {
            auto end_time = std::chrono::high_resolution_clock::now();
            std::chrono::duration<double> diff = end_time - start_time;
            double hashrate = (double)iteration * blocks * threads / diff.count();
            std::cerr << "Hashrate: " << (hashrate / 1e6) << " MH/s" << std::endl;
        }

        start_nonce += (uint64_t)blocks * threads;
    }
    cudaFree(d_found_nonce); cudaFree(d_found_flag);
    return 0;
}
