/*
 * Copyright (c) 2025 Yusuf Yamak <yamakyusuf@gmail.com>
 *
 * SPDX-License-Identifier: Apache-2.0
 */

/**
 * \brief 128-bit Xorshift Pseudo-Random Number Generator
 *
 * Implements a simple xorshift128 PRNG for generating pseudo-random numbers.
 * Can be periodically seeded from an external TRNG source.
 *
 * Ports:
 *  - clk_i: Clock
 *  - rst_ni: Active-low reset
 *  - enable_i: Enable PRNG operation
 *  - seed_enable_i: Enable seeding from TRNG
 *  - seed_data_i: 8-bit TRNG seed data
 *  - seed_valid_i: TRNG data valid signal
 *  - random_o: 128-bit random output
 */
module xorshift128_prng (
    input  logic        clk_i,
    input  logic        rst_ni,
    input  logic        enable_i,
    input  logic        seed_enable_i,
    input  logic [7:0]  seed_data_i,
    input  logic        seed_valid_i,
    output logic [127:0] random_o
);

    logic [127:0] state_q, state_d;
    logic [127:0] xorshift_next;
    logic [3:0]   seed_byte_cnt_q, seed_byte_cnt_d;
    logic         seeding_q, seeding_d;

    // Xorshift128 algorithm
    always_comb begin
        logic [127:0] t;
        t = state_q ^ (state_q << 11);
        xorshift_next = (state_q >> 8) ^ t ^ (t >> 19);
    end

    // State and seeding logic
    always_comb begin
        state_d = state_q;
        seed_byte_cnt_d = seed_byte_cnt_q;
        seeding_d = seeding_q;

        if (seed_enable_i && seed_valid_i && !seeding_q) begin
            // Start seeding process
            seeding_d = 1'b1;
            seed_byte_cnt_d = 4'd1;
            state_d[7:0] = seed_data_i;
        end else if (seeding_q) begin
            if (seed_valid_i) begin
                // Continue seeding
                case (seed_byte_cnt_q)
                    4'd1: state_d[15:8]   = seed_data_i;
                    4'd2: state_d[23:16]  = seed_data_i;
                    4'd3: state_d[31:24]  = seed_data_i;
                    4'd4: state_d[39:32]  = seed_data_i;
                    4'd5: state_d[47:40]  = seed_data_i;
                    4'd6: state_d[55:48]  = seed_data_i;
                    4'd7: state_d[63:56]  = seed_data_i;
                    4'd8: state_d[71:64]  = seed_data_i;
                    4'd9: state_d[79:72]  = seed_data_i;
                    4'd10: state_d[87:80]  = seed_data_i;
                    4'd11: state_d[95:88]  = seed_data_i;
                    4'd12: state_d[103:96] = seed_data_i;
                    4'd13: state_d[111:104] = seed_data_i;
                    4'd14: state_d[119:112] = seed_data_i;
                    4'd15: begin
                        state_d[127:120] = seed_data_i;
                        seeding_d = 1'b0;
                        seed_byte_cnt_d = 4'd0;
                    end
                    default: ;  // Use default from line 46
                endcase
                
                if (seed_byte_cnt_q < 4'd15) begin
                    seed_byte_cnt_d = seed_byte_cnt_q + 4'd1;
                end
            end
        end else if (enable_i) begin
            // Normal operation: generate next random number
            state_d = xorshift_next;
        end
    end

    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            state_q <= 128'hDEADBEEF_CAFEBABE_DEADC0DE_12345678;  // Initial seed
            seed_byte_cnt_q <= 4'd0;
            seeding_q <= 1'b0;
        end else begin
            state_q <= state_d;
            seed_byte_cnt_q <= seed_byte_cnt_d;
            seeding_q <= seeding_d;
        end
    end

    assign random_o = state_q;

endmodule
