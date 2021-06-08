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

#include <stdbool.h>
#include <stdio.h>
#include <cuda_runtime.h>
#include "sequence_alignment_kernel.cuh"

#define MAX_PB(A, B) llmax((A), (B))
#define MAX(A, B) max((A), (B))
#define MIN(A, B) min((A), (B))

// At least one of the highest two bits is set
#define BT_WORD_FULL_CMP 0x4000
#define BT_IS_FULL(bt_word) ((bt_word) >= BT_WORD_FULL_CMP)

#ifdef DEBUG

#define PPRINT_WFS(aws, wfs, d, title) pprint_wavefronts(aws, wfs, d, title)
__device__ void pprint_wavefronts (const int active_working_set_size,
                                   wfa_wavefront_t* wavefronts,
                                   const int distance,
                                   char* title) {
    if (threadIdx.x == 0) {
        if (!title) title = (char*)("");

        printf("%s (distance: %d)\n", title, distance);

        //const int wf_padding_len = 14;

        // Header (WF number)
        for (int i=0; i<active_working_set_size; i++) {
            const int curr_n = i - (active_working_set_size - 1);
            printf("| %.2d          ", curr_n);
        }
        printf(" |\n");

        // exist
        for (int i=0; i<active_working_set_size; i++) {
            printf("| exist: %d     ", wavefronts[i].exist);
        }
        printf("|\n");

        for (int i=0; i<active_working_set_size; i++) {
            printf("| hi=%.2d, lo=%.2d", wavefronts[i].hi, wavefronts[i].lo);
        }
        printf("|\n");
    }
    __syncthreads();
}

#else // DEBUG

#define PPRINT_WFS(aws, wfs, d, title) pprint_wavefronts(aws, wfs, d, title)

#endif // DEBUG


__device__ wfa_offset_t WF_extend_kernel (const char* text,
                                  const char* pattern,
                                  const int tlen,
                                  const int plen,
                                  const int k,
                                  const wfa_offset_t offset_k) {
    int v  = EWAVEFRONT_V(k, offset_k);
    int h  = EWAVEFRONT_H(k, offset_k);

    const int bases_to_cmp = 16;
    int eq_elements = 0;
    int acc = 0;
    // Compare 16 bases at once
    while (v < plen && h < tlen) {
        // Which byte to pick
        int real_v = v / 4;
        int real_h = h / 4;

        // Get the displacement inside the aligned word
        int pattern_displacement = v % bases_to_cmp;
        int text_displacement = h % bases_to_cmp;

        // 0xffffffffffffff00
        uintptr_t alignment_mask = (uintptr_t)-1 << 2;
        uint32_t* word_p_ptr = (uint32_t*)((uintptr_t)(pattern + real_v) & alignment_mask);
        uint32_t* next_word_p_ptr = word_p_ptr + 1;
        uint32_t* word_t_ptr = (uint32_t*)((uintptr_t)(text + real_h) & alignment_mask);
        uint32_t* next_word_t_ptr = word_t_ptr + 1;


        // * 2 because each element is 2 bits
        uint32_t sub_word_p_1 = *word_p_ptr;
        uint32_t sub_word_p_2 = *next_word_p_ptr;
        sub_word_p_1 = sub_word_p_1 << (pattern_displacement * 2);
        // Convert the u32 to big-endian, as little endian inverts the order
        // for the sequences.
        sub_word_p_2 = *next_word_p_ptr;
        // Cast to uint64_t is done to avoid undefined behaviour in case
        // it's shifted by 32 elements.
        // ----
        // The type of the result is that of the promoted left operand. The
        // behavior is undefined if the right operand is negative, or
        // greater than or equal to the length in bits of the promoted left
        // operand.
        // ----
        sub_word_p_2 = ((uint64_t)sub_word_p_2) >>
            ((bases_to_cmp - pattern_displacement) * 2);

        uint32_t sub_word_t_1 = *word_t_ptr;
        sub_word_t_1 = sub_word_t_1 << (text_displacement * 2);
        uint32_t sub_word_t_2 = *next_word_t_ptr;
        sub_word_t_2 = ((uint64_t)sub_word_t_2) >>
            ((bases_to_cmp - text_displacement) * 2);

        uint32_t word_p = sub_word_p_1 | sub_word_p_2;
        uint32_t word_t = sub_word_t_1 | sub_word_t_2;

        uint32_t diff = word_p ^ word_t;
        // Branchless method to remove the equal bits if we read "too far away"
        uint32_t full_mask = (uint32_t)-1;
        int next_v = v + bases_to_cmp;
        int next_h = h + bases_to_cmp;
        uint32_t mask_p = full_mask << ((next_v - plen) * 2 * (next_v > plen));
        uint32_t mask_t = full_mask << ((next_h - tlen) * 2 * (next_h > tlen));
        diff = diff | ~mask_p | ~mask_t;

        int lz = __clz(diff);

        // each element has 2 bits
        eq_elements = lz / 2;
        acc += eq_elements;

        if (eq_elements < bases_to_cmp) {
            break;
        }


        v += bases_to_cmp;
        h += bases_to_cmp;
    }

    return offset_k + acc;
}

__device__ uint16_t offload_backtrace (unsigned int* const last_free_bt_position,
                                   const wfa_backtrace_t backtrace,
                                   wfa_backtrace_t* const global_backtraces_array) {
    uint32_t old_val = atomicAdd(last_free_bt_position, 1);

    global_backtraces_array[old_val].backtrace = backtrace.backtrace;
    global_backtraces_array[old_val].prev = backtrace.prev;

    //printf("(tid = %d) Offloading backtrace! old: %d\n", threadIdx.x, old_val);

    // TODO: Check if new_val is more than 16 bits
    return (uint16_t)old_val;
}

__device__ void next_M (wfa_wavefront_t* M_wavefronts,
                        const int curr_wf,
                        const int active_working_set_size,
                        const int x,
                        const char* text,
                        const char* pattern,
                        const int tlen,
                        const int plen,
                        unsigned int* const last_free_bt_position,
                        wfa_backtrace_t* const offloaded_backtraces) {
    // The wavefront do not grow in case of mismatch
    const wfa_wavefront_t* prev_wf = &M_wavefronts[(curr_wf + x) % active_working_set_size];
    const int hi = prev_wf->hi;
    const int lo = prev_wf->lo;

    for (int k=lo + threadIdx.x; k <= hi; k+=blockDim.x) {
        wfa_offset_t curr_offset = prev_wf->offsets[k] + 1;

        curr_offset = WF_extend_kernel(text, pattern,
                                       tlen, plen, k, curr_offset);

        M_wavefronts[curr_wf].offsets[k] = curr_offset;

        wfa_backtrace_t prev_bt = prev_wf->backtraces[k];
        uint16_t backtrace_val = (prev_bt.backtrace << 2) | OP_SUB;
        uint16_t prev = prev_bt.prev;
        wfa_backtrace_t M_backtrace = {
            .backtrace = backtrace_val,
            .prev = prev
            };

        if (BT_IS_FULL(backtrace_val)) {
            prev = offload_backtrace(last_free_bt_position,
                                     M_backtrace,
                                     offloaded_backtraces);
            M_backtrace = {.backtrace = 0, .prev = prev};
        }

        M_wavefronts[curr_wf].backtraces[k] = M_backtrace;
    }

    if (threadIdx.x == 0) {
        M_wavefronts[curr_wf].hi = hi;
        M_wavefronts[curr_wf].lo = lo;
        M_wavefronts[curr_wf].exist= true;
    }
}

__device__ void next_MDI (wfa_wavefront_t* M_wavefronts,
                          wfa_wavefront_t* I_wavefronts,
                          wfa_wavefront_t* D_wavefronts,
                          const int curr_wf,
                          const int active_working_set_size,
                          const int x,
                          const int o,
                          const int e,
                          const char* text,
                          const char* pattern,
                          const int tlen,
                          const int plen,
                          unsigned int* const last_free_bt_position,
                          wfa_backtrace_t* const offloaded_backtraces) {
    const wfa_wavefront_t* prev_wf_x =   &M_wavefronts[(curr_wf + x) % active_working_set_size];
    const wfa_wavefront_t* prev_wf_o =   &M_wavefronts[(curr_wf + o + e) % active_working_set_size];
    const wfa_wavefront_t* prev_I_wf_e = &I_wavefronts[(curr_wf + e) % active_working_set_size];
    const wfa_wavefront_t* prev_D_wf_e = &D_wavefronts[(curr_wf + e) % active_working_set_size];

    const int hi_ID = MAX(prev_wf_o->hi, MAX(prev_I_wf_e->hi, prev_D_wf_e->hi)) + 1;
    const int hi    = MAX(prev_wf_x->hi, hi_ID);
    const int lo_ID = MIN(prev_wf_o->lo, MIN(prev_I_wf_e->lo, prev_D_wf_e->lo)) - 1;
    const int lo    = MIN(prev_wf_x->lo, lo_ID);

    for (int k=lo + threadIdx.x; k <= hi; k+=blockDim.x) {
        // ~I offsets
        const wfa_offset_t I_gap_open_offset = prev_wf_o->offsets[k - 1] + 1;
        const wfa_backtrace_t I_gap_open_bt = prev_wf_o->backtraces[k - 1];
        const int64_t I_gap_open_offset_pb = (int64_t)
                                  ((uint64_t)I_gap_open_offset << 32)
                                  | ((uint32_t)I_gap_open_bt.backtrace << 16)
                                  | I_gap_open_bt.prev;

        const wfa_offset_t I_gap_extend_offset = prev_I_wf_e->offsets[k - 1] + 1;
        const wfa_backtrace_t I_gap_extend_bt = prev_I_wf_e->backtraces[k - 1];
        const int64_t I_gap_extend_offset_pb = (int64_t)
                                ((uint64_t)I_gap_extend_offset << 32)
                                | ((uint32_t)I_gap_extend_bt.backtrace << 16)
                                | I_gap_extend_bt.prev;

        int64_t I_offset_pb = MAX_PB(I_gap_open_offset_pb,
                                     I_gap_extend_offset_pb);

        const wfa_offset_t I_offset = (wfa_offset_t)(I_offset_pb >> 32);
        I_wavefronts[curr_wf].offsets[k] = I_offset;

        // ~I backtraces
        // Include backtrace and previous backtrace offset
        wfa_backtrace_packed_t I_backtrace_packed = \
                        (wfa_backtrace_packed_t)(I_offset_pb & 0xffffffff);

        uint16_t I_backtrace_value = (uint16_t)((I_backtrace_packed >> 16) & 0xffff);
        I_backtrace_value = (I_backtrace_value << 2) | OP_INS;

        uint16_t I_backtrace_prev = (uint16_t)(I_backtrace_packed & 0xffff);

        wfa_backtrace_t I_backtrace = {.backtrace = I_backtrace_value,
                                       .prev = I_backtrace_prev};

        // TODO: Needed to offload ~I and ~D backtraces?
        // Offload ~I backtraces if the bitvector is full
        if (BT_IS_FULL(I_backtrace_value)) {
            uint16_t prev = offload_backtrace(last_free_bt_position,
                                              I_backtrace,
                                              offloaded_backtraces);
            I_backtrace_value = 0;
            I_backtrace_prev = prev;
            I_backtrace = {.backtrace = 0, .prev = prev};
        }

        I_wavefronts[curr_wf].backtraces[k] = I_backtrace;
        I_offset_pb = (uint64_t)(((uint64_t)I_offset << 32)
                                 | ((uint32_t)I_backtrace_value << 16)
                                 | I_backtrace_prev);

        // ~D offsets
        const wfa_offset_t D_gap_open_offset = prev_wf_o->offsets[k + 1];
        const wfa_backtrace_t D_gap_open_bt = prev_wf_o->backtraces[k + 1];
        const int64_t D_gap_open_offset_pb = (int64_t)
                                  ((uint64_t)D_gap_open_offset << 32)
                                  | ((uint32_t)D_gap_open_bt.backtrace << 16)
                                  | D_gap_open_bt.prev;

        const wfa_offset_t D_gap_extend_offset = prev_D_wf_e->offsets[k + 1];
        const wfa_backtrace_t D_gap_extend_bt = prev_D_wf_e->backtraces[k + 1];
        const int64_t D_gap_extend_offset_pb = (int64_t)
                                    (((uint64_t)D_gap_extend_offset << 32)
                                    // TODO
                                    //| *(uint32_t*)&D_gap_extend_bt);
                                    | ((uint32_t)D_gap_extend_bt.backtrace << 16)
                                    | D_gap_extend_bt.prev);

        int64_t D_offset_pb = MAX_PB(D_gap_open_offset_pb,
                                     D_gap_extend_offset_pb);

        const wfa_offset_t D_offset = (wfa_offset_t)(D_offset_pb >> 32);
        D_wavefronts[curr_wf].offsets[k] = D_offset;

        // ~D backtraces
        wfa_backtrace_packed_t D_backtrace_packed = (wfa_backtrace_packed_t)
                                                      (D_offset_pb & 0xffffffff);
        uint16_t D_backtrace_value = (uint16_t)(D_backtrace_packed >> 16);
        D_backtrace_value = (D_backtrace_value << 2) | OP_DEL;

        uint16_t D_backtrace_prev = (uint16_t)(D_backtrace_packed & 0xffff);

        wfa_backtrace_t D_backtrace = {.backtrace = D_backtrace_value,
                                       .prev = D_backtrace_prev};

        // Offload ~D backtraces if the bitvector is full
        if (BT_IS_FULL(D_backtrace_value)) {
            uint16_t prev = offload_backtrace(last_free_bt_position,
                                              D_backtrace,
                                              offloaded_backtraces);
            D_backtrace_value = 0;
            D_backtrace_prev = prev;
            D_backtrace = {.backtrace = 0, .prev = prev};
        }

        D_wavefronts[curr_wf].backtraces[k] = D_backtrace;
        D_offset_pb = (uint64_t)(((uint64_t)D_offset << 32)
                                 | ((uint32_t)D_backtrace_value << 16)
                                 | D_backtrace_prev);

        // ~M update
        const wfa_offset_t X_offset = prev_wf_x->offsets[k] + 1;
        const wfa_backtrace_t X_backtrace = prev_wf_x->backtraces[k];
        const uint16_t X_backtrace_value = (X_backtrace.backtrace << 2) | OP_SUB;
        const int64_t X_offset_pb = (int64_t)
                                     (((uint64_t)X_offset << 32)
                                     | ((uint32_t)X_backtrace_value << 16)
                                     | X_backtrace.prev);

        const int64_t M_offset_pb = MAX_PB(
                                        MAX_PB(X_offset_pb, D_offset_pb),
                                        I_offset_pb
                                        );

        const wfa_backtrace_packed_t M_backtrace_packed = (wfa_backtrace_packed_t)
                                            (M_offset_pb & 0xffffffff);
        const uint16_t M_backtrace_value = (uint16_t)(M_backtrace_packed >> 16);
        const uint16_t M_backtrace_prev = (uint16_t)(M_backtrace_packed & 0xffff);

        wfa_offset_t M_offset = (wfa_offset_t)(M_offset_pb >> 32);
        M_offset = WF_extend_kernel(text, pattern, tlen, plen, k, M_offset);

        M_wavefronts[curr_wf].offsets[k] = M_offset;

        wfa_backtrace_t M_backtrace = {.backtrace = M_backtrace_value,
                                       .prev = M_backtrace_prev};

        // Offload backtraces if the bitvector is full
        if (BT_IS_FULL(M_backtrace_value)) {
            //printf("OFFLOADING BACKTRACES!!!!!\n");
            uint16_t prev = offload_backtrace(last_free_bt_position,
                                              M_backtrace,
                                              offloaded_backtraces);
            M_backtrace = {.backtrace = 0, .prev = prev};
        }

        M_wavefronts[curr_wf].backtraces[k] = M_backtrace;
    }

    if (threadIdx.x == 0) {
        M_wavefronts[curr_wf].hi = hi;
        M_wavefronts[curr_wf].lo = lo;
        M_wavefronts[curr_wf].exist = true;

        I_wavefronts[curr_wf].hi = hi;
        I_wavefronts[curr_wf].lo = lo;
        I_wavefronts[curr_wf].exist = true;

        D_wavefronts[curr_wf].hi = hi;
        D_wavefronts[curr_wf].lo = lo;
        D_wavefronts[curr_wf].exist = true;
    }
}

__device__ void update_curr_wf (wfa_wavefront_t* M_wavefronts,
                                wfa_wavefront_t* I_wavefronts,
                                wfa_wavefront_t* D_wavefronts,
                                const int active_working_set_size,
                                const int max_wf_size,
                                int* curr_wf) {
    // As we read wavefronts "forward" in the waveronts arrays, so the wavefront
    // index is moved backwards.
    const int wf_idx = (*curr_wf - 1 + active_working_set_size) % active_working_set_size;

    // Set new wf to NULL, as new wavefront may be smaller than the
    // previous one
    wfa_offset_t* to_clean_M = M_wavefronts[wf_idx].offsets - (max_wf_size/2);
    M_wavefronts[wf_idx].exist = false;

    wfa_offset_t* to_clean_I = I_wavefronts[wf_idx].offsets - (max_wf_size/2);
    I_wavefronts[wf_idx].exist = false;

    wfa_offset_t* to_clean_D = D_wavefronts[wf_idx].offsets - (max_wf_size/2);
    D_wavefronts[wf_idx].exist = false;

    for (int i=threadIdx.x; i<max_wf_size; i+=blockDim.x) {
        to_clean_M[i] = -1;
        to_clean_D[i] = -1;
        to_clean_I[i] = -1;
    }

    *curr_wf = wf_idx;

}

__global__ void alignment_kernel (
                            const char* packed_sequences_buffer,
                            const sequence_pair_t* sequences_metadata,
                            const size_t num_alignments,
                            const int max_steps,
                            const affine_penalties_t penalties,
                            wfa_backtrace_t* offloaded_backtraces_global,
                            alignment_result_t* results) {
    const int tid = threadIdx.x;
    // m = 0 for WFA
    const int x = penalties.x;
    const int o = penalties.o;
    const int e = penalties.e;

    const sequence_pair_t metadata = sequences_metadata[blockIdx.x];
    const char* text = packed_sequences_buffer + metadata.text_offset_packed;
    const char* pattern = packed_sequences_buffer + metadata.pattern_offset_packed;
    const int tlen = metadata.text_len;
    const int plen = metadata.pattern_len;

    // TODO: Move to function/macro + use in lib/sequence_alignment.cu
    size_t bt_offloaded_size = \
                        // Height
                        (max_steps * 2 + 1)
                        // Width
                        * (max_steps * 2 / 8);
    wfa_backtrace_t* const offloaded_backtraces = \
                 &offloaded_backtraces_global[blockIdx.x * bt_offloaded_size];
;
    // In shared memory:
    // - Offsets for all the wavefronts
    // - Backtraces for all the wavefronts
    // - Wavefronts needed to calculate current WF_s, there are 3 "pyramids" so
    //   this number of wavefront is 3 times (WF_{max(o+e, x)} --> WF_s)
    extern __shared__ char sh_mem[];

    // TODO: +1 because of the current wf?
    const int active_working_set_size = MAX(o+e, x) + 1;
    const int max_wf_size = 2 * max_steps + 1;

    // Offsets and backtraces must be 32 bits aligned to avoid unaligned access
    // errors on the structs
    int offsets_size = active_working_set_size * max_wf_size;
    offsets_size = offsets_size + (4 - (offsets_size % 4));

    int bt_size = active_working_set_size * max_wf_size;
    bt_size = bt_size + (4 - (bt_size % 4));

    wfa_offset_t* M_base = (wfa_offset_t*)sh_mem;
    wfa_offset_t* I_base = M_base + offsets_size;
    wfa_offset_t* D_base = I_base + offsets_size;

    wfa_backtrace_t* M_bt_base = (wfa_backtrace_t*)(D_base + offsets_size);
    wfa_backtrace_t* I_bt_base = M_bt_base + bt_size;
    wfa_backtrace_t* D_bt_base = I_bt_base + bt_size;

    wfa_wavefront_t* M_wavefronts = (wfa_wavefront_t*)(D_bt_base + bt_size);
    wfa_wavefront_t* I_wavefronts = (M_wavefronts + active_working_set_size);
    wfa_wavefront_t* D_wavefronts = (I_wavefronts + active_working_set_size);

    uint32_t* last_free_bt_position = (uint32_t*)
                                          (D_wavefronts + active_working_set_size);

    // Start at 1 because 0 is used as NULL (no more backtraces blocks to
    // recover)
    *last_free_bt_position = 1;

    // Initialize all wavefronts to -1
    for (int i=tid; i<(offsets_size * 3); i+=blockDim.x) {
        M_base[i] = -1;
    }

    for (int i=tid; i<(bt_size * 3); i+=blockDim.x) {
        M_bt_base[i] = {0};
    }

    // Initialize wavefronts memory
    for (int i=tid; i<active_working_set_size; i+=blockDim.x) {
        M_wavefronts[i].offsets = M_base + (i * max_wf_size) + (max_wf_size/2);
        M_wavefronts[i].backtraces = M_bt_base + (i * max_wf_size) + (max_wf_size/2);
        M_wavefronts[i].hi = 0;
        M_wavefronts[i].lo = 0;
        M_wavefronts[i].exist = false;

        I_wavefronts[i].offsets = I_base + (i * max_wf_size) + (max_wf_size/2);
        I_wavefronts[i].backtraces = I_bt_base + (i * max_wf_size) + (max_wf_size/2);
        I_wavefronts[i].hi = 0;
        I_wavefronts[i].lo = 0;
        I_wavefronts[i].exist = false;

        D_wavefronts[i].offsets = D_base + (i * max_wf_size) + (max_wf_size/2);
        D_wavefronts[i].backtraces = D_bt_base + (i * max_wf_size) + (max_wf_size/2);
        D_wavefronts[i].hi = 0;
        D_wavefronts[i].lo = 0;
        D_wavefronts[i].exist = false;
    }

    __syncthreads();

    int curr_wf = 0;

    if (tid == 0) {
        wfa_offset_t initial_ext = WF_extend_kernel(
            text,
            pattern,
            tlen, plen,
            0, 0);
        M_wavefronts[curr_wf].offsets[0] = initial_ext;
        M_wavefronts[curr_wf].exist = true;
    }

    __syncthreads();

    // TODO: Change tarket K if we don't start form WF 0 (cooperative strategy)
    const int target_k = EWAVEFRONT_DIAGONAL(tlen, plen);
    const int target_k_abs = (target_k >= 0) ? target_k : -target_k;
    const wfa_offset_t target_offset = EWAVEFRONT_OFFSET(tlen, plen);

    int distance = 0;
    // steps = number of editions
    int steps = 0;
    // TODO: target_k_abs <= distance or <= steps (?)
    if (!(target_k_abs <= distance && M_wavefronts[curr_wf].exist && M_wavefronts[curr_wf].offsets[target_k] == target_offset)) {

        update_curr_wf(
            M_wavefronts,
            I_wavefronts,
            D_wavefronts,
            active_working_set_size,
            max_wf_size,
            &curr_wf);

        distance++;
        steps++;
        __syncthreads();

        while (steps < (max_steps - 1)) {

            bool M_exist = false;
            bool GAP_exist = false;
            const int o_delta = (curr_wf + o + e) % active_working_set_size;
            const int e_delta = (curr_wf + e) % active_working_set_size;
            const int x_delta = (curr_wf + x) % active_working_set_size;
            if ((distance - o - e) >= 0) {
                // Just test with I because I and D exist in the same distances
                GAP_exist = M_wavefronts[o_delta].exist
                          || I_wavefronts[e_delta].exist;
            }

            if (GAP_exist) {
                M_exist = true;
            } else {
                if ((distance - x) >= 0) {
                    M_exist = M_wavefronts[x_delta].exist;
                } 
            }

            if (!GAP_exist && !M_exist) {
                distance++;
            } else {
                if (M_exist && !GAP_exist) {
                    next_M(M_wavefronts, curr_wf, active_working_set_size, x,
                           text, pattern, tlen, plen,
                           last_free_bt_position, offloaded_backtraces);
                } else {
                    next_MDI(
                        M_wavefronts, I_wavefronts, D_wavefronts,
                        curr_wf, active_working_set_size,
                        x, o, e,
                        text, pattern, tlen, plen,
                        last_free_bt_position, offloaded_backtraces);

                    // Wavefront only grows if there's an operation in the ~I or
                    // ~D matrices
                    steps++;
                }

                // TODO: This is necessary for now, try to find a less sync
                // version
                __syncthreads();

                if (target_k_abs <= distance && M_exist && M_wavefronts[curr_wf].offsets[target_k] == target_offset) {
                    break;
                }

                distance++;
            }

#if 0
// DEVELOPING HELP ONLY
            PPRINT_WFS(active_working_set_size,
                       M_wavefronts,
                       distance,
                       (char*)("~M wavefronts"));
            PPRINT_WFS(active_working_set_size,
                       I_wavefronts,
                       distance,
                       (char*)("~I wavefronts"));
            PPRINT_WFS(active_working_set_size,
                       D_wavefronts,
                       distance,
                       (char*)("~D wavefronts"));
            if (tid == 0) printf("---------------------------------------------\n");
#endif

        update_curr_wf(
            M_wavefronts,
            I_wavefronts,
            D_wavefronts,
            active_working_set_size,
            max_wf_size,
            &curr_wf);

        __syncthreads();
        }
    }

    if  (tid == 0) {
        if (x == 2 && blockIdx.x == 2) printf("d: %d, steps: %d\n", distance, steps);
        results[blockIdx.x].distance = distance;
        results[blockIdx.x].backtrace = M_wavefronts[curr_wf].backtraces[target_k];
    }
}
