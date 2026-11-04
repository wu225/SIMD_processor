`timescale 1ns/1ps
module asip_system(input clock,input reset,
 output reg [31:0] status,output reg [31:0] failure_id,
 output reg [31:0] result8,output reg [31:0] result16,output reg [31:0] result32,
 output reg access_fault,output [31:0] fetch_address);
 wire [31:0] pm_addr,pm_rd,pm_wr,dm_addr,dm_rd,dm_wr;
 wire pm_ld,pm_st,dm_ld,pm_fault,dm_fault;
 wire [3:0] dm_st;
 trv32p5
 // synopsys translate_off
 #(.reg_log(1'b0))
 // synopsys translate_on
 cpu(.clock(clock),.reset_ext(reset),
 .pm_addr_out(pm_addr),.pm_rd_in(pm_rd),.pm_wr_out(pm_wr),.pm_ld_out(pm_ld),.pm_st_out(pm_st),
 .edm_addr_out(dm_addr),.edm_rd_in(dm_rd),.edm_wr_out(dm_wr),.edm_ld_out(dm_ld),.edm_st_out(dm_st),
 .dbg_instr_in(16'b0),.dbg_data_pi_in(32'b0),.dbg_data_we_in(1'b0),
 .dbg_instr_exec_in(1'b0),.dbg_ext_break_in(1'b0),.dbg_data_po_out(),.dbg_set_break_out());
 asip_program_mem pm(clock,reset,pm_addr,pm_ld,pm_st,pm_wr,pm_rd,pm_fault);
 asip_data_mem dm(clock,reset,dm_addr,dm_ld,dm_st,dm_wr,dm_rd,dm_fault);
 assign fetch_address=pm_addr;
 always @(posedge clock or posedge reset) begin
   if(reset) begin
     status<=0;failure_id<=0;result8<=0;result16<=0;result32<=0;access_fault<=0;
   end else begin
     if(pm_fault || dm_fault) access_fault<=1;
     if(dm_st==4'hf) begin
       case(dm_addr)
         32'hfc: status<=dm_wr;
         32'hfd: failure_id<=dm_wr;
         32'h43: result8<=dm_wr;
         32'h4b: result16<=dm_wr;
         32'h53: result32<=dm_wr;
       endcase
     end
   end
 end
endmodule
