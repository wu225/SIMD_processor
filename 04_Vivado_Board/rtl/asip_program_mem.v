`timescale 1ns/1ps
// 4 KiB byte-addressed, little endian, synchronous read / write-first.
// Four byte banks also support an unaligned four-byte access as in tb_mem_PMb.
module asip_program_mem(input clock,input reset,input [31:0] addr,
 input ld,input st,input [31:0] wr,output [31:0] rd,output fault);
 wire valid=(addr<=4092);
 reg active;
 reg [1:0] offset;
 wire [31:0] banks;
 genvar b;
 generate for(b=0;b<4;b=b+1) begin: bank
   (* ram_style="block" *) reg [7:0] mem[0:1023];
   reg [7:0] q;
   reg [7:0] bypass_data;
   reg bypass;
   wire [9:0] index=addr[11:2]+(addr[1:0]>b);
   wire [1:0] lane=b-addr[1:0];
   wire [7:0] din=wr >> (8*lane);
   initial begin
     if(b==0) $readmemh("pm0.mem",mem);
     if(b==1) $readmemh("pm1.mem",mem);
     if(b==2) $readmemh("pm2.mem",mem);
     if(b==3) $readmemh("pm3.mem",mem);
   end
   always @(posedge clock) if(!reset && valid && (ld || st)) begin
     if(st) mem[index]<=din;
     q<=mem[index];
   end
   always @(posedge clock) begin
     bypass<=st;
     bypass_data<=din;
   end
   assign banks[8*b+:8]=bypass ? bypass_data : q;
 end endgenerate
 always @(posedge clock) begin
   active<=!reset && valid && ld;
   offset<=addr[1:0];
 end
 wire [63:0] repeated={banks,banks};
 assign rd=active ? (repeated >> (offset*8)) : 32'b0;
 assign fault=!reset && (ld || st) && !valid;
endmodule
