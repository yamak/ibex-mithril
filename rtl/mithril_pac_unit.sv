/*
 * Copyright (c) 2025 Yusuf Yamak <yamakyusuf@gmail.com>
 *
 * SPDX-License-Identifier: Apache-2.0
 */

module mithril_pac_unit (
  input logic clk_i,
  input logic rst_ni,
  input logic [127:0] key,
  input logic [31:0] ra_i,
  input logic [31:0] sp_i,
  input logic [31:0] s0_i,
  input logic [31:0] s1_i,
  input logic [31:0] s2_i,
  input logic [31:0] s3_i,
  input logic [21:0] site_id_i,
  input logic trap_ctx_i,
  input logic calculate_i,
  input logic verify_i,
  input logic [63:0] pac_i,
  output logic [31:0] pac_lo_o,
  output logic [31:0] pac_hi_o,
  output logic valid_o,
  output logic pac_mismatch_o
);

logic [63:0] tweak;
logic [63:0] qarma_result;
logic [21:0] site_id_reg;
logic [21:0] site_id_shadow_reg;
logic qarma_valid;
logic start_qarma;
logic trap_ctx_q; // latched domain for atomic PAC ops

typedef enum {
  IDLE,
  CALCULATE_PAC,
  VERIFY_PAC
} state_t;

state_t state_reg;
state_t state_next;


qarma64_enc_core qarma64_enc_core_inst (
    .clk_i(clk_i),
    .rst_ni(rst_ni),
    .block_i({ra_i, sp_i}),
    .key_i(key),
    .tweak_i(tweak),
    .start_i(start_qarma),
    .ready_o(),
    .valid_o(qarma_valid),
    .result_o(qarma_result)
  );    

always_ff @(posedge clk_i or negedge rst_ni) begin
  if (!rst_ni) begin
    site_id_reg <= 22'b0;
    site_id_shadow_reg <= 22'b0;
    state_reg <= IDLE;
    trap_ctx_q <= 1'b0;
  end
  else begin
    state_reg <= state_next;
    // Latch domain at operation start to keep bank selection consistent
    if (state_reg == IDLE && (calculate_i || verify_i))
      trap_ctx_q <= trap_ctx_i;
      // Site ID write follows current domain; trap_ctx_q latched in the same cycle
      if (trap_ctx_q) begin
        site_id_shadow_reg <= site_id_i;
      end else begin
        site_id_reg <= site_id_i;
      end
  
  end
end

always_comb begin
  state_next = state_reg;
  start_qarma = 1'b0;
  tweak = 64'b0;
  pac_mismatch_o = 1'b0;
  case (state_reg)
    IDLE: begin
      if (calculate_i) begin
        tweak = {s3_i, s2_i, s1_i, s0_i, site_id_i}[63:0];
        start_qarma = 1'b1;
        state_next = CALCULATE_PAC;
      end
      else if (verify_i) begin
        // Use latched domain for site-id selection during verify
        tweak = {s3_i, s2_i, s1_i, s0_i, trap_ctx_q ? site_id_shadow_reg : site_id_reg}[63:0];
        start_qarma = 1'b1;
        state_next = VERIFY_PAC;
      end
    end
    CALCULATE_PAC: begin
      if (qarma_valid) begin
        state_next = IDLE;
      end
    end
    VERIFY_PAC: begin
      if(qarma_valid) begin
        state_next = IDLE;
        if (qarma_result == pac_i) begin
          pac_mismatch_o = 1'b0;
        end else begin
          pac_mismatch_o = 1'b1;
        end
      end 
    end
  endcase
end

assign pac_lo_o = qarma_result[31:0];
assign pac_hi_o = qarma_result[63:32];
assign valid_o = qarma_valid;

endmodule

