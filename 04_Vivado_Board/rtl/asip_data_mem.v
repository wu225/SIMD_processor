`timescale 1ns/1ps
// eDM is already WORD-addressed. Do not shift addr right by two again.
module asip_data_mem(input clock,input reset,input [31:0] addr,
 input ld,input [3:0] st,input [31:0] wr,output [31:0] rd,output fault);
 (* ram_style="block" *) reg [31:0] mem[0:1023];
 reg [31:0] q;
 reg active;
 reg [3:0] bypass;
 reg [31:0] bypass_data;
 wire valid=(addr<1024);
 integer i;
 initial $readmemh("dm.mem",mem);
 always @(posedge clock) begin
   active<=!reset && valid && ld;
   bypass<=st;
   bypass_data<=wr;
   if(!reset && valid && (ld || |st)) begin
     for(i=0;i<4;i=i+1) begin
       if(st[i]) mem[addr[9:0]][8*i+:8]<=wr[8*i+:8];
     end
     q<=mem[addr[9:0]];
   end
 end
 genvar b;
 generate for(b=0;b<4;b=b+1) begin
   assign rd[b*8+:8]=active ? (bypass[b] ? bypass_data[b*8+:8] : q[b*8+:8]) : 8'b0;
 end endgenerate
 assign fault=!reset && (ld || |st) && !valid;
endmodule
