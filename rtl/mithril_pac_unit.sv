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
  input  logic we_i,
  
  // SPF (Stochastic Pipeline Flooding) interface
  output logic busy_o,
  input logic spf_enable_i,
  input logic [3:0] spf_trng_period_i,
  // TRNG interface (external to this module)
  output logic trng_enable_o,
  input logic [7:0] trng_data_i,
  input logic trng_valid_i
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

// ============================================================================
// SPF (Stochastic Pipeline Flooding) - TRNG and PRNG management
// ============================================================================

logic [127:0] prng_random;
logic [15:0] trng_period_cnt;
logic trng_seed_trigger;

// TRNG seeding period counter
// Period = 2048 * (spf_trng_period_i + 1) cycles
// Range: 2048 to 32768 cycles (for spf_trng_period_i = 0 to 15)
// This provides a good balance between entropy refresh and power consumption
always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
        trng_period_cnt <= 16'd0;
    end else if (spf_enable_i) begin
        // Calculate period: 2048 * (N + 1)
        // 2048 = 2^11, multiply by (spf_trng_period_i + 1)
        if (trng_period_cnt == (16'd2048 * ({12'd0, spf_trng_period_i} + 16'd1) - 16'd1)) begin
            trng_period_cnt <= 16'd0;
        end else begin
            trng_period_cnt <= trng_period_cnt + 16'd1;
        end
    end else begin
        trng_period_cnt <= 16'd0;
    end
end

assign trng_seed_trigger = (trng_period_cnt == 16'd0) && spf_enable_i;
assign trng_enable_o = trng_seed_trigger;  // Output to enable TRNG

// Xorshift128 PRNG instance for SPF
xorshift128_prng u_xorshift_prng (
    .clk_i          (clk_i),
    .rst_ni         (rst_ni),
    .enable_i       (spf_enable_i),
    .seed_enable_i  (trng_seed_trigger),
    .seed_data_i    (trng_data_i),
    .seed_valid_i   (trng_valid_i),
    .random_o       (prng_random)
);

// ============================================================================
// QARMA instance - fully pipelined, 2-cycle latency with SPF support
// ============================================================================
qarma64_enc_core qarma64_enc_core_inst (
    .clk_i(clk_i),
    .rst_ni(rst_ni),
    .block_i(message_i),
    .key_i(key_i),
    .tweak_i(tweak_i),
    .start_i(start_qarma),
    .valid_o(qarma_valid),
    .result_o(qarma_result),
    .busy_o(busy_o),
    .spf_enable_i(spf_enable_i),
    .random_data_i(prng_random)
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
