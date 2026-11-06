-----------------------------------------------------------------
-- WebTV SOLO1 frame renderer: draws one 640x480 frame into an RGB framebuffer in DDR3
--
-- Same algorithm and arithmetic as the webtv-bridge JS model (src/machine/solo_cels.js,
-- solo_video.js render(); ported there from the wtvemac MAME driver), so frames can be compared
-- pixel for pixel:
--   vid mode (POT_CNTL.UseGfx = 0): blank colour, then the 4:2:2 framebuffer at vid nstart
--   gfx mode: blank colour, black window, then the gfxUnit cels: ymap bands -> cel lists,
--             texture types 1/4/5 (4:2:2), 3 (4:4:4), 2 (VQ8), 7 (VQ4), data-load cels (6),
--             alpha types 0..3 with the cel's global alpha.
-- JS uses floats, but every quantity is a multiple of 1/256 (u, v and steps: 8.8) or 1/1024
-- (x edges: 10.10), so the integer arithmetic here is exact.
--
-- Order: a first pass walks the ymap and cel lists (as drawCels does, including the loads that
-- move the ymap/cel bases) and keeps every drawable cel (its 12 header words, carried over
-- between cels of a band like the JS data[] array, plus the band's line count/top) in a table.
-- Then each screen row is composed in a line buffer -- every cel that covers the row, in list
-- order -- and written out. Per pixel the result is the same as the JS cel-by-cel order.
--
-- Memory: box RAM is at RAM_BASE in the DDR3 window (8 MB, bytes in address order). Reads go
-- through a direct-mapped cache of 32 lines x 32 bytes (4-beat bursts, captured from ddr3_DOUT
-- on clk2x after the grant, as the CPU caches do), invalidated at the start of each frame.
-- Framebuffer: 640 x 480 x 32 bit at fb_base, pixel = R, G, B, 0 in address order; a finished
-- row is written out from one line buffer by a second client while the next row is composed in
-- the other.
--
-- Storage for synthesis: the cel table and the two line buffers are M10K block RAM (registered
-- read), the texel cache data is MLAB (written on clk2x, read asynchronously). Each line buffer
-- has two banks (even / odd pixels) so a pixel pair is one access, plus a 640-bit "written"
-- flag vector: an unwritten pixel reads as its row-start value (window black or blank colour),
-- so a new row needs no clearing pass.
-----------------------------------------------------------------
library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

library mem;

entity webtv_gfx_render is
   generic
   (
      RAM_BASE  : unsigned(27 downto 0) := x"0000000";
      MAX_CELS  : integer := 256
   );
   port
   (
      clk1x            : in  std_logic;
      clk2x            : in  std_logic;
      reset            : in  std_logic;

      start            : in  std_logic;                      -- end of a displayed frame
      busy             : out std_logic := '0';
      fb_base          : in  unsigned(27 downto 0);          -- where to draw this frame

      -- registers (raw values as the CPU wrote them)
      pot_vstart, pot_vsize, pot_hstart, pot_hsize, pot_cntl, pot_blnkcol : in std_logic_vector(31 downto 0);
      vid_nstart, vid_dmacntl : in std_logic_vector(31 downto 0);
      gfx_cntl, gfx_ymapbase_master, gfx_celsbase_master : in std_logic_vector(31 downto 0);
      gfx_hcounterinit, gfx_blanklines, gfx_activelines   : in std_logic_vector(31 downto 0);

      -- DDR3 client: texel / ymap / cel reads, 4-beat bursts streamed in on clk2x
      rdram_request    : out std_logic := '0';
      rdram_rnw        : out std_logic := '1';
      rdram_address    : out unsigned(27 downto 0) := (others => '0');
      rdram_burstcount : out unsigned(9 downto 0) := 10x"004";
      rdram_writeMask  : out std_logic_vector(7 downto 0) := x"FF";
      rdram_dataWrite  : out std_logic_vector(63 downto 0) := (others => '0');
      rdram_done       : in  std_logic;
      rdram_granted2x  : in  std_logic;
      ddr3_DOUT        : in  std_logic_vector(63 downto 0);
      ddr3_DOUT_READY  : in  std_logic;

      -- DDR3 client: framebuffer writes (one beat = 2 pixels), from the row being written out
      fbw_request      : out std_logic := '0';
      fbw_address      : out unsigned(27 downto 0) := (others => '0');
      fbw_dataWrite    : out std_logic_vector(63 downto 0) := (others => '0');
      fbw_done         : in  std_logic
   );
end entity;

architecture arch of webtv_gfx_render is

   constant SCREEN_W : integer := 640;
   constant SCREEN_H : integer := 480;

   subtype word is std_logic_vector(31 downto 0);
   type tWords is array(natural range <>) of word;

   ------------------------------------------------------------------ helpers
   function s10(v : std_logic_vector(9 downto 0)) return integer is
   begin
      return to_integer(signed(v));
   end function;

   function clampi(v, lo, hi : integer) return integer is
   begin
      if v < lo then return lo; elsif v > hi then return hi; end if;
      return v;
   end function;

   -- truncTowardInf(U / 256) & mask, sign extended from 8 bits (JS maskedTrunc)
   function maskedTrunc(u : signed(31 downto 0); m : std_logic_vector(7 downto 0)) return integer is
      variable t : signed(31 downto 0);
      variable b : std_logic_vector(7 downto 0);
   begin
      if u > 0 then t := shift_right(u + 255, 8); else t := shift_right(u, 8); end if;
      b := std_logic_vector(t(7 downto 0)) and m;
      return to_integer(signed(b));
   end function;

   -- truncTowardZero(X / 1024)
   function truncZ10(x : signed(31 downto 0)) return integer is
   begin
      if x >= 0 then return to_integer(shift_right(x, 10)); end if;
      return -to_integer(shift_right(-x, 10));
   end function;

   -- ((y - 16) * 256 + 128) / 219, truncated toward zero
   function yexpCalc(y : integer) return integer is
      variable n : integer;
   begin
      n := (y - 16) * 256 + 128;
      if n >= 0 then return n / 219; end if;
      return -((-n) / 219);
   end function;
   type tYexp is array(0 to 511) of integer range -32 to 600;
   function yexpInit return tYexp is
      variable t : tYexp;
   begin
      for i in 0 to 511 loop t(i) := yexpCalc(i); end loop;
      return t;
   end function;
   constant YEXP_TABLE : tYexp := yexpInit;
   -- (a table: no divider in the pixel path; y is 0..287)
   function yexp(y : integer) return integer is
   begin
      return YEXP_TABLE(y mod 512);
   end function;

   -- n / 255 truncated toward zero, |n| < 2^19: exact as ((|n| + 1) * 0x10101) >> 24 (shifts and adds)
   function div255(n : integer) return integer is
      variable a : unsigned(19 downto 0);
      variable p : unsigned(39 downto 0);
      variable q : integer;
   begin
      if n >= 0 then a := to_unsigned(n + 1, 20); else a := to_unsigned(1 - n, 20); end if;
      p := shift_left(resize(a, 40), 16) + shift_left(resize(a, 40), 8) + resize(a, 40);
      q := to_integer(p(39 downto 24));
      if n >= 0 then return q; end if;
      return -q;
   end function;

   function clamp8(v : integer) return std_logic_vector is
   begin
      return std_logic_vector(to_unsigned(clampi(v, 0, 255), 8));
   end function;

   type tRGB is record r, g, b : integer; end record;

   -- YCbCr (Y already expanded, Cb/Cr signed) -> RGB, unclamped (JS put422/put444/yuvToRgb)
   function yuv(y, cb, cr : integer) return tRGB is
      variable rr, bb, gg : integer;
      variable o : tRGB;
   begin
      rr := to_integer(shift_right(to_signed(16#166# * cr + 128, 32), 8));
      bb := to_integer(shift_right(to_signed(16#1C7# * cb + 128, 32), 8));
      gg := to_integer(shift_right(to_signed(16#32# * bb + 16#83# * rr + 128, 32), 8));
      o.r := y + rr; o.g := y - gg; o.b := y + bb;
      return o;
   end function;

   -- big-endian byte n (0..3) of a word
   function wbyte(w : word; n : integer) return integer is
   begin
      case n is
         when 0      => return to_integer(unsigned(w(31 downto 24)));
         when 1      => return to_integer(unsigned(w(23 downto 16)));
         when 2      => return to_integer(unsigned(w(15 downto 8)));
         when others => return to_integer(unsigned(w(7 downto 0)));
      end case;
   end function;

   ------------------------------------------------------------------ cel table
   -- per cel: 12 header words + (lineCnt << 16 | lineTop & 0x3ff)
   signal celCount  : integer range 0 to MAX_CELS := 0;
   signal celWe     : std_logic := '0';
   signal celWA     : unsigned(11 downto 0) := (others => '0');
   signal celWD     : word := (others => '0');
   signal celRA     : unsigned(11 downto 0);
   signal celQ      : word;
   signal stIdx     : integer range 0 to 13 := 0;

   ------------------------------------------------------------------ line buffer (24-bit RGB)
   -- two buffers (sel = the one being composed) x two banks (even / odd pixel), 320 x 24 each
   type tLbAddr is array(0 to 1, 0 to 1) of unsigned(8 downto 0);
   type tLbData is array(0 to 1, 0 to 1) of std_logic_vector(23 downto 0);
   type tLbWe   is array(0 to 1, 0 to 1) of std_logic;
   type tFlags  is array(0 to 1) of std_logic_vector(0 to SCREEN_W - 1);
   signal lbRA      : tLbAddr;
   type tBankAddr is array(0 to 1) of unsigned(8 downto 0);
   signal cAddr     : tBankAddr;
   signal lbQ       : tLbData;
   signal lbWA      : unsigned(8 downto 0) := (others => '0');   -- per bank (registered write)
   signal lbWA1     : unsigned(8 downto 0) := (others => '0');
   signal lbWD0, lbWD1 : std_logic_vector(23 downto 0) := (others => '0');
   signal lbWe0, lbWe1 : std_logic := '0';
   signal lbWBuf    : integer range 0 to 1 := 0;
   signal lbFlags   : tFlags := (others => (others => '0'));
   signal sel       : integer range 0 to 1 := 0;
   signal wBusy     : std_logic := '0';
   signal wPend     : std_logic := '0';
   signal wPh       : std_logic := '0';
   signal wY        : integer range 0 to SCREEN_H := 0;
   signal wX        : integer range 0 to SCREEN_W := 0;
   signal wBase     : unsigned(27 downto 0) := (others => '0');

   ------------------------------------------------------------------ texel beat cache
   type tCacheTag  is array(0 to 31) of unsigned(12 downto 0);
   signal cTag      : tCacheTag;
   signal cWe       : std_logic;
   signal cWA       : std_logic_vector(6 downto 0);
   signal cWD       : std_logic_vector(63 downto 0);
   signal cRA       : std_logic_vector(6 downto 0);
   signal cQ        : std_logic_vector(63 downto 0);
   signal cValid    : std_logic_vector(0 to 31) := (others => '0');
   signal fillLine  : integer range 0 to 31 := 0;
   signal capture   : std_logic := '0';
   signal capCnt    : unsigned(1 downto 0) := (others => '0');

   ------------------------------------------------------------------ state
   type tState is (IDLE, GEOM, GEOM2, SETUP_B, SETUP_C, SETUP_D, SETUP_E,
                   B_YM, B_YM_W, B_CELW, B_CELW_W, B_CELDONE, B_CELSTORE, B_CELNEXT,
                   ROW_START, ROW_VID, ROW_VID_PIX, ROW_CEL, ROW_CEL_LOAD, ROW_CEL_SETUP,
                   PIX_FETCH, PIX_FETCH2, PIX_CB0, PIX_CB1, PIX_DRAW1,
                   ROW_OUT, FRAME_DONE,
                   RD_WORD, RD_WAIT);
   signal state, ret : tState := IDLE;

   -- geometry
   signal gHstart, gHsize, gVstart, gVsize : integer range -2048 to 4095 := 0;
   signal gNstart   : unsigned(31 downto 0) := (others => '0');
   signal gGfx, gEn, gCels : std_logic := '0';
   signal blankRGB  : std_logic_vector(23 downto 0) := (others => '0');

   -- first pass
   signal ymapBase, celsBase, celPtr : unsigned(31 downto 0) := (others => '0');
   signal ymOff     : unsigned(31 downto 0) := (others => '0');
   signal ymIdx     : integer range 0 to 255 := 0;
   signal celIdx    : integer range 0 to 255 := 0;
   signal celWords  : integer range 0 to 12 := 0;
   signal wordIdx   : integer range 0 to 12 := 0;
   signal bandHdr   : word := (others => '0');
   signal data      : tWords(0 to 11);

   -- rows
   signal y         : integer range 0 to SCREEN_H := 0;
   signal x         : integer range -4096 to 4095 := 0;
   signal xe        : integer range -4096 to 4095 := 0;
   signal vaddr     : unsigned(31 downto 0) := (others => '0');
   signal ce        : integer range 0 to MAX_CELS := 0;
   signal ldIdx     : integer range 0 to 15 := 0;
   signal cw        : tWords(0 to 12);             -- current cel header + band word
   signal u, v      : signed(31 downto 0) := (others => '0');
   signal one       : std_logic := '0';
   signal outX      : integer range 0 to SCREEN_W := 0;

   -- decoded current cel (registered in ROW_CEL_SETUP)
   signal cTex, cAlphaType : integer range 0 to 7 := 0;
   signal cGA       : integer range 0 to 255 := 255;
   signal cTexBase, cCb : unsigned(31 downto 0) := (others => '0');
   signal cRowBytes : integer range 0 to 65535 := 0;
   signal cDux, cDvx : signed(31 downto 0) := (others => '0');
   signal cUmask, cVmask : std_logic_vector(7 downto 0) := (others => '0');
   signal cBlend    : tRGB := (0, 0, 0);

   -- pixel pipeline
   signal tw0, tw1  : word := (others => '0');     -- fetched words (texel / codebook)
   signal fetchSel  : integer range 0 to 3 := 0;   -- byte offset of the first texel fetch
   signal fetchSel2 : integer range 0 to 3 := 0;   -- byte offset of the second (VQ8)
   signal px0, px1  : tRGB := (0, 0, 0);
   signal pa0, pa1  : integer range 0 to 255 := 0;  -- alpha for each pixel (0 = skip)
   signal pdo0, pdo1 : std_logic := '0';           -- pixel present

   -- pixel pipeline (one pair a cycle, fixed latency): S1 texel words -> S2 Y/Cb/Cr/alpha ->
   -- S3 Cr/Cb products -> S4 RGB (+ background read) -> S5 blend products -> line buffer
   type tInt2 is array(0 to 1) of integer range -1024 to 1023;
   type tA2   is array(0 to 1) of integer range 0 to 255;
   type tRGB2 is array(0 to 1) of tRGB;
   type tP3   is array(0 to 5) of integer range -262144 to 262143;
   signal p1v, p2v, p3v, p4v, p5v : std_logic := '0';
   signal p1kind    : integer range 0 to 2 := 0;     -- 1: 4:2:2 word, 2: two 4:4:4 words
   signal p1w0, p1w1 : word := (others => '0');
   signal p1ga      : integer range 0 to 255 := 255;
   signal p1x, p2x, p3x, p4x, p5x : integer range 0 to 1023 := 0;
   signal p1one, p2one, p3one, p4one, p5one : std_logic := '0';
   signal p2ye, p2cb, p2cr, p3ye, p3rr, p3bb : tInt2 := (others => 0);
   signal p2a, p3a, p4a, p5a : tA2 := (others => 0);
   signal p4c, p5c  : tRGB2 := (others => (0, 0, 0));
   signal p5pr, p5pb : tP3 := (others => 0);
   signal pipeBusy  : std_logic;

   -- cel setup stages
   signal sYy, sCr, sCb, sRr, sBb : integer range -1024 to 1023 := 0;
   signal sYoff     : integer range -2048 to 2047 := 0;
   signal sDuRaw    : signed(15 downto 0) := (others => '0');
   signal sUu, sVv, sXl, sXr : signed(31 downto 0) := (others => '0');
   signal sClipN    : integer range 0 to 4095 := 0;
   -- texel coordinates, registered from u / v (two cycles after a change of u / v)
   signal muR, mvR  : integer range -128 to 127 := 0;
   -- pipeline: background flag / default for S4, final values for S6
   type tBg2 is array(0 to 1) of std_logic_vector(23 downto 0);
   signal p4flag    : std_logic_vector(0 to 1) := "00";
   signal p4dflt    : tBg2 := (others => (others => '0'));
   signal p6v       : std_logic := '0';
   signal p6x       : integer range 0 to 1023 := 0;
   signal p6a       : tA2 := (others => 0);
   signal p6c       : tRGB2 := (others => (0, 0, 0));

   -- memory word read
   signal rdAddr    : unsigned(31 downto 0) := (others => '0');
   signal rdData    : word := (others => '0');
   signal reqPend   : std_logic := '0';

begin

   ------------------------------------------------------------------ memories
   icelmem : entity work.webtv_sdpram
   generic map (WIDTH => 32, AW => 12)
   port map (clk => clk1x, we => celWe, waddr => celWA, wdata => celWD, raddr => celRA, q => celQ);
   celRA <= to_unsigned(ce * 16 + ldIdx, 12) when ce < MAX_CELS else (others => '0');

   -- composer read address per bank for the pixel pair at x: (x+1)/2 in bank 0, x/2 in bank 1
   -- background read for the pair in S3 (data in S4): pixel p3x+k sits in bank (p3x+k) mod 2
   cAddr(0) <= to_unsigned((p3x + 1) / 2, 9) when (p3x < SCREEN_W) else (others => '0');
   cAddr(1) <= to_unsigned(p3x / 2, 9) when (p3x < SCREEN_W) else (others => '0');
   pipeBusy <= p1v or p2v or p3v or p4v or p5v or p6v;

   glb_buf : for b in 0 to 1 generate
      glb_bank : for k in 0 to 1 generate
         signal we : std_logic;
         signal wa : unsigned(8 downto 0);
         signal wd : std_logic_vector(23 downto 0);
         signal q  : std_logic_vector(23 downto 0);
      begin
         we <= lbWe0 when (k = 0 and lbWBuf = b) else lbWe1 when (k = 1 and lbWBuf = b) else '0';
         wa <= lbWA when k = 0 else lbWA1;
         wd <= lbWD0 when k = 0 else lbWD1;
         ilb : entity work.webtv_sdpram
         generic map (WIDTH => 24, AW => 9)
         port map (clk => clk1x, we => we, waddr => wa, wdata => wd, raddr => lbRA(b, k), q => q);
         lbQ(b, k) <= q;
         -- composer: the pair at x (x+1)/2 in bank 0, x/2 in bank 1; writer: wX/2 in both
         lbRA(b, k) <= cAddr(k) when b = sel else to_unsigned(wX / 2, 9);
      end generate;
   end generate;

   icache : entity mem.RamMLAB
   generic map (width => 64, widthad => 7)
   port map (inclock => clk2x, wren => cWe, data => cWD, wraddress => cWA, rdaddress => cRA, q => cQ);
   cRA <= std_logic_vector(rdAddr(9 downto 3));
   -- fills: the beats go straight from the DDR3 port into the MLAB's input registers
   cWe <= capture and ddr3_DOUT_READY and not rdram_granted2x;
   cWA <= std_logic_vector(to_unsigned(fillLine * 4 + to_integer(capCnt), 7));
   cWD <= ddr3_DOUT;

   process (clk1x)
      variable vi, n, k, yt, yb, ytc, yoff : integer;
      variable hs, vs, hst, vst : integer;
      variable ym : word;
      variable d0 : word;
      variable xl, xr, xs, xen : integer;
      variable uu, vv : signed(31 downto 0);
      variable a32 : unsigned(31 downto 0);
      variable mu, mv : integer;
      variable idx : signed(31 downto 0);
      variable rowb : signed(31 downto 0);
      variable bm, bc : integer;
      variable beat : std_logic_vector(63 downto 0);
      variable ci  : integer range 0 to 63;
      variable w   : word;
      variable c   : tRGB;
      variable bg  : std_logic_vector(23 downto 0);
      variable a, fa, ba, rr, gg, bb : integer;
      variable cr, cb, yy : integer;
      variable modeB : std_logic_vector(7 downto 0);
      variable rowlongs : integer;
      variable duxRaw : std_logic_vector(15 downto 0);
      variable px  : integer;
      variable bk  : integer range 0 to 1;

      -- a pixel nobody wrote this row: the row-start fill (blank colour, black inside the gfx window)
      impure function dflt(i : integer; row : integer) return std_logic_vector is
      begin
         if (gEn = '1' and gGfx = '1' and row >= gVstart and row < gVstart + gVsize and i >= gHstart and i < gHstart + gHsize) then
            return x"000000";
         end if;
         return blankRGB;
      end function;

      -- line-buffer write of pixel i in the composed buffer (registered: lands next cycle)
      procedure lbPut(i : integer; d : std_logic_vector(23 downto 0)) is
      begin
         if (i mod 2 = 0) then
            lbWe0 <= '1'; lbWA <= to_unsigned(i / 2, 9); lbWD0 <= d;
         else
            lbWe1 <= '1'; lbWA1 <= to_unsigned(i / 2, 9); lbWD1 <= d;
         end if;
         lbFlags(sel)(i) <= '1';
      end procedure;

      -- one 4:2:2 pixel of word w (first = Y0, else Y1), as put422 + drawPixel (alpha 255)
      procedure pix422(w : word; first : boolean; variable o : out tRGB; variable al : out integer) is
         variable y8 : integer;
         variable cc : tRGB;
      begin
         if first then y8 := wbyte(w, 0); else y8 := wbyte(w, 2); end if;
         cc := yuv(yexp(y8), wbyte(w, 1) - 128, wbyte(w, 3) - 128);
         o := cc;
         if y8 = 255 then al := 0; else al := 255; end if;
      end procedure;

      -- one 4:4:4 pixel Y Cb A Cr (put444)
      procedure pix444(w : word; variable o : out tRGB; variable al : out integer) is
         variable cc : tRGB;
         variable cr8, cb8 : integer;
      begin
         cr8 := to_integer(signed(w(7 downto 0)));
         cb8 := to_integer(signed(w(23 downto 16)));
         cc := yuv(yexp(wbyte(w, 0)), cb8, cr8);
         o := cc;
         al := wbyte(w, 2);
         if wbyte(w, 0) = 255 then al := 0; end if;
      end procedure;

   begin
      if rising_edge(clk1x) then

         rdram_request <= '0';
         celWe         <= '0';
         lbWe0         <= '0';
         lbWe1         <= '0';
         lbWBuf        <= sel;
         p1v           <= '0';

         case state is

            ------------------------------------------------ idle / frame setup
            when IDLE =>
               busy <= '0';
               if (start = '1') then
                  busy    <= '1';
                  cValid  <= (others => '0');
                  lbFlags(sel) <= (others => '0');
                  state   <= GEOM;
               end if;

            when GEOM =>
               -- SoloVideo.validate()
               hs := clampi(to_integer(unsigned(pot_hsize(15 downto 0))), 2, SCREEN_W);
               if unsigned(pot_hsize(31 downto 16)) /= 0 then hs := SCREEN_W; end if;
               vs := clampi(to_integer(unsigned(pot_vsize(15 downto 0))), 2, SCREEN_H);
               if unsigned(pot_vsize(31 downto 16)) /= 0 then vs := SCREEN_H; end if;
               a32 := unsigned(vid_nstart);
               if (pot_cntl(3) = '1') then
                  if unsigned(gfx_hcounterinit) /= 0 then
                     if to_integer(unsigned(gfx_hcounterinit(15 downto 0))) * 2 < hs and unsigned(gfx_hcounterinit(31 downto 16)) = 0 then
                        hs := 2 * to_integer(unsigned(gfx_hcounterinit(15 downto 0)));
                     end if;
                  end if;
                  if unsigned(gfx_activelines) /= 0 then
                     n := 2 * to_integer(signed(gfx_activelines(15 downto 0))) - to_integer(signed(gfx_blanklines(15 downto 0))) - 2;
                     if n < 2 then n := 2; end if;
                     if n < vs then vs := n; end if;
                  end if;
               else
                  a32 := a32 + to_unsigned(4 * hs, 32);
                  vs  := vs - 2;
               end if;
               gHsize  <= hs; gVsize <= vs;
               gNstart <= a32;
               vaddr   <= a32;
               state   <= GEOM2;

            when GEOM2 =>
               hs  := gHsize; vs := gVsize;
               hst := to_integer(signed(pot_hstart(15 downto 0))) - 16#77#;
               if hst < 2 then hst := 2; end if;
               vst := to_integer(signed(pot_vstart(15 downto 0))) - 16#23#;
               if vst < 2 then vst := 2; end if;
               if hst + hs > SCREEN_W then hst := SCREEN_W - hs; end if;
               if vst + vs > SCREEN_H then vst := SCREEN_H - vs; end if;
               gHstart <= hst; gVstart <= vst;
               gGfx    <= pot_cntl(3);
               if (pot_cntl(3) = '1') then
                  gEn   <= pot_cntl(0) and gfx_cntl(7);
               else
                  gEn   <= pot_cntl(0) and vid_dmacntl(2);
               end if;
               if (pot_cntl(3) = '1' and pot_cntl(0) = '1' and gfx_cntl(7) = '1' and gfx_ymapbase_master /= x"80000000") then
                  gCels <= '1';
               else
                  gCels <= '0';
               end if;
               -- blank colour (cacheBlank)
               c := yuv(yexp(wbyte(pot_blnkcol, 1)), wbyte(pot_blnkcol, 2) - 128, wbyte(pot_blnkcol, 3) - 128);
               blankRGB <= clamp8(c.r) & clamp8(c.g) & clamp8(c.b);
               -- first pass
               ymapBase <= unsigned(gfx_ymapbase_master);
               celsBase <= unsigned(gfx_celsbase_master);
               ymOff    <= (others => '0');
               ymIdx    <= 0;
               celCount <= 0;
               if (pot_cntl(3) = '1' and pot_cntl(0) = '1' and gfx_cntl(7) = '1' and gfx_ymapbase_master /= x"80000000") then
                  state <= B_YM;
               else
                  y     <= 0;
                  state <= ROW_START;
               end if;

            ------------------------------------------------ first pass: ymap bands
            when B_YM =>
               if (ymIdx = 255) then
                  y <= 0; state <= ROW_START;
               else
                  rdAddr <= ymapBase + ymOff;
                  ymOff  <= ymOff + 4;
                  ret    <= B_YM_W;
                  state  <= RD_WORD;
               end if;

            when B_YM_W =>
               ym := rdData;
               ymIdx <= ymIdx + 1;
               if (ym(12) = '1') then
                  state <= B_YM;                                         -- disabled band
               elsif (ym(22 downto 13) = "0111111111") then
                  y <= 0; state <= ROW_START;                            -- termination
               else
                  bandHdr <= ym;
                  -- fresh data[] for the band
                  data <= (2 => x"00100000", 3 => x"ff000000", 6 => x"00000100", 10 => x"ffff0000", 11 => x"00dbdbdb", others => (others => '0'));
                  case ym(11 downto 10) is
                     when "00" => celWords <= 2;
                     when "01" => celWords <= 4;
                     when others => celWords <= 12;
                  end case;
                  celPtr  <= celsBase + shift_left(resize(unsigned(ym(9 downto 0)), 32), 3);
                  celIdx  <= 0;
                  wordIdx <= 0;
                  state   <= B_CELW;
               end if;

            when B_CELW =>
               if (wordIdx = celWords) then
                  state <= B_CELDONE;
               else
                  rdAddr <= celPtr + to_unsigned(4 * wordIdx, 32);
                  ret    <= B_CELW_W;
                  state  <= RD_WORD;
               end if;

            when B_CELW_W =>
               data(wordIdx) <= rdData;
               wordIdx <= wordIdx + 1;
               state   <= B_CELW;

            when B_CELDONE =>
               d0 := data(0);
               modeB := d0(31 downto 24);
               if (modeB(3 downto 1) = "110") then
                  -- loadData
                  case to_integer(unsigned(modeB(6 downto 4))) is
                     when 1 => ymapBase <= shift_left(resize(unsigned(data(1)(23 downto 0)), 32), 2) and x"03FFFFFC";
                     when 5 => ymapBase <= unsigned(gfx_ymapbase_master);
                     when 2 => celsBase <= shift_left(resize(unsigned(data(1)(23 downto 0)), 32), 2) and x"03FFFFFC";
                     when 6 => celsBase <= unsigned(gfx_celsbase_master);
                     when others => null;                              -- 4: initColor (not drawn)
                  end case;
               elsif (celCount < MAX_CELS) then
                  stIdx <= 0;
                  state <= B_CELSTORE;
               end if;
               if (modeB(3 downto 1) = "110" or celCount = MAX_CELS) then
                  state <= B_CELNEXT;
               end if;

            when B_CELSTORE =>
               -- the cel's 12 words + band word into the table, one per cycle
               celWe <= '1';
               celWA <= to_unsigned(celCount * 16 + stIdx, 12);
               if (stIdx = 12) then
                  celWD    <= bandHdr;
                  celCount <= celCount + 1;
                  state    <= B_CELNEXT;
               else
                  celWD <= data(stIdx);
                  stIdx <= stIdx + 1;
               end if;

            when B_CELNEXT =>
               d0 := data(0);
               modeB := d0(31 downto 24);
               if (modeB(7) = '1' or celIdx = 254) then
                  state <= B_YM;
               else
                  celIdx  <= celIdx + 1;
                  celPtr  <= celPtr + to_unsigned(4 * celWords, 32);
                  wordIdx <= 0;
                  state   <= B_CELW;
               end if;

            ------------------------------------------------ rows
            when ROW_START =>
               if (y = SCREEN_H) then
                  state <= FRAME_DONE;
               else
                  if (gGfx = '0') then
                     if (gEn = '1' and y >= gVstart and y < gVstart + gVsize) then
                        x     <= 0;
                        state <= ROW_VID;
                     else
                        outX <= 0; state <= ROW_OUT;
                     end if;
                  else
                     ce    <= 0;
                     state <= ROW_CEL;
                  end if;
               end if;

            -- vid mode: hsize pixels from vaddr, 2 per word
            when ROW_VID =>
               if (x >= gHsize) then
                  outX <= 0; state <= ROW_OUT;
               else
                  rdAddr <= vaddr;
                  vaddr  <= vaddr + 4;
                  ret    <= ROW_VID_PIX;
                  state  <= RD_WORD;
               end if;

            when ROW_VID_PIX =>
               px := (gHstart / 2) * 2 + x;
               if (px < SCREEN_W) then
                  p1v <= '1'; p1kind <= 1; p1w0 <= rdData; p1x <= px; p1one <= '0'; p1ga <= 255;
               end if;
               x     <= x + 2;
               state <= ROW_VID;

            -- gfx mode: each cel that covers row y
            when ROW_CEL =>
               if (gCels = '0' or ce = celCount) then
                  outX <= 0; state <= ROW_OUT;
               else
                  ldIdx <= 0;
                  state <= ROW_CEL_LOAD;
               end if;

            when ROW_CEL_LOAD =>
               -- celQ = word ldIdx - 1 (the table read is registered)
               if (ldIdx > 0) then cw(ldIdx - 1) <= celQ; end if;
               if (ldIdx = 13) then state <= ROW_CEL_SETUP; else ldIdx <= ldIdx + 1; end if;

            when ROW_CEL_SETUP =>
               -- drawCel: rows yTop .. yBottom
               yt  := gVstart + gVsize / 2 + s10(cw(12)(22 downto 13)) + to_integer(unsigned(cw(0)(23 downto 16)));
               yb  := yt + to_integer(unsigned(cw(12)(31 downto 23))) - to_integer(unsigned(cw(1)(31 downto 24)));
               if yb > gVstart + gVsize then yb := gVstart + gVsize; end if;
               ytc := yt;
               if ytc < gVstart then ytc := gVstart; end if;
               ce <= ce + 1;
               if (y < ytc or y >= yb) then
                  state <= ROW_CEL;
               else
                  yoff := y - yt;
                  modeB := cw(0)(31 downto 24);
                  cTex       <= to_integer(unsigned(modeB(3 downto 1)));
                  cAlphaType <= to_integer(unsigned(modeB(5 downto 4)));
                  cGA        <= to_integer(unsigned(cw(3)(31 downto 24)));
                  cTexBase   <= shift_left(resize(unsigned(cw(1)(23 downto 0)), 32), 2);
                  cCb        <= resize(unsigned(cw(3)(23 downto 0)), 32);
                  rowlongs   := to_integer(unsigned(cw(2)(31 downto 24))) * 16 + to_integer(unsigned(cw(0)(13 downto 10)));
                  cRowBytes  <= (rowlongs + 1) * 4;
                  duxRaw     := cw(10)(15 downto 12) & cw(2)(23 downto 16) & cw(10)(11 downto 8);
                  cDux       <= resize(signed(duxRaw), 32);
                  cDvx       <= resize(signed(cw(9)(15 downto 0)), 32);
                  cUmask     <= cw(10)(31 downto 24);
                  cVmask     <= cw(10)(23 downto 16);
                  -- alpha type 3 blend colour, stage 1
                  sYy <= yexp(to_integer(unsigned(cw(11)(23 downto 16))) + 32);   -- (yBlend + Y_BLACK): yexp subtracts 16
                  sCr <= to_integer(signed(cw(11)(7 downto 0)));
                  sCb <= to_integer(signed(cw(11)(15 downto 8)));
                  sYoff  <= yoff;
                  sDuRaw <= signed(duxRaw);
                  state  <= SETUP_B;
               end if;

            when SETUP_B =>
               -- row start values (products), edges before truncation, blend stage 2
               sUu <= resize(signed(cw(4)(31 downto 16)), 32) + to_signed(sYoff, 16) * signed(cw(4)(15 downto 0));
               sVv <= resize(signed(cw(6)(31 downto 16)), 32) + to_signed(sYoff, 16) * signed(cw(6)(15 downto 0));
               xl := s10(cw(0)(9 downto 0)) * 1024 + to_integer(unsigned(cw(7)(29 downto 20)));
               sXl <= to_signed(xl, 32) + to_signed(sYoff, 12) * signed(cw(7)(19 downto 0));
               xr := s10(cw(2)(9 downto 0)) * 1024 + to_integer(unsigned(cw(8)(29 downto 20)));
               sXr <= to_signed(xr, 32) + to_signed(sYoff, 12) * signed(cw(8)(19 downto 0));
               sRr <= sYy + to_integer(shift_right(to_signed(16#166# * sCr + 128, 32), 8));
               sBb <= sYy - to_integer(shift_right(to_signed(16#1C7# * sCb + 128, 32), 8));
               state <= SETUP_C;

            when SETUP_C =>
               xl  := truncZ10(sXl);
               xr  := truncZ10(sXr);
               xs  := gHstart + gHsize / 2 + xl;
               xen := gHsize / 2 + xr;
               if xen > gHsize then xen := gHsize; end if;
               xen := gHstart + xen;
               if (xs < gHstart) then
                  sClipN <= gHstart - xs;
                  xs := gHstart;
               else
                  sClipN <= 0;
               end if;
               x  <= xs; xe <= xen;
               gg := sYy + to_integer(shift_right(to_signed(16#32# * sBb + 16#83# * sRr + 128, 32), 8));
               cBlend <= (sRr, gg, sBb);
               state <= SETUP_D;

            when SETUP_D =>
               -- clipped at the window's left edge: advance u, v by the skipped pixels
               u <= sUu + resize(sDuRaw, 16) * to_signed(sClipN, 16);
               v <= sVv + signed(cw(9)(15 downto 0)) * to_signed(sClipN, 16);
               if (x >= xe) then
                  state <= ROW_CEL;
               else
                  if (x + 1 = xe) then one <= '1'; else one <= '0'; end if;
                  state <= SETUP_E;
               end if;

            when SETUP_E =>
               state <= PIX_FETCH;             -- muR / mvR follow the new u, v

            -- texel fetches (each through RD_WORD)
            when PIX_FETCH =>
               mu := muR;
               mv := mvR;
               rowb := signed(cTexBase) + to_signed(mv, 12) * to_signed(cRowBytes, 20);
               case cTex is
                  when 1 | 4 | 5 =>
                     idx := rowb + to_signed(mu * 2, 32);
                     u <= u + shift_left(cDux, 1); v <= v + shift_left(cDvx, 1);
                     rdAddr <= unsigned(idx); ret <= PIX_DRAW1; state <= RD_WORD;
                  when 3 =>
                     idx := rowb + to_signed(mu * 4, 32);
                     u <= u + cDux; v <= v + cDvx;
                     rdAddr <= unsigned(idx); ret <= PIX_FETCH2; state <= RD_WORD;
                  when 2 =>
                     idx := rowb + to_signed(mu, 32);
                     fetchSel <= to_integer(unsigned(idx(1 downto 0)));
                     u <= u + cDux; v <= v + cDvx;
                     rdAddr <= unsigned(idx); ret <= PIX_FETCH2; state <= RD_WORD;
                  when 7 =>
                     if mu >= 0 then k := mu / 2; else k := -((-mu) / 2); end if;
                     idx := rowb + to_signed(k, 32);
                     fetchSel <= to_integer(unsigned(idx(1 downto 0)));
                     u <= u + cDux; v <= v + cDvx;
                     rdAddr <= unsigned(idx); ret <= PIX_CB0; state <= RD_WORD;
                  when others =>
                     u <= u + shift_left(cDux, 1); v <= v + shift_left(cDvx, 1);
                     state <= PIX_DRAW1;                               -- nothing drawn
               end case;

            when PIX_FETCH2 =>
               -- second texel (3: direct 4:4:4, 2: VQ8 index)
               tw0 <= rdData;
               mu := muR;
               mv := mvR;
               rowb := signed(cTexBase) + to_signed(mv, 12) * to_signed(cRowBytes, 20);
               if (cTex = 3) then
                  idx := rowb + to_signed(mu * 4, 32);
                  ret <= PIX_DRAW1;
               else
                  idx := rowb + to_signed(mu, 32);
                  fetchSel2 <= to_integer(unsigned(idx(1 downto 0)));
                  ret <= PIX_CB0;
               end if;
               u <= u + cDux; v <= v + cDvx;
               rdAddr <= unsigned(idx);
               state  <= RD_WORD;

            when PIX_CB0 =>
               -- codebook lookups: VQ8 (indices from tw0 / rdData), VQ4 (two nibbles of one byte)
               if (cTex = 2) then
                  tw1 <= rdData;                                       -- word holding index 1
                  k := wbyte(tw0, fetchSel);                           -- index 0 (fetchSel of the first fetch)
               else
                  k := wbyte(rdData, fetchSel) / 16;
                  tw1 <= rdData;
               end if;
               rdAddr <= shift_left(cCb + to_unsigned(k, 32), 2);
               ret    <= PIX_CB1;
               state  <= RD_WORD;

            when PIX_CB1 =>
               tw0 <= rdData;                                          -- codebook entry for pixel 0
               if (one = '1') then
                  state <= PIX_DRAW1;
               else
                  if (cTex = 2) then
                     -- index 1 sits at the second fetch address
                     k := wbyte(tw1, fetchSel2);
                  else
                     k := wbyte(tw1, fetchSel) mod 16;
                  end if;
                  rdAddr <= shift_left(cCb + to_unsigned(k, 32), 2);
                  ret    <= PIX_DRAW1;
                  state  <= RD_WORD;
               end if;

            when PIX_DRAW1 =>
               -- the pair goes down the pixel pipeline (drawPixel)
               --   1/4/5: rdData = the 4:2:2 word; 3: tw0, rdData = the two 4:4:4 words;
               --   2/7: tw0, rdData = the two codebook entries
               if (x < SCREEN_W) then
                  p1v <= '1'; p1x <= x; p1one <= one; p1ga <= cGA;
                  case cTex is
                     when 1 | 4 | 5 => p1kind <= 1; p1w0 <= rdData;
                     when 2 | 3 | 7 => p1kind <= 2; p1w0 <= tw0; p1w1 <= rdData;
                     when others    => p1kind <= 0;
                  end case;
               end if;
               -- next pair
               x <= x + 2;
               if (x + 2 >= xe) then
                  state <= ROW_CEL;
               else
                  if (x + 3 = xe) then one <= '1'; else one <= '0'; end if;
                  state <= PIX_FETCH;
               end if;

            ------------------------------------------------ hand the row to the writer
            when ROW_OUT =>
               if (wBusy = '0' and pipeBusy = '0') then
                  -- swap: the composed row goes to the writer, the written-out buffer is the next row
                  sel    <= 1 - sel;
                  lbFlags(1 - sel) <= (others => '0');
                  wY     <= y;
                  wX     <= 0;
                  wPh    <= '0';
                  wBase  <= fb_base;
                  wBusy  <= '1';
                  y      <= y + 1;
                  state  <= ROW_START;
               end if;

            when FRAME_DONE =>
               if (wBusy = '0') then
                  busy  <= '0';
                  state <= IDLE;
               end if;

            ------------------------------------------------ read the big-endian word at rdAddr (box RAM)
            when RD_WORD =>
               a32 := rdAddr and x"007FFFFC";
               ci  := to_integer(a32(9 downto 5));
               if (cValid(ci) = '1' and cTag(ci) = a32(22 downto 10)) then
                  beat := cQ;
                  if a32(2) = '0' then
                     rdData <= beat(7 downto 0) & beat(15 downto 8) & beat(23 downto 16) & beat(31 downto 24);
                  else
                     rdData <= beat(39 downto 32) & beat(47 downto 40) & beat(55 downto 48) & beat(63 downto 56);
                  end if;
                  state <= ret;
               else
                  -- line fill: 4 beats, written into the cache MLAB by the clk2x capture
                  rdram_rnw        <= '1';
                  rdram_burstcount <= 10x"004";
                  rdram_address    <= RAM_BASE + (a32(27 downto 5) & "00000");
                  rdram_request    <= '1';
                  fillLine         <= ci;
                  cValid(ci)       <= '0';
                  state            <= RD_WAIT;
               end if;

            when RD_WAIT =>
               if (rdram_done = '1') then
                  a32 := rdAddr and x"007FFFFC";
                  ci  := to_integer(a32(9 downto 5));
                  cTag(ci)   <= a32(22 downto 10);
                  cValid(ci) <= '1';
                  state      <= RD_WORD;
               end if;

         end case;

         ------------------------------------------------ pixel pipeline
         -- S1 -> S2: Y (expanded), Cb, Cr, alpha per pixel
         p2v <= p1v; p2x <= p1x; p2one <= p1one;
         for k in 0 to 1 loop
            if (p1kind = 1) then
               if k = 0 then n := wbyte(p1w0, 0); else n := wbyte(p1w0, 2); end if;
               p2ye(k) <= yexp(n);
               p2cb(k) <= wbyte(p1w0, 1) - 128;
               p2cr(k) <= wbyte(p1w0, 3) - 128;
               if (n = 255) then p2a(k) <= 0; else p2a(k) <= p1ga; end if;   -- alpha 255 or global alpha
            elsif (p1kind = 2) then
               if k = 0 then w := p1w0; else w := p1w1; end if;
               p2ye(k) <= yexp(wbyte(w, 0));
               p2cb(k) <= to_integer(signed(w(23 downto 16)));
               p2cr(k) <= to_integer(signed(w(7 downto 0)));
               a := wbyte(w, 2);
               if (wbyte(w, 0) = 255) then a := 0; end if;
               if (a /= 0 and (a = 255 or p1ga /= 255)) then a := p1ga; end if;
               p2a(k) <= a;
            else
               p2a(k) <= 0; p2ye(k) <= 0; p2cb(k) <= 0; p2cr(k) <= 0;
            end if;
         end loop;
         if (p1one = '1') then p2a(1) <= 0; end if;
         -- S2 -> S3: the Cr / Cb products
         p3v <= p2v; p3x <= p2x; p3one <= p2one; p3ye <= p2ye; p3a <= p2a;
         for k in 0 to 1 loop
            p3rr(k) <= to_integer(shift_right(to_signed(16#166# * p2cr(k) + 128, 32), 8));
            p3bb(k) <= to_integer(shift_right(to_signed(16#1C7# * p2cb(k) + 128, 32), 8));
         end loop;
         -- S3 -> S4: RGB (the background read for p3x is issued now: lbQ valid in S4)
         p4v <= p3v; p4x <= p3x; p4one <= p3one; p4a <= p3a;
         for k in 0 to 1 loop
            px := p3x + k;
            if (px < SCREEN_W) then
               p4flag(k) <= lbFlags(sel)(px);
               p4dflt(k) <= dflt(px, y);
            end if;
         end loop;
         for k in 0 to 1 loop
            n := to_integer(shift_right(to_signed(16#32# * p3bb(k) + 16#83# * p3rr(k) + 128, 32), 8));
            p4c(k) <= (p3ye(k) + p3rr(k), p3ye(k) - n, p3ye(k) + p3bb(k));
         end loop;
         -- S4 -> S5: blend products: fa * c and bm * (background or blend colour)
         p5v <= p4v; p5x <= p4x; p5one <= p4one; p5a <= p4a; p5c <= p4c;
         for k in 0 to 1 loop
            if p4flag(k) = '1' then bg := lbQ(sel, (p4x + k) mod 2); else bg := p4dflt(k); end if;
            fa := p4a(k); ba := 255 - p4a(k);
            case cAlphaType is
               when 0      => bm := ba;
               when 1      => bm := fa;
               when 2      => bm := 0;
               when others => bm := ba;
            end case;
            p5pr(3 * k + 0) <= fa * p4c(k).r;
            p5pr(3 * k + 1) <= fa * p4c(k).g;
            p5pr(3 * k + 2) <= fa * p4c(k).b;
            if cAlphaType = 3 then
               p5pb(3 * k + 0) <= bm * cBlend.r; p5pb(3 * k + 1) <= bm * cBlend.g; p5pb(3 * k + 2) <= bm * cBlend.b;
            else
               p5pb(3 * k + 0) <= bm * to_integer(unsigned(bg(23 downto 16)));
               p5pb(3 * k + 1) <= bm * to_integer(unsigned(bg(15 downto 8)));
               p5pb(3 * k + 2) <= bm * to_integer(unsigned(bg(7 downto 0)));
            end if;
         end loop;
         -- S5 -> S6: divide
         p6v <= p5v; p6x <= p5x; p6a <= p5a;
         for k in 0 to 1 loop
            if (p5a(k) = 255) then
               p6c(k) <= p5c(k);
            else
               p6c(k) <= (div255(p5pr(3 * k) + p5pb(3 * k)), div255(p5pr(3 * k + 1) + p5pb(3 * k + 1)),
                          div255(p5pr(3 * k + 2) + p5pb(3 * k + 2)));
            end if;
         end loop;
         -- S6: clamp, write
         if (p6v = '1') then
            for k in 0 to 1 loop
               px := p6x + k;
               if (p6a(k) /= 0 and px < SCREEN_W) then
                  lbPut(px, clamp8(p6c(k).r) & clamp8(p6c(k).g) & clamp8(p6c(k).b));
               end if;
            end loop;
         end if;
         -- texel coordinates for the next fetch
         muR <= maskedTrunc(u, cUmask);
         mvR <= maskedTrunc(v, cVmask);

         ------------------------------------------------ row writer (second DDR3 client)
         fbw_request <= '0';
         -- the out buffer is 1 - sel; its read address is wX / 2 (data one cycle later: wPh)
         if (wBusy = '1') then
            if (wPh = '0') then
               wPh <= '1';
            elsif (wPend = '0') then
               if lbFlags(1 - sel)(wX) = '1' then bg := lbQ(1 - sel, 0); else bg := dflt(wX, wY); end if;
               fbw_dataWrite(31 downto 0) <= x"00" & bg(7 downto 0) & bg(15 downto 8) & bg(23 downto 16);
               if lbFlags(1 - sel)(wX + 1) = '1' then bg := lbQ(1 - sel, 1); else bg := dflt(wX + 1, wY); end if;
               fbw_dataWrite(63 downto 32) <= x"00" & bg(7 downto 0) & bg(15 downto 8) & bg(23 downto 16);
               fbw_address   <= wBase + to_unsigned((wY * SCREEN_W + wX) * 4, 28);
               fbw_request   <= '1';
               wPend         <= '1';
            elsif (fbw_done = '1') then
               wPend <= '0';
               wPh   <= '0';
               if (wX + 2 = SCREEN_W) then wBusy <= '0'; else wX <= wX + 2; end if;
            end if;
         end if;

         if (reset = '1') then
            state <= IDLE;
            busy  <= '0';
            wBusy <= '0';
            wPend <= '0';
         end if;
      end if;
   end process;

   -- cache line fills: the 4 beats of a granted read, straight from the DDR3 port
   process (clk2x)
   begin
      if rising_edge(clk2x) then
         if (rdram_granted2x = '1') then
            capture <= '1';
            capCnt  <= "00";
         elsif (capture = '1' and ddr3_DOUT_READY = '1') then
            capCnt <= capCnt + 1;
            if (capCnt = 3) then capture <= '0'; end if;
         end if;
      end if;
   end process;

end architecture;
