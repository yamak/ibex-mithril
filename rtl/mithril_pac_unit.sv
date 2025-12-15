/*
 * Copyright (c) 2025 Yusuf Yamak <yamakyusuf@gmail.com>
 *
 * SPDX-License-Identifier: Apache-2.0
 */

module mithril_pac_unit #(
  parameter int NumRegs = 2
)(
  input logic clk_i,
  input logic rst_ni,
  input logic [127:0] key_i,
  
  input logic [31:0] s0_i,
  input logic [31:0] s1_i,
  
  // Message source selection
  input logic [63:0] message_i,
  
  // Control signals
  input logic calculate_i,
  input logic verify_i,
  
  output logic valid_o,
  output logic pac_mismatch_o,
  input logic pac_mismatch_ack_i,

  /* verilator lint_off UNUSED */
  input  logic [4:0] current_result_reg_i,
  input  logic [4:0] raddr_i,
  input  logic [4:0] waddr_i,
  /* verilator lint_on UNUSED */

  output logic [31:0] rdata_o,

  input  logic [31:0] wdata_i,
  input  logic we_i
);

localparam int PacRegAddrWidth = $clog2(NumRegs * 2);

logic [63:0] tweak;
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
logic [PacRegAddrWidth-1:0] current_result_reg_q;


  // Each pac register is 64 bits. Split into two 32-bit registers.
  logic [31:0] pac_regs[2 * NumRegs];

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      for(int i = 0; i < NumRegs * 2; i++) begin
        pac_regs[i] <= 32'b0;
      end
    end else if (we_i) begin
      pac_regs[waddr_i[PacRegAddrWidth-1:0]] <= wdata_i;
    end else if (qarma_valid) begin
      pac_regs[current_result_reg_q] <= qarma_result[31:0];
      pac_regs[current_result_reg_q + 1] <= qarma_result[63:32];
    end
  end

  assign rdata_o = pac_regs[raddr_i[PacRegAddrWidth-1:0]];

qarma64_enc_core qarma64_enc_core_inst (
    .clk_i(clk_i),
    .rst_ni(rst_ni),
    .block_i(message_i),
    .key_i(key_i),
    .tweak_i(tweak),
    .start_i(start_qarma),
    .valid_o(qarma_valid),
    .result_o(qarma_result)
  );    

always_ff @(posedge clk_i or negedge rst_ni) begin
  if (!rst_ni) begin
    state_reg <= IDLE;
    pac_mismatch_q <= 1'b0;
    current_result_reg_q <= '0; 
  end
  else begin
    state_reg <= state_next;
    pac_mismatch_q <= pac_mismatch_d;
    if(calculate_i || verify_i) begin
      // Truncate to PacRegAddrWidth and clear bit 0 to get base index of 64-bit PAC register
      current_result_reg_q <= {current_result_reg_i[PacRegAddrWidth-1:1], 1'b0};
    end
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
        if (qarma_result == {pac_regs[current_result_reg_q + 1], pac_regs[current_result_reg_q]}) begin
          pac_mismatch_d = 1'b0;
        end else begin
          pac_mismatch_d = 1'b1;
        end
      end 
    end
  endcase
end
assign tweak = {s1_i, s0_i};
assign valid_o = qarma_valid;
assign pac_mismatch_o = pac_mismatch_q | pac_mismatch_d;

endmodule

