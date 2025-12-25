// Copyright lowRISC contributors.
// Copyright 2018 ETH Zurich and University of Bologna, see also CREDITS.md.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

/**
 * RISC-V register file
 *
 * Register file with 31 or 15x 32 bit wide registers. Register 0 is fixed to 0.
 *
 * This register file is designed to make FPGA synthesis tools infer RAM primitives. For Xilinx
 * FPGA architectures, it will produce RAM32M primitives. Other vendors have not yet been tested.
 */
module ibex_register_file_fpga #(
    parameter bit                   RV32E             = 0,
    parameter int unsigned          DataWidth         = 32,
    parameter bit                   DummyInstructions = 0,
    parameter bit                   WrenCheck         = 0,
    parameter bit                   RdataMuxCheck     = 0,
    parameter logic [DataWidth-1:0] WordZeroVal       = '0
) (
  // Clock and Reset
  input  logic                 clk_i,
  input  logic                 rst_ni,

  input  logic                 test_en_i,
  input  logic                 dummy_instr_id_i,
  input  logic                 dummy_instr_wb_i,

  //Read port R1
  input  logic [          4:0] raddr_a_i,
  output logic [DataWidth-1:0] rdata_a_o,
  //Read port R2
  input  logic [          4:0] raddr_b_i,
  output logic [DataWidth-1:0] rdata_b_o,
  // Write port W1
  input  logic [          4:0] waddr_a_i,
  input  logic [DataWidth-1:0] wdata_a_i,
  input  logic                 we_a_i,

  // This indicates whether spurious WE or non-one-hot encoded raddr are detected.
  output logic                 err_o,

  // Outputs for Mithril PAC
  output logic [DataWidth-1:0] ra_o, 
  output logic [DataWidth-1:0] sp_o, 
  output logic [DataWidth-1:0] s0_o, 
  output logic [DataWidth-1:0] s1_o
);

  localparam int ADDR_WIDTH = RV32E ? 4 : 5;
  localparam int NUM_WORDS = 2 ** ADDR_WIDTH;

  logic [DataWidth-1:0] mem[NUM_WORDS];
  logic we; // write enable if writing to any register other than R0

  logic [DataWidth-1:0] mem_o_a, mem_o_b;

  // Shadow registers for Mithril PAC (to preserve BRAM inference)
  logic [DataWidth-1:0] ra_shadow_q;  // x1 (ra)
  logic [DataWidth-1:0] sp_shadow_q;  // x2 (sp)
  logic [DataWidth-1:0] s0_shadow_q;  // x8 (s0/fp)
  logic [DataWidth-1:0] s1_shadow_q;  // x9 (s1)

  // WE strobe and one-hot encoded raddr alert.
  logic oh_raddr_a_err, oh_raddr_b_err, oh_we_err;
  assign err_o = oh_raddr_a_err || oh_raddr_b_err || oh_we_err;

  if (RdataMuxCheck) begin : gen_rdata_mux_check
    // Encode raddr_a/b into one-hot encoded signals.
    logic [NUM_WORDS-1:0] raddr_onehot_a, raddr_onehot_b;
    logic [NUM_WORDS-1:0] raddr_onehot_a_buf, raddr_onehot_b_buf;
    prim_onehot_enc #(
      .OneHotWidth(NUM_WORDS)
    ) u_prim_onehot_enc_raddr_a (
      .in_i  (raddr_a_i),
      .en_i  (1'b1),
      .out_o (raddr_onehot_a)
    );

    prim_onehot_enc #(
      .OneHotWidth(NUM_WORDS)
    ) u_prim_onehot_enc_raddr_b (
      .in_i  (raddr_b_i),
      .en_i  (1'b1),
      .out_o (raddr_onehot_b)
    );

    // Buffer the one-hot encoded signals so that the checkers
    // are not optimized.
    prim_buf #(
      .Width(NUM_WORDS)
    ) u_prim_buf_raddr_a (
      .in_i (raddr_onehot_a),
      .out_o(raddr_onehot_a_buf)
    );

    prim_buf #(
      .Width(NUM_WORDS)
    ) u_prim_buf_raddr_b (
      .in_i (raddr_onehot_b),
      .out_o(raddr_onehot_b_buf)
    );

    // SEC_CM: DATA_REG_SW.GLITCH_DETECT
    // Check the one-hot encoded signals for glitches.
    prim_onehot_check #(
      .AddrWidth(ADDR_WIDTH),
      .OneHotWidth(NUM_WORDS),
      .AddrCheck(1),
      // When AddrCheck=1 also EnableCheck needs to be 1.
      .EnableCheck(1)
    ) u_prim_onehot_check_raddr_a (
      .clk_i,
      .rst_ni,
      .oh_i   (raddr_onehot_a_buf),
      .addr_i (raddr_a_i),
      // Set enable=1 as address is always valid.
      .en_i   (1'b1),
      .err_o  (oh_raddr_a_err)
    );

    prim_onehot_check #(
      .AddrWidth(ADDR_WIDTH),
      .OneHotWidth(NUM_WORDS),
      .AddrCheck(1),
      // When AddrCheck=1 also EnableCheck needs to be 1.
      .EnableCheck(1)
    ) u_prim_onehot_check_raddr_b (
      .clk_i,
      .rst_ni,
      .oh_i   (raddr_onehot_b_buf),
      .addr_i (raddr_b_i),
      // Set enable=1 as address is always valid.
      .en_i   (1'b1),
      .err_o  (oh_raddr_b_err)
    );

    // MUX register to rdata_a/b_o according to raddr_a/b_onehot.
    prim_onehot_mux  #(
      .Width(DataWidth),
      .Inputs(NUM_WORDS)
    ) u_rdata_a_mux (
      .clk_i,
      .rst_ni,
      .in_i  (mem),
      .sel_i (raddr_onehot_a),
      .out_o (mem_o_a)
    );

    prim_onehot_mux  #(
      .Width(DataWidth),
      .Inputs(NUM_WORDS)
    ) u_rdata_b_mux (
      .clk_i,
      .rst_ni,
      .in_i  (mem),
      .sel_i (raddr_onehot_b),
      .out_o (mem_o_b)
    );

    assign rdata_a_o = (raddr_a_i == '0) ? '0 : mem_o_a;
    assign rdata_b_o = (raddr_b_i == '0) ? '0 : mem_o_b;
  end else begin : gen_no_rdata_mux_check
    // async_read a
    assign rdata_a_o = (raddr_a_i == '0) ? '0 : mem[raddr_a_i];

    // async_read b
    assign rdata_b_o = (raddr_b_i == '0) ? '0 : mem[raddr_b_i];
  end

  // we select
  assign we = (waddr_a_i == '0) ? 1'b0 : we_a_i;

  // SEC_CM: DATA_REG_SW.GLITCH_DETECT
  // This checks for spurious WE strobes on the regfile.
  if (WrenCheck) begin : gen_wren_check
    // Since the FPGA uses a memory macro, there is only one write-enable strobe to check.
    assign oh_we_err = we && !we_a_i;
  end else begin : gen_no_wren_check
    assign oh_we_err = 1'b0;
  end

  // Note that the SystemVerilog LRM requires variables on the LHS of assignments within
  // "always_ff" to not be written to by any other process. However, to enable the initialization
  // of the inferred RAM32M primitives with non-zero values, below "initial" procedure is needed.
  // Therefore, we use "always" instead of the generally preferred "always_ff" for the synchronous
  // write procedure.
  always @(posedge clk_i) begin : sync_write
    if (we == 1'b1) begin
      mem[waddr_a_i] <= wdata_a_i;
    end
  end : sync_write

  // Shadow registers for PAC - updated on write to preserve BRAM inference
  always_ff @(posedge clk_i or negedge rst_ni) begin : pac_shadow_regs
    if (!rst_ni) begin
      ra_shadow_q <= WordZeroVal;
      sp_shadow_q <= WordZeroVal;
      s0_shadow_q <= WordZeroVal;
      s1_shadow_q <= WordZeroVal;
    end else if (we_a_i) begin
      // Update shadow register when corresponding register is written
      case (waddr_a_i)
        5'd1:  ra_shadow_q <= wdata_a_i;  // x1 (ra)
        5'd2:  sp_shadow_q <= wdata_a_i;  // x2 (sp)
        5'd8:  s0_shadow_q <= wdata_a_i;  // x8 (s0/fp)
        5'd9:  s1_shadow_q <= wdata_a_i;  // x9 (s1)
        default: ; // No update for other registers
      endcase
    end
  end : pac_shadow_regs

  // Make sure we initialize the BRAM with the correct register reset value.
  initial begin
    for (int k = 0; k < NUM_WORDS; k++) begin
      mem[k] = WordZeroVal;
    end
  end

  // Dummy instruction changes not relevant for FPGA implementation
  logic unused_dummy_instr;
  assign unused_dummy_instr = dummy_instr_id_i ^ dummy_instr_wb_i;
  // Test enable signal not used in FPGA implementation
  logic unused_test_en;
  assign unused_test_en = test_en_i;

  // Assign outputs for Mithril PAC (from shadow registers to preserve BRAM)
  assign ra_o = ra_shadow_q;  // x1 (ra)
  assign sp_o = sp_shadow_q;  // x2 (sp)
  assign s0_o = s0_shadow_q;  // x8 (s0/fp)
  assign s1_o = s1_shadow_q;  // x9 (s1)

endmodule
