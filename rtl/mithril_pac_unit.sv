/*
 * Copyright (c) 2025 Yusuf Yamak <yamakyusuf@gmail.com>

/**
 * Fully Pipelined PAC Unit
 *
 * This unit handles PAC (Pointer Authentication Code) operations using QARMA-64.
 * It is fully pipelined - can accept a new calculate/verify request every cycle
 * without blocking. No state machine needed.
 *
 * Pipeline timing (QARMA is 2-cycle):
 *   Cycle N:   calculate_i/verify_i asserted, QARMA starts
 *   Cycle N+1: QARMA valid, result written to pac_regs or compared for verify
 */
module mithril_pac_unit #(
  parameter int NumRegs = 2
)(
  input logic clk_i,
  input logic rst_ni,
  input logic [127:0] key_i,
  input logic [63:0] tweak_i,
  input logic [63:0] message_i,
  
  // Control signals - can be asserted every cycle (pipelined)
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

logic [63:0] qarma_result;
logic qarma_valid;
logic start_qarma;

// Pipeline registers - track operation type and target register
logic is_verify_q;  // Was the operation that's completing now a verify?
logic [PacRegAddrWidth-1:0] target_reg_q;  // Which register to write/verify

logic pac_mismatch_q, pac_mismatch_d;

// Each pac register is 64 bits. Split into two 32-bit registers.
logic [31:0] pac_regs[2 * NumRegs];

// PAC register file write logic
always_ff @(posedge clk_i or negedge rst_ni) begin
  if (!rst_ni) begin
    for(int i = 0; i < NumRegs * 2; i++) begin
      pac_regs[i] <= 32'b0;
    end
  end else if (we_i) begin
    // External write (from pac.load instruction)
    pac_regs[waddr_i[PacRegAddrWidth-1:0]] <= wdata_i;
  end else if (qarma_valid) begin
    // QARMA finished a calculate operation - write result
    if(!is_verify_q) begin
      pac_regs[target_reg_q] <= qarma_result[31:0];
      pac_regs[target_reg_q + 1] <= qarma_result[63:32];
    end
  end
end

assign rdata_o = pac_regs[raddr_i[PacRegAddrWidth-1:0]];

// QARMA instance - fully pipelined, 2-cycle latency
qarma64_enc_core qarma64_enc_core_inst (
    .clk_i(clk_i),
    .rst_ni(rst_ni),
    .block_i(message_i),
    .key_i(key_i),
    .tweak_i(tweak_i),
    .start_i(start_qarma),
    .valid_o(qarma_valid),
    .result_o(qarma_result)
);

// Pipeline registers for operation tracking
always_ff @(posedge clk_i or negedge rst_ni) begin
  if (!rst_ni) begin
    is_verify_q <= 1'b0;
    target_reg_q <= '0;
    pac_mismatch_q <= 1'b0;
  end else begin
    // Capture operation type and target register when starting
    if(verify_i) begin
      is_verify_q <= 1'b1;
      target_reg_q <= {current_result_reg_i[PacRegAddrWidth-1:1], 1'b0};
    end else if (calculate_i) begin
      is_verify_q <= 1'b0;
      target_reg_q <= {current_result_reg_i[PacRegAddrWidth-1:1], 1'b0};
    end else if (qarma_valid) begin
      is_verify_q <= 1'b0;
    end 
    
    
    // Mismatch flag handling
    pac_mismatch_q <= pac_mismatch_d;
  end
end

// Combinational logic for starting QARMA and mismatch detection
always_comb begin
  // Always accept new operations - fully pipelined!
  start_qarma = calculate_i | verify_i;
  
  // Mismatch logic
  pac_mismatch_d = pac_mismatch_q;
  
  // Clear mismatch only on ack
  if (pac_mismatch_ack_i) begin
    pac_mismatch_d = 1'b0;
  end
  
  // Set mismatch if verify operation completed and PAC doesn't match
  if (qarma_valid && is_verify_q) begin
    if (qarma_result != {pac_regs[target_reg_q + 1], pac_regs[target_reg_q]}) begin
      pac_mismatch_d = 1'b1;
    end
  end
end

assign valid_o = qarma_valid;
assign pac_mismatch_o = pac_mismatch_q | pac_mismatch_d;

endmodule
