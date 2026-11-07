//============================================================================
//
//  WebTV Plus (LC2) core for MiSTer
//
//  This program is free software; you can redistribute it and/or modify it
//  under the terms of the GNU General Public License as published by the Free
//  Software Foundation; either version 2 of the License, or (at your option)
//  any later version.
//
//  This program is distributed in the hope that it will be useful, but WITHOUT
//  ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
//  FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License for
//  more details.
//
//  You should have received a copy of the GNU General Public License along
//  with this program; if not, write to the Free Software Foundation, Inc.,
//  51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.
//
//============================================================================

module emu
(
	`include "sys/emu_ports.vh"
);

///////// Default values for ports not used in this core /////////

assign ADC_BUS  = 'Z;
assign USER_OUT = '1;
assign {SD_SCK, SD_MOSI, SD_CS} = 'Z;
assign {SDRAM_DQ, SDRAM_A, SDRAM_BA, SDRAM_CLK, SDRAM_CKE, SDRAM_DQML, SDRAM_DQMH, SDRAM_nWE, SDRAM_nCAS, SDRAM_nRAS, SDRAM_nCS} = 'Z;

assign VGA_SL = 0;
assign VGA_F1 = 0;
assign VGA_SCALER  = 0;
assign VGA_DISABLE = 0;
assign HDMI_FREEZE = 0;
assign HDMI_BLACKOUT = 0;
assign HDMI_BOB_DEINT = 0;

assign AUDIO_S = 1;
assign AUDIO_L = 0;
assign AUDIO_R = 0;
assign AUDIO_MIX = 0;

assign LED_POWER = 0;
assign BUTTONS   = 0;

//////////////////////////////////////////////////////////////////

wire [1:0] ar = status[122:121];

assign VIDEO_ARX = (!ar) ? 12'd4 : (ar - 1'd1);
assign VIDEO_ARY = (!ar) ? 12'd3 : 12'd0;

`include "build_id.v"
localparam CONF_STR = {
	"WebTV;UART115200;",
	"-;",
	"F0,ROMBIN,Load Boot ROM;",
	"S0,IMGBINVHD,Mount Disk;",
	"-;",
	"O[122:121],Aspect ratio,Original,Full Screen,[ARC1],[ARC2];",
	"O[1],Answer Disk Boot prompt,Yes,No;",
	"O[2],Serial port,Modem,Debug console;",
	"O[3],Debug overlay,Off,On;",
	"O[4],Data cache,On,Off;",
	"O[5],Instruction cache,On,Off;",
	"-;",
	"J1,Select,Back,Home,Options,Scroll Up,Scroll Down,Power;",
	"-;",
	"R[0],Reset;",
	"v,0;",
	"V,v",`BUILD_DATE
};

wire   [1:0] buttons;
wire [127:0] status;
wire  [10:0] ps2_key;
wire  [31:0] joystick_0;

wire        ioctl_download;
wire [15:0] ioctl_index;
wire        ioctl_wr;
wire [26:0] ioctl_addr;
wire [15:0] ioctl_dout;
wire        ioctl_wait;

wire        img_mounted;
wire        img_readonly;
wire [63:0] img_size;
wire [31:0] sd_lba;
wire  [5:0] sd_blk_cnt;
wire        sd_rd;
wire        sd_wr;
wire        sd_ack;
wire [12:0] sd_buff_addr;
wire [15:0] sd_buff_dout;
wire [15:0] sd_buff_din;
wire        sd_buff_wr;

hps_io #(.CONF_STR(CONF_STR), .WIDE(1), .VDNUM(1), .BLKSZ(2)) hps_io
(
	.clk_sys(clk_1x),
	.HPS_BUS(HPS_BUS),
	.EXT_BUS(),
	.gamma_bus(),

	.buttons(buttons),
	.status(status),
	.status_menumask(16'd0),
	.ps2_key(ps2_key),
	.joystick_0(joystick_0),

	.ioctl_download(ioctl_download),
	.ioctl_index(ioctl_index),
	.ioctl_wr(ioctl_wr),
	.ioctl_addr(ioctl_addr),
	.ioctl_dout(ioctl_dout),
	.ioctl_wait(ioctl_wait),

	.img_mounted(img_mounted),
	.img_readonly(img_readonly),
	.img_size(img_size),
	.sd_lba('{sd_lba}),
	.sd_blk_cnt('{sd_blk_cnt}),
	.sd_rd(sd_rd),
	.sd_wr(sd_wr),
	.sd_ack(sd_ack),
	.sd_buff_addr(sd_buff_addr),
	.sd_buff_dout(sd_buff_dout),
	.sd_buff_din('{sd_buff_din}),
	.sd_buff_wr(sd_buff_wr)
);

///////////////////////   CLOCKS   ///////////////////////////////

wire clk_1x;   //  62.5  MHz: memory system, SOLO, video
wire clk_93;   //  93.75 MHz: CPU
wire clk_2x;   // 125    MHz: DDR3
wire pll_locked;

pll pll
(
	.refclk(CLK_50M),
	.rst(0),
	.outclk_0(clk_1x),
	.outclk_1(clk_93),
	.outclk_2(clk_2x),
	.outclk_3(),
	.locked(pll_locked)
);

reg [1:0] reset_s = 2'b11;
always @(posedge clk_1x) reset_s <= {reset_s[0], RESET | status[0] | buttons[1]};

/////////////////////////  CORE  /////////////////////////////////

wire        running;
wire        rom_loaded;
wire        fb_en;
wire [31:0] fb_base;
wire        vid_ce, vid_hblank, vid_vblank, vid_hsync, vid_vsync;

assign DDRAM_CLK = clk_2x;

// WEBTV_SLOW (qsf VERILOG_MACRO): the PLL runs 50 / 75 / 100 MHz instead of 62.5 / 93.75 / 125 (bring-up)
`ifdef WEBTV_SLOW
localparam CLK1X_HZ = 50000000;
localparam CLK93_HZ = 75000000;
`else
localparam CLK1X_HZ = 62500000;
localparam CLK93_HZ = 93750000;
`endif

wire [7:0] ov_r, ov_g, ov_b;

webtv_mister #(.CLK1X_HZ(CLK1X_HZ), .CLK93_HZ(CLK93_HZ)) webtv
(
	.clk1x          (clk_1x),
	.clk93          (clk_93),
	.clk2x          (clk_2x),
	.pll_locked     (pll_locked),
	.reset          (reset_s[1]),

	.autoboot_y     (~status[1]),

	.ioctl_download (ioctl_download),
	.ioctl_index    (ioctl_index[7:0]),
	.ioctl_wr       (ioctl_wr),
	.ioctl_addr     (ioctl_addr),
	.ioctl_dout     (ioctl_dout),
	.ioctl_wait     (ioctl_wait),

	.img_mounted    (img_mounted),
	.img_size       (img_size),
	.sd_lba         (sd_lba),
	.sd_blk_cnt     (sd_blk_cnt),
	.sd_rd          (sd_rd),
	.sd_wr          (sd_wr),
	.sd_ack         (sd_ack),
	.sd_buff_addr   (sd_buff_addr),
	.sd_buff_dout   (sd_buff_dout),
	.sd_buff_din    (sd_buff_din),
	.sd_buff_wr     (sd_buff_wr),

	.ps2_key        (ps2_key),
	.joy            (joystick_0[15:0]),

	.uart_modem     (~status[2]),
	.uart_rxd       (UART_RXD),
	.uart_txd       (UART_TXD),
	.uart_dsr       (UART_DSR),
	.uart_rts       (UART_RTS),
	.uart_dtr       (UART_DTR),

	.running        (running),
	.rom_loaded     (rom_loaded),
	.led            (),
	.errors         (),

	.fb_en          (fb_en),
	.fb_base        (fb_base),
	.vid_ce         (vid_ce),
	.vid_hblank     (vid_hblank),
	.vid_vblank     (vid_vblank),
	.vid_hsync      (vid_hsync),
	.vid_vsync      (vid_vsync),
	.debug_overlay  (status[3]),
	.dcache_off     (status[4]),
	.icache_off     (status[5]),
	.vga_r          (ov_r),
	.vga_g          (ov_g),
	.vga_b          (ov_b),

	.ddr3_BUSY      (DDRAM_BUSY),
	.ddr3_DOUT      (DDRAM_DOUT),
	.ddr3_DOUT_READY(DDRAM_DOUT_READY),
	.ddr3_BURSTCNT  (DDRAM_BURSTCNT),
	.ddr3_ADDR      (DDRAM_ADDR),
	.ddr3_DIN       (DDRAM_DIN),
	.ddr3_BE        (DDRAM_BE),
	.ddr3_WE        (DDRAM_WE),
	.ddr3_RD        (DDRAM_RD)
);

/////////////////////////  VIDEO  ////////////////////////////////
// The picture comes from the framebuffer (640x480, 32 bit R,G,B,x) through the scaler.
// The core's own video output carries only the timing (black) until a scanout path exists.

assign FB_EN      = fb_en & ~status[3];
assign FB_FORMAT  = 5'b00110;
assign FB_WIDTH   = 12'd640;
assign FB_HEIGHT  = 12'd480;
assign FB_BASE    = fb_base;
assign FB_STRIDE  = 14'd2560;
assign FB_FORCE_BLANK = 0;

assign CLK_VIDEO = clk_1x;
assign CE_PIXEL  = vid_ce;
assign VGA_DE    = ~(vid_hblank | vid_vblank);
assign VGA_HS    = vid_hsync;
assign VGA_VS    = vid_vsync;
assign VGA_R     = ov_r;
assign VGA_G     = ov_g;
assign VGA_B     = ov_b;

assign LED_USER  = ~rom_loaded | ~running;
assign LED_DISK  = {1'b0, sd_ack};

endmodule
