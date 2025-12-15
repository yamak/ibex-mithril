/*
 * Copyright (c) 2025 Yusuf Yamak <yamakyusuf@gmail.com>
 *
 * SPDX-License-Identifier: Apache-2.0
 */

/**
 * \brief QARMA-64 core (Midori S-box, 64-bit block)
 *
 * Implements the QARMA-64 tweakable block cipher. The pipeline runs in two
 * stages: forward (with pseudo-reflection) and backward. Synthesis-oriented,
 * single-block per start, single-cycle combinational per stage.
 *
 * \param ROUNDS Number of forward/backward rounds (default: 5)
 *
 * Ports:
 *  - clk_i: Clock
 *  - rst_ni: Active-low reset
 *  - start_i: Start pulse (sampled in STAGE1)
 *  - block_i: 64-bit input plaintext block
 *  - key_i: 128-bit key, concatenated as {w0, k0}
 *  - tweak_i: 64-bit tweak value
 *  - valid_o: High when result_o is valid (during STAGE2)
 *  - result_o: 64-bit output ciphertext block
 */
module qarma64_enc_core #(
    parameter int unsigned ROUNDS = 5
) (
    input logic clk_i,
    input logic rst_ni,
    input [63:0] block_i,
    input logic [127:0] key_i,
    input logic [63:0] tweak_i,
    input logic start_i,
    output logic valid_o,
    output logic [63:0] result_o
    );

/** Round constants (RC) used in forward/backward rounds */
localparam logic [63:0] RC [0:6] = {
    64'h0000_0000_0000_0000,
    64'h1319_8A2E_0370_7344,
    64'hA409_3822_299F_31D0,
    64'h082E_FA98_EC4E_6C89,
    64'h4528_21E6_38D0_1377,
    64'hBE54_66CF_34E9_0C6C,
    64'h3F84_D5B5_B547_0917
    
};

typedef logic [63:0] tweak_t;
typedef logic [127:0] key_t;
typedef logic [63:0] block_t;
typedef logic [63:0] u64_t;
typedef logic [3:0] nibble_t;

/** Alpha constant used in backward round keying */
localparam logic [63:0] ALPHA = 64'hC0AC_29B7_C97C_50DD;
/** Two-stage controller: STAGE1 (forward/reflection), STAGE2 (backward/final) */
typedef enum {
    STAGE1,
    STAGE2
} state_t;


/**
 * \brief Initial whitening
 * \param block Input state
 * \param key Whitening key (w0)
 * \return block ^ key
 */
function automatic block_t initial_whitening(input block_t block, input u64_t key);
    return block ^ key;
endfunction

/**
 * \brief ShuffleCells (tau): forward nibble permutation
 * \param block Input state
 * \return Permuted state
 */
function automatic block_t shuffle_tau(input block_t block);
    const int unsigned p[16] = '{0,11,6,13,10,1,12,7,5,14,3,8,15,4,9,2};
    nibble_t v[16], y[16]; block_t r;
    for (int i=0;i<16;i++) v[i]=block[63-4*i -:4];
    for (int i=0;i<16;i++) y[i]=v[p[i]];
    for (int i=0;i<16;i++) r[63-4*i -:4]=y[i];
    return r;
endfunction

/**
 * \brief ShuffleCells inverse (tau^-1): inverse nibble permutation
 * \param block Input state
 * \return Inversely permuted state
 */
function automatic block_t shuffle_tau_inv(input block_t block);
    const int unsigned p_inv[16] = '{0,5,15,10,13,8,2,7,11,14,4,1,6,3,9,12};
    nibble_t v[16], y[16]; block_t r;
    for (int i=0;i<16;i++) v[i] = block[63-4*i -:4];
    for (int i=0;i<16;i++) y[i] = v[p_inv[i]];
    for (int i=0;i<16;i++) r[63-4*i -:4] = y[i];
    return r;
endfunction


/** Rotate nibble left by 1 bit */
function automatic nibble_t rol1(input nibble_t x);
    return {x[2:0], x[3]};
endfunction

/** Rotate nibble left by 2 bits */
function automatic nibble_t rol2(input nibble_t x);
    return {x[1:0], x[3:2]};
endfunction

/**
 * \brief Theta (column mix): linear diffusion per column (involutory)
 * \param block Input state
 * \return Mixed state
 */
function automatic block_t mix_columns(input block_t block);
    nibble_t x[16], y[16];
    block_t r;
    for (int col=0;col<4;col++)
        for(int row=0;row<4;row++)
            x[col*4+row]=block[63-4*(row*4+col) -:4];
    for (int col=0;col<4;col++) begin
        y[col*4+0] = rol1(x[col*4+1]) ^ rol2(x[col*4+2]) ^ rol1(x[col*4+3]);
        y[col*4+1] = rol1(x[col*4+0]) ^ rol1(x[col*4+2]) ^ rol2(x[col*4+3]);
        y[col*4+2] = rol2(x[col*4+0]) ^ rol1(x[col*4+1]) ^ rol1(x[col*4+3]);
        y[col*4+3] = rol1(x[col*4+0]) ^ rol2(x[col*4+1]) ^ rol1(x[col*4+2]);
        for(int row=0;row<4;row++)
            r[63-4*(row*4+col) -:4]=y[col*4+row];
    end
    return r;
endfunction

/** Midori S-box (forward) */
function automatic nibble_t sbox_midori(input nibble_t x);
    unique case (x)
        4'h0: sbox_midori=4'hA; 4'h1: sbox_midori=4'hD; 4'h2: sbox_midori=4'hE; 4'h3: sbox_midori=4'h6;
        4'h4: sbox_midori=4'hF; 4'h5: sbox_midori=4'h7; 4'h6: sbox_midori=4'h3; 4'h7: sbox_midori=4'h5;
        4'h8: sbox_midori=4'h9; 4'h9: sbox_midori=4'h8; 4'hA: sbox_midori=4'h0; 4'hB: sbox_midori=4'hC;
        4'hC: sbox_midori=4'hB; 4'hD: sbox_midori=4'h1; 4'hE: sbox_midori=4'h2; 4'hF: sbox_midori=4'h4;
    endcase
endfunction

/** Midori S-box (inverse) */
function automatic nibble_t sbox_midori_inv(input nibble_t x);
    unique case (x)
        4'hA: sbox_midori_inv=4'h0; 4'hD: sbox_midori_inv=4'h1; 4'hE: sbox_midori_inv=4'h2; 4'h6: sbox_midori_inv=4'h3;
        4'hF: sbox_midori_inv=4'h4; 4'h7: sbox_midori_inv=4'h5; 4'h3: sbox_midori_inv=4'h6; 4'h5: sbox_midori_inv=4'h7;
        4'h9: sbox_midori_inv=4'h8; 4'h8: sbox_midori_inv=4'h9; 4'h0: sbox_midori_inv=4'hA; 4'hC: sbox_midori_inv=4'hB;
        4'hB: sbox_midori_inv=4'hC; 4'h1: sbox_midori_inv=4'hD; 4'h2: sbox_midori_inv=4'hE; 4'h4: sbox_midori_inv=4'hF;
    endcase
endfunction

/**
 * \brief SubCells (apply S-box forward on all nibbles)
 * \param block Input state
 * \return Substituted state
 */
function automatic block_t subcells(input block_t block);
    block_t r;
    for (int i=0;i<16;i++) begin
        logic [3:0] nibble = block[63-4*i -:4];
        r[63-4*i -:4] = sbox_midori(nibble);
    end
    return r;
endfunction

/**
 * \brief SubCells inverse (apply inverse S-box on all nibbles)
 * \param block Input state
 * \return Inversely substituted state
 */
function automatic block_t subcells_inv(input block_t block);

    block_t r;
    for (int i=0;i<16;i++) begin
        logic [3:0] nibble = block[63-4*i -:4];
        r[63-4*i -:4] = sbox_midori_inv(nibble);
    end
    return r;
endfunction

/**
 * \brief Forward round
 * s ^ tk → (if full: shuffle_tau → mix_columns) → subcells
 * \param s Input state
 * \param tk Round tweakey
 * \param full 1 for full round, 0 for short round (r==0)
 */
function automatic block_t forward(input block_t s, input u64_t tk, bit full);
    block_t x = s ^ tk;
    if(full) begin
        x = shuffle_tau(x);
        x = mix_columns(x);
    end
    x = subcells(x);
    return x;
endfunction

/**
 * \brief Backward round
 * subcells_inv → (if full: mix_columns → shuffle_tau_inv) → XOR tk
 * \param s Input state
 * \param tk Round tweakey
 * \param full 1 for full round, 0 for short round (r==0)
 */
function automatic block_t backward(input block_t s, input u64_t tk, bit full);
    block_t x = s;
    x = subcells_inv(x);
    if(full) begin
        x = mix_columns(x);
        x = shuffle_tau_inv(x);
    end
    x = x ^ tk;
    return x;
endfunction


/** 4-bit LFSR forward used in tweak update */
function automatic nibble_t lfsr4_fw(input nibble_t x);
    return {x[0]^x[1], x[3], x[2], x[1]};
endfunction

/** 4-bit LFSR inverse used in backward tweak update */
function automatic nibble_t lfsr4_bw(input nibble_t x);
    return {x[2],x[1],x[0],x[3]^x[0]};
endfunction

/**
 * \brief Tweak forward update
 * Applies h permutation, then LFSR on selected nibble indices.
 * \param x Current tweak
 * \return Updated tweak
 */
function automatic tweak_t tweak_update_fw(input tweak_t x);
    const int unsigned h[16] = '{6,5,14,15,0,1,2,3,7,12,13,4,8,9,10,11};
    nibble_t nibble[16], nibble_h[16];
    tweak_t r;
    for(int i=0;i<16;i++)
        nibble[i] = x[63-4*i -:4];
    for(int i=0;i<16;i++)
        nibble_h[i] = nibble[h[i]];
    for(int i=0;i<16;i++) begin
        unique case (i)
        0,1,3,4,8,11,13: nibble_h[i] = lfsr4_fw(nibble_h[i]);
        default: ;
        endcase
    end
    for(int i=0;i<16;i++)
        r[63-4*i -:4] = nibble_h[i];
    return r;
endfunction

/**
 * \brief Tweak backward update
 * Applies inverse LFSR on selected indices, then h_inv permutation.
 * \param x Current tweak
 * \return Updated tweak
 */
function automatic tweak_t tweak_update_bw(input tweak_t x);
    const int unsigned h_inv[16] = '{4, 5, 6, 7, 11, 1, 0, 8, 12, 13, 14, 15, 9, 10, 2, 3};
    nibble_t nibble[16], nibble_h[16];
    tweak_t r;
    for(int i=0;i<16;i++)
        nibble[i] = x[63-4*i -:4];
    for(int i=0;i<16;i++) begin
        unique case (i)
        0,1,3,4,8,11,13: nibble[i] = lfsr4_bw(nibble[i]);
        default: ;
        endcase
    end
    for(int i=0;i<16;i++)
        nibble_h[i] = nibble[h_inv[i]];
    for(int i=0;i<16;i++)
        r[63-4*i -:4] = nibble_h[i];
    return r;
endfunction

/**
 * \brief Pseudo-reflection layer
 * shuffle_tau → mix_columns → XOR k → shuffle_tau_inv
 * \param x Input state
 * \param k Key word k0
 * \return Reflected state
 */
function automatic block_t pseudo_reflect(input block_t x, input u64_t k);
    block_t s;
    s = shuffle_tau(x);
    s = mix_columns(s);
    s = s ^ k;
    s = shuffle_tau_inv(s);
    return s;
endfunction


/**
 * \brief Stage 1 computation
 * Whitening with w0, ROUNDS forward rounds (r=0 short), forward with w1,
 * pseudo-reflection with k0, then one backward round with w0.
 * \param key {w0,k0}
 * \param tweak_in Input tweak
 * \param block_in Input block
 * \param block_out Output state after stage 1
 * \param tweak_out Tweak after stage 1
 */
function automatic void compute_stage1(
    input key_t key,
    input tweak_t tweak_in,
    input block_t block_in,
    output block_t block_out,
    output tweak_t tweak_out
);
    u64_t w0_l = key[127:64];
    u64_t k0_l = key[63:0];
    u64_t w1_l = {w0_l[0],w0_l[63:1]} ^ {63'b0,w0_l[63]};

    block_t is = initial_whitening(block_in, w0_l);
    tweak_t tweak = tweak_in;

    for (int i = 0; i < ROUNDS; i++) begin
        is = forward(is, k0_l ^ tweak ^ RC[i], i > 0);
        tweak = tweak_update_fw(tweak);
    end

    is = forward(is, w1_l ^ tweak, 1);
    is = pseudo_reflect(is, k0_l);
    is = backward(is, w0_l ^ tweak, 1);

    block_out = is;
    tweak_out = tweak;
endfunction

/**
 * \brief Stage 2 computation
 * ROUNDS backward rounds with backward tweak updates and ALPHA, then final XOR w1.
 * \param key {w0,k0}
 * \param tweak_in Tweak from stage 1
 * \param block_in State from stage 1
 * \param block_out Final block
 * \param tweak_out Final tweak
 */
function automatic void compute_stage2(
    input key_t key,
    input tweak_t tweak_in,
    input block_t block_in,
    output block_t block_out
);
u64_t w0_l = key[127:64];
u64_t k0_l = key[63:0];
u64_t w1_l = {w0_l[0],w0_l[63:1]} ^ {63'b0,w0_l[63]};
block_t is = block_in;
tweak_t tweak = tweak_in;

for (int i = ROUNDS-1; i >= 0; i--) begin
    tweak = tweak_update_bw(tweak);
    is = backward(is, k0_l ^ tweak ^ RC[i] ^ ALPHA, i > 0);
end

is ^= w1_l;

block_out = is;
endfunction

block_t is_stage_reg, is_stage_next;
tweak_t tweak_stage_reg, tweak_stage_next;
logic stage2_valid_reg, stage2_valid_next;

/** Register stage: state/tweak/state machine */
always_ff @(posedge clk_i or negedge rst_ni) begin
    if(!rst_ni) begin
        is_stage_reg <= 0;
        tweak_stage_reg <= 0;
        stage2_valid_reg <= 0;
    end
    else begin
        is_stage_reg <= is_stage_next;
        tweak_stage_reg <= tweak_stage_next;
        stage2_valid_reg <= stage2_valid_next;
    end
end

/** Combinational next-state/output logic */
always_comb begin
    is_stage_next = is_stage_reg;
    tweak_stage_next = tweak_stage_reg;
    stage2_valid_next = 1'b0;
    if(start_i) begin
        compute_stage1(key_i, tweak_i, block_i, is_stage_next, tweak_stage_next);
        stage2_valid_next = 1'b1;
    end
    compute_stage2(key_i, tweak_stage_reg, is_stage_reg, result_o);
end

assign valid_o = stage2_valid_reg;

endmodule
