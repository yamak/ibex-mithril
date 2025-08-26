
module mithril_pac_regs (
  input  logic clk_i,
  input  logic rst_ni,
  input  logic waddr_i,
  input  logic [31:0] sp_i,
  input  logic [31:0] wdata_i,
  input  logic we_i,
  input  logic trap_ctx_i,
  output logic [63:0] pac_o,
  output logic [31:0] latched_sp_o
);
  
  logic [31:0] pac_regs[2]; // 0: lo, 1: hi
  logic [31:0] shadow_pac_regs[2]; // 0: lo, 1: hi
  logic [31:0] latched_sp;
  logic [31:0] shadow_latched_sp;
  logic trap_ctx_q;
  logic [1:0] received_mask;
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      pac_regs[0] <= 32'b0;
      pac_regs[1] <= 32'b0;
      shadow_pac_regs[0] <= 32'b0;
      shadow_pac_regs[1] <= 32'b0;
      latched_sp <= 32'b0;
      shadow_latched_sp <= 32'b0;
      trap_ctx_q <= 1'b0;
      received_mask <= 2'b11;
    end else if (we_i) begin
      if(received_mask[0] & received_mask[1]) begin // start of frame
        if(trap_ctx_i) begin
          shadow_latched_sp <= sp_i;
        end else begin
          latched_sp <= sp_i;
        end
        trap_ctx_q <= trap_ctx_i;
        received_mask <= 2'b00;
      end
      if(trap_ctx_q) begin
        shadow_pac_regs[waddr_i] <= wdata_i;
      end else begin
        pac_regs[waddr_i] <= wdata_i;
      end
      received_mask[waddr_i] <= 1'b1;
    end
  end

  assign pac_o = trap_ctx_q ? {shadow_pac_regs[1], shadow_pac_regs[0]} : {pac_regs[1], pac_regs[0]};
  assign latched_sp_o = trap_ctx_q ? shadow_latched_sp : latched_sp;
endmodule

