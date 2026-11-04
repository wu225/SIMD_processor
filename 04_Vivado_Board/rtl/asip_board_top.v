`timescale 1ns/1ps
// Board wrapper. SYSCLK200 pin locations are documented; IO electrical standard
// remains to be confirmed from the vendor. Do not generate/program a bitstream yet.
module asip_board_top(input sysclk200_p,input sysclk200_n);
 wire clk200,fb_raw,fb,clk_raw,clock,locked;
 IBUFDS input_clock(.I(sysclk200_p),.IB(sysclk200_n),.O(clk200));
 MMCME4_BASE #(.CLKIN1_PERIOD(5.0),.DIVCLK_DIVIDE(1),
   .CLKFBOUT_MULT_F(5.0),.CLKOUT0_DIVIDE_F(10.0))
 mmcm(.CLKIN1(clk200),.CLKFBIN(fb),.RST(1'b0),.PWRDWN(1'b0),
   .CLKFBOUT(fb_raw),.CLKOUT0(clk_raw),.LOCKED(locked));
 BUFG feedback_buffer(.I(fb_raw),.O(fb));
 BUFG cpu_clock_buffer(.I(clk_raw),.O(clock));
 wire reset_request;
 (* ASYNC_REG="TRUE" *) reg [3:0] reset_sync=4'hf;
 wire async_reset=~locked | reset_request;
 always @(posedge clock or posedge async_reset)
   if(async_reset) reset_sync<=4'hf;
   else reset_sync<={reset_sync[2:0],1'b0};
 wire reset=reset_sync[3];
 wire [31:0] status,failure_id,r8,r16,r32,pc;
 wire fault;
 asip_system system(clock,reset,status,failure_id,r8,r16,r32,fault,pc);
 // VIO starts with reset asserted: arm ILA, then set probe_out0 to zero.
 demo_vio control(.clk(clock),.probe_out0(reset_request),.probe_in0(status));
 demo_ila capture(.clk(clock),.probe0(status),.probe1(failure_id),
   .probe2(r8),.probe3(r16),.probe4(r32),.probe5(pc),.probe6(fault),.probe7(reset));
endmodule
