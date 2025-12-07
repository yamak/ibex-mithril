/*
 * Copyright (c) 2025 Yusuf Yamak <yamakyusuf@gmail.com>
 *
 * SPDX-License-Identifier: Apache-2.0
 */

module mithril_pac_unit
  import ibex_pkg::*;
(
  input logic clk_i,
  input logic rst_ni,
  input logic [127:0] key_i,
  
  // Register inputs for message/tweak
  input logic [31:0] ra_i,
  input logic [31:0] sp_i,
  input logic [31:0] mepc_i,       // MEPC from CSR
  input logic [31:0] s0_i,
  input logic [31:0] s1_i,
  
  // Message source selection
  input pac_msg_e pac_msg_sel_i,   // PAC_MSG_RA_SP or PAC_MSG_MEPC_SP
  
  // Control signals
  input logic calculate_i,
  input logic verify_i,
  input logic [63:0] pac_i,
  
  // Outputs
  output logic [31:0] pac_lo_o,
  output logic [31:0] pac_hi_o,
  output logic valid_o,
  output logic pac_mismatch_o,
  input logic pac_mismatch_ack_i
);

logic [63:0] tweak;
logic [63:0] message;
logic [63:0] qarma_result;
logic qarma_valid;
logic start_qarma;

typedef enum {
  IDLE,
  CALCULATE_PAC,
  VERIFY_PAC
} state_t;

state_t state_reg;
state_t state_next;
logic pac_mismatch_q, pac_mismatch_d;

// Message source selection mux
always_comb begin
  unique case (pac_msg_sel_i)
    PAC_MSG_RA_SP:   message = {ra_i, sp_i};    // Message = {RA, SP}
    PAC_MSG_MEPC_SP: message = {mepc_i, sp_i};  // Message = {MEPC, SP}
    default:         message = {ra_i, sp_i};    // Default to RA+SP
  endcase
end

qarma64_enc_core qarma64_enc_core_inst (
    .clk_i(clk_i),
    .rst_ni(rst_ni),
    .block_i(message),
    .key_i(key_i),
    .tweak_i(tweak),
    .start_i(start_qarma),
    .ready_o(),
    .valid_o(qarma_valid),
    .result_o(qarma_result)
  );    

always_ff @(posedge clk_i or negedge rst_ni) begin
  if (!rst_ni) begin
    state_reg <= IDLE;
    pac_mismatch_q <= 1'b0;
  end
  else begin
    state_reg <= state_next;
    pac_mismatch_q <= pac_mismatch_d;
  end
end

always_comb begin
  state_next = state_reg;
  start_qarma = 1'b0;
  pac_mismatch_d = pac_mismatch_q;
  if(pac_mismatch_ack_i || ((state_reg == IDLE) && (calculate_i || verify_i))) begin
    pac_mismatch_d = 1'b0;
  end
  case (state_reg)
    IDLE: begin
      if (calculate_i) begin
        start_qarma = 1'b1;
        state_next = CALCULATE_PAC;
      end
      else if (verify_i) begin
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
          pac_mismatch_d = 1'b0;
        end else begin
          pac_mismatch_d = 1'b1;
        end
      end 
    end
  endcase
end
assign tweak = {s1_i, s0_i};
assign pac_lo_o = qarma_result[31:0];
assign pac_hi_o = qarma_result[63:32];
assign valid_o = qarma_valid;
assign pac_mismatch_o = pac_mismatch_q | pac_mismatch_d;

endmodule

