/*
 * Copyright (c) 2021 Quim Aguado
 *
 * Permission is hereby granted, free of charge, to any person obtaining a copy of
 * this software and associated documentation files (the "Software"), to deal in
 * the Software without restriction, including without limitation the rights to
 * use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of
 * the Software, and to permit persons to whom the Software is furnished to do so,
 * subject to the following conditions:
 *
 * The above copyright notice and this permission notice shall be included in all
 * copies or substantial portions of the Software.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 * IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS
 * FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR
 * COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER
 * IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN
 * CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
 */

#include <stdint.h>
#include <stdio.h>
#include "kernels/sequence_packing_kernel.cuh"

// Encode one sequence from 8 to 2 bits
__global__ void compact_sequences (const char* const sequences_in,
                                   char* const sequences_out,
                                   const sequence_pair_t* sequences_metadata,
                                   const size_t shared_memory_size) {
    const size_t sequence_idx = blockIdx.x;
    const sequence_pair_t curr_alignment = sequences_metadata[sequence_idx / 2];
    const char* sequence_unpacked;
    char* sequence_packed;
    size_t sequence_unpacked_length;
    if ((sequence_idx % 2) == 0) {
        sequence_unpacked = &sequences_in[curr_alignment.pattern_offset];
        sequence_unpacked_length = curr_alignment.pattern_len;
        sequence_packed = &sequences_out[curr_alignment.pattern_offset_packed];
    } else {
        sequence_unpacked = &sequences_in[curr_alignment.text_offset];
        sequence_unpacked_length = curr_alignment.text_len;
        sequence_packed = &sequences_out[curr_alignment.text_offset_packed];
    }
    //size_t sequence_packed_length = sequence_unpacked_length -
    //                                    (4 - (sequence_unpacked_length % 4));

    // Sequence cache
    extern __shared__ char sequence_sh[];

    size_t read_bytes = 0;
    do {
        // Load cache
        for (int i=threadIdx.x*4; (i<(shared_memory_size/4)) && (i < sequence_unpacked_length); i += blockDim.x*4) {
            *(uint32_t*)(&sequence_sh[i]) = *(uint32_t*)(&sequence_unpacked[read_bytes + i]);
        }

        __syncthreads();

        // Each thread packs 4 bytes into 1 byte.
        for (int i=threadIdx.x; i<(sequence_unpacked_length/4); i += blockDim.x) {
            uint32_t bases = *((uint32_t*)(sequence_unpacked + i*4));
            if (bases == 0)
                break;

            // Extract bases SIMD like --> (base & 6) >> 1 for each element
            bases = (bases & 0x06060606) >> 1;

            const uint8_t base0 = bases & 0xff;
            const uint8_t base1 = (bases >> 8) & 0xff;
            const uint8_t base2 = (bases >> 16) & 0xff;
            const uint8_t base3 = (bases >> 24) & 0xff;

            // Reverse the bases, because they are read in little endian
            uint8_t packed_reg = base3;
            packed_reg |= (base2 << 2);
            packed_reg |= (base1 << 4);
            packed_reg |= (base0 << 6);

            // Byte idx if we were packing the sequences in big endian
            const int be_idx = i;

            // Save to the correct by to be little endian encoded for 32bits ints
            int le_byte_idx;
            switch (be_idx % 4) {
                case 0:
                    le_byte_idx = be_idx + (3 - (be_idx % 4));
                    break;
                case 1:
                    le_byte_idx = be_idx + (be_idx % 4);
                    break;
                case 2:
                    le_byte_idx = be_idx - (3 - (be_idx % 4));
                    break;
                case 3:
                default:
                    le_byte_idx = be_idx - (be_idx % 4);
                    break;
            }

            sequence_packed[le_byte_idx] = packed_reg;
        }

        read_bytes += shared_memory_size;
    } while ((read_bytes+shared_memory_size) < sequence_unpacked_length);
}