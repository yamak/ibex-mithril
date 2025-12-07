
module mithril_pac_regs #(
  parameter int unsigned NumRegs = 2
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  logic [$clog2(NumRegs)-1:0] addr_i,
  input  logic [31:0] wdata_i,
  input  logic we_i,
  input  logic wr_hi_i,
  output logic [63:0] pac_o,
);
  
  // Each pac register is 64 bits. Split into two 32-bit registers.
  logic [31:0] pac_regs[2*NumRegs];

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      for(int i = 0; i < NumRegs; i++) begin
        pac_regs[i] <= 32'b0;
      end
    end else if (we_i) begin
      int index = addr_i * 2 + (wr_hi_i ? 1 : 0);
      pac_regs[index] <= wdata_i;
    end
  end

  assign pac_o = {pac_regs[addr_i * 2 + 1], pac_regs[addr_i * 2]};
endmodule

