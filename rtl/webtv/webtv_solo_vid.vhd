-----------------------------------------------------------------
-- WebTV SOLO1 video units: registers, interrupts and display timing
--   vidUnit 0x3000 (framebuffer DMA), gfxUnit 0x6000 (cel compositor), dveUnit 0x7000,
--   divUnit 0x8000 (video in; 0x8040-0x805f belong to the audio unit), potUnit 0x9000
--   (pixel output: timing, blanking, interrupts), 0xD000 (id)
-- Register behaviour follows the webtv-bridge JS model (src/machine/solo_video.js) and the
-- wtvemac MAME driver; the display is modelled like both emulators: a progressive 640x480
-- frame (here with VGA-style 800x525 timing from pix_ce), POT_CLINE = current line, VSYNCO at
-- the start of vertical blank, HSYNC when the line in POT_HINTLINE starts.
--
-- Interrupts: each sub-unit has intstat/inten; the summary (BUS_VIDINTSTAT bits 5 div, 4 gfx,
-- 3 pot, 2 vid) is loaded into the SOLO's vid group with sum_load. Enabling a sub-unit interrupt
-- also sets the summary enable and BUS_INTEN.video (en_set), as the OS expects.
--
-- TIMING_EXTERNAL = '1' (lock-step testbench): the JS model times video in CPU cycles, so the
-- registers that depend on display timing are left to the testbench (handles = '0' for them)
-- and the summary is not loaded (the testbench forces the reference's).
--
-- Pixel output (framebuffer DMA, cels) is not here yet: this unit gives the timing.
-----------------------------------------------------------------
library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

entity webtv_solo_vid is
   generic
   (
      HTOTAL  : integer := 800;
      HACTIVE : integer := 640;
      VTOTAL  : integer := 525;
      VACTIVE : integer := 480
   );
   port
   (
      clk1x           : in  std_logic;
      reset           : in  std_logic;
      pix_ce          : in  std_logic;                     -- one pulse per pixel (clk1x)
      TIMING_EXTERNAL : in  std_logic := '0';

      bus_addr        : in  unsigned(15 downto 0);
      bus_read        : in  std_logic;
      bus_write       : in  std_logic;
      bus_be          : in  std_logic_vector(3 downto 0);
      bus_dataWrite   : in  std_logic_vector(31 downto 0);
      bus_dataRead    : out std_logic_vector(31 downto 0) := (others => '0');
      bus_done        : out std_logic := '0';
      handles         : out std_logic;                     -- from bus_addr and req_read (not bus_read: no loop)
      req_read        : in  std_logic;                     -- a read is being requested (before routing)

      sum_level       : out std_logic_vector(7 downto 0);  -- BUS_VIDINTSTAT value
      sum_load        : out std_logic := '0';
      en_set          : out std_logic_vector(7 downto 0) := (others => '0');
      vid_cleared     : in  std_logic := '0';               -- CPU cleared bits in BUS_VIDINTSTAT

      -- display timing (clk1x, advance on pix_ce)
      hcount          : out unsigned(9 downto 0);
      vcount          : out unsigned(9 downto 0);
      hblank          : out std_logic;
      vblank          : out std_logic;
      hsync           : out std_logic;
      vsync           : out std_logic;

      -- for the frame renderer
      frame_start     : out std_logic := '0';               -- displayed frame ends (vblank starts)
      pot_vstart, pot_vsize, pot_hstart, pot_hsize, pot_cntl, pot_blankColor : out std_logic_vector(31 downto 0);
      vid_nstart, vid_dmacntl : out std_logic_vector(31 downto 0);
      gfx_cntl, gfx_ymapbase_master, gfx_celsbase_master : out std_logic_vector(31 downto 0);
      gfx_hcounterinit, gfx_blanklines, gfx_activelines   : out std_logic_vector(31 downto 0);

      -- raw state load (JS snapshots, sim/trace.mjs vid.txt): register offsets as read, values stored as is
      init_we         : in  std_logic := '0';
      init_addr       : in  unsigned(15 downto 0) := (others => '0');
      init_data       : in  std_logic_vector(31 downto 0) := (others => '0')
   );
end entity;

architecture arch of webtv_solo_vid is

   subtype word is std_logic_vector(31 downto 0);
   type tWords is array(natural range <>) of word;

   constant VID_DIV : integer := 5;
   constant VID_GFX : integer := 4;
   constant VID_POT : integer := 3;
   constant VID_VID : integer := 2;
   constant POT_INT_VSYNCO : integer := 4;
   constant POT_INT_HSYNC  : integer := 3;
   constant VID_INT_DMA    : integer := 2;
   constant POT_FCNTL_USEGFX : integer := 3;

   -- vidUnit
   signal vNstart  : word := x"80000000";
   signal vNsize, vDmacntl, vCstart, vCsize, vCcnt, vVdata, vInten, vIntstat : word := (others => '0');
   -- gfxUnit: 0x6004..0x604c as an array (index (o - 4) / 4), plus the WB registers
   signal gRegs    : tWords(1 to 19) := (5 => x"80000000", 6 => x"80000000", 7 => x"80000000", 8 => x"80000000", others => (others => '0'));
   signal gInten, gIntstat, gWbdStart, gWbdLsize, gWbStride, gWbdConfig : word := (others => '0');
   -- divUnit
   signal dRegs    : tWords(0 to 31) := (others => (others => '0'));
   signal dInten, dIntstat, dGpioMask, dGpioOut : word := (others => '0');
   -- dveUnit (sparse in the JS model; 64 words here)
   signal dve      : tWords(0 to 63) := (others => (others => '0'));
   -- potUnit
   signal pVstart  : word := std_logic_vector(to_unsigned(30, 32));
   signal pVsize   : word := std_logic_vector(to_unsigned(420, 32));
   signal pBlank   : word := x"00108080";
   signal pHstart  : word := std_logic_vector(to_unsigned(16#77# + 40, 32));
   signal pHsize   : word := std_logic_vector(to_unsigned(560, 32));
   signal pCntl, pHintline, pInten, pIntstat : word := (others => '0');

   -- timing
   signal hc, vc   : unsigned(9 downto 0) := (others => '0');

   signal summary, summary_1 : std_logic_vector(7 downto 0) := (others => '0');
   signal readPend : std_logic := '0';

   function act(s, e : word) return std_logic is
   begin
      if (s and e) /= x"00000000" then return '1'; end if;
      return '0';
   end function;

   -- registers whose value depends on display timing
   function timingReg(o : integer) return boolean is
   begin
      return o = 16#90AC# or o = 16#90A0# or o = 16#90A8# or o = 16#3038# or
             o = 16#3000# or o = 16#3004# or o = 16#3008#;
   end function;

   function handled(a : unsigned(15 downto 0); ext : std_logic; rd : std_logic) return std_logic is
      variable u : integer;
   begin
      u := to_integer(a(15 downto 12));
      case u is
         when 16#3# | 16#6# | 16#7# | 16#9# | 16#D# => null;
         when 16#8# =>
            if a(11 downto 0) >= x"040" and a(11 downto 0) <= x"05F" then return '0'; end if;   -- audio
         when others => return '0';
      end case;
      if ext = '1' and rd = '1' and timingReg(to_integer(a)) then return '0'; end if;
      return '1';
   end function;

begin

   handles <= handled(bus_addr, TIMING_EXTERNAL, req_read);

   hcount <= hc;
   vcount <= vc;
   hblank <= '1' when hc >= HACTIVE else '0';
   vblank <= '1' when vc >= VACTIVE else '0';
   hsync  <= '1' when hc >= HACTIVE + 16 and hc < HACTIVE + 16 + 96 else '0';
   vsync  <= '1' when vc >= VACTIVE + 10 and vc < VACTIVE + 12 else '0';

   pot_vstart     <= pVstart;
   pot_vsize      <= pVsize;
   pot_hstart     <= pHstart;
   pot_hsize      <= pHsize;
   pot_cntl       <= pCntl;
   pot_blankColor <= pBlank;
   vid_nstart     <= vNstart;
   vid_dmacntl    <= vDmacntl;
   gfx_cntl            <= gRegs(1);    -- 0x6004
   gfx_celsbase_master <= gRegs(7);    -- 0x601c
   gfx_ymapbase_master <= gRegs(8);    -- 0x6020
   gfx_hcounterinit    <= gRegs(17);   -- 0x6044
   gfx_blanklines      <= gRegs(18);   -- 0x6048
   gfx_activelines     <= gRegs(19);   -- 0x604c

   summary <= "00" & act(dIntstat, dInten) & act(gIntstat, gInten) & act(pIntstat, pInten) & act(vIntstat, vInten) & "00";
   sum_level <= summary;

   process (clk1x)
      variable o    : integer;
      variable v, r : word;
      variable hl   : unsigned(9 downto 0);
   begin
      if rising_edge(clk1x) then

         bus_done    <= '0';
         en_set      <= (others => '0');
         frame_start <= '0';
         sum_load <= '0';

         ------------------------------------------------ timing
         if (pix_ce = '1') then
            if (hc = HTOTAL - 1) then
               hc <= (others => '0');
               if (vc = VTOTAL - 1) then vc <= (others => '0'); else vc <= vc + 1; end if;

               -- line vc + 1 starts
               if (pHintline(31 downto 9) = 23x"0") then hl := unsigned(pHintline(9 downto 0)); else hl := to_unsigned(VACTIVE - 1, 10); end if;
               if (hl > VACTIVE - 1) then hl := to_unsigned(VACTIVE - 1, 10); end if;
               if ((vc + 1 = hl and vc /= VTOTAL - 1) or (vc = VTOTAL - 1 and hl = 0)) then
                  pIntstat(POT_INT_HSYNC) <= pInten(POT_INT_HSYNC) or pIntstat(POT_INT_HSYNC);
               end if;
               if (vc + 1 = VACTIVE) then
                  -- end of the displayed frame (JS endField / MAME vblank)
                  frame_start <= '1';
                  pIntstat(POT_INT_VSYNCO) <= pInten(POT_INT_VSYNCO) or pIntstat(POT_INT_VSYNCO);
                  vCstart <= vNstart;
                  vCsize  <= vNsize;
                  if (pCntl(POT_FCNTL_USEGFX) = '0') then
                     vIntstat(VID_INT_DMA) <= vInten(VID_INT_DMA) or vIntstat(VID_INT_DMA);
                  end if;
               end if;
            else
               hc <= hc + 1;
            end if;
         end if;

         o := to_integer(bus_addr);
         v := bus_dataWrite;
         for b in 0 to 3 loop
            if (bus_be(b) = '0') then v(8 * b + 7 downto 8 * b) := x"00"; end if;
         end loop;

         ------------------------------------------------ reads
         if (bus_read = '1') then
            bus_done <= '1';
            r := (others => '0');
            case o is
               when 16#3000# => r := vCstart;
               when 16#3004# => r := vCsize;
               when 16#3008# => r := vCcnt;
               when 16#300C# => r := vNstart;
               when 16#3010# => r := vNsize;
               when 16#3014# => r := vDmacntl;
               when 16#3038# => r := vIntstat;
               when 16#303C# => r := vInten;
               when 16#3040# => r := vVdata;
               when 16#6004# to 16#604C# =>
                  if (o mod 4 = 0) then r := gRegs((o - 16#6000#) / 4); end if;
               when 16#6060# => r := gInten;
               when 16#6068# => r := gIntstat;
               when 16#6080# | 16#6094# => r := gWbdStart;
               when 16#6084# => r := gWbdLsize;
               when 16#608C# => r := gWbStride;
               when 16#6090# => r := gWbdConfig;
               when 16#9080# => r := pVstart;
               when 16#9084# => r := pVsize;
               when 16#9088# => r := pBlank;
               when 16#908C# => r := pHstart;
               when 16#9090# => r := pHsize;
               when 16#9094# => r := pCntl;
               when 16#9098# => r := pHintline;
               when 16#909C# => r := pInten;
               when 16#90A0# | 16#90A8# => r := pIntstat;
               when 16#90AC# => r := 22x"0" & std_logic_vector(vc);
               when 16#D000# => r := x"00020000";
               when 16#8060# | 16#806C# => null;
               when 16#8064# => r := dGpioMask;
               when 16#8068# => r := dGpioOut and dGpioMask;
               when 16#8070# | 16#8074# => r := dInten;
               when 16#8078# | 16#807C# => r := dIntstat;
               when 16#8000# to 16#805C# =>
                  if (o mod 4 = 0) then r := dRegs((o - 16#8000#) / 4); end if;
               when 16#7000# to 16#7FFC# =>
                  if (o mod 4 = 0) then r := dve(((o - 16#7000#) / 4) mod 64); end if;
               when others => null;
            end case;
            bus_dataRead <= r;
         end if;

         ------------------------------------------------ writes
         if (bus_write = '1') then
            bus_done <= '1';
            case o is
               when 16#300C# => vNstart <= v and x"03FFFFFC";
               when 16#3010# => vNsize <= v;
               when 16#3014# => vDmacntl <= v;
               when 16#3138# => vIntstat <= vIntstat and not v;
               when 16#303C# =>
                  vInten <= vInten or v;
                  if ((vInten or v) /= x"00000000") then en_set(VID_VID) <= '1'; end if;
               when 16#313C# => vIntstat <= vIntstat and not v; vInten <= vInten and not v;
               when 16#3040# => vVdata <= v;

               when 16#6014# | 16#6018# | 16#601C# | 16#6020# => gRegs((o - 16#6000#) / 4) <= v and x"03FFFFFC";
               when 16#6004# | 16#6010# | 16#6024# to 16#604C# =>
                  if (o mod 4 = 0) then gRegs((o - 16#6000#) / 4) <= v; end if;
               when 16#6060# =>
                  gInten <= gInten or v;
                  if ((gInten or v) /= x"00000000") then en_set(VID_GFX) <= '1'; end if;
               when 16#6064# => gIntstat <= gIntstat and not v; gInten <= gInten and not v;
               when 16#6068# => gIntstat <= gIntstat or v;
               when 16#606C# => gIntstat <= gIntstat and not v;
               when 16#6080# => gWbdStart <= v and x"03FFFFFC";
               when 16#6084# => gWbdLsize <= v;
               when 16#608C# => gWbStride <= v;
               when 16#6090# => gWbdConfig <= v;
               when 16#6094# => gWbdStart <= v;

               when 16#9080# => pVstart <= v;
               when 16#9084# => pVsize <= v;
               when 16#9088# => pBlank <= v;
               when 16#908C# => pHstart <= v;
               when 16#9090# => pHsize <= v;
               when 16#9094# => pCntl <= v;
               when 16#9098# => pHintline <= v;
               when 16#909C# =>
                  pInten <= pInten or v;
                  if ((pInten or v) /= x"00000000") then en_set(VID_POT) <= '1'; end if;
               when 16#90A4# => pIntstat <= pIntstat and not v; pInten <= pInten and not v;
               when 16#90A8# => pIntstat <= pIntstat and not v;

               when 16#8064# => dGpioMask <= v;
               when 16#8068# => dGpioOut <= dGpioOut or (v and dGpioMask);
               when 16#8168# => dGpioOut <= dGpioOut and not v;
               when 16#8070# =>
                  dInten <= dInten or v;
                  if ((dInten or v) /= x"00000000") then en_set(VID_DIV) <= '1'; end if;
               when 16#8170# => dInten <= dInten and not v; dIntstat <= dIntstat and not v;
               when 16#8078# => dIntstat <= dIntstat or v;
               when 16#8178# => dIntstat <= dIntstat and not v;
               when 16#8000# to 16#805C# =>
                  if (o mod 4 = 0) then dRegs((o - 16#8000#) / 4) <= v; end if;
               when 16#7000# to 16#7FFC# =>
                  if (o mod 4 = 0) then dve(((o - 16#7000#) / 4) mod 64) <= v; end if;
               when others => null;
            end case;
         end if;

         ------------------------------------------------ raw state load
         if (init_we = '1') then
            o := to_integer(init_addr);
            v := init_data;
            case o is
               when 16#3000# => vCstart <= v;
               when 16#3004# => vCsize <= v;
               when 16#3008# => vCcnt <= v;
               when 16#300C# => vNstart <= v;
               when 16#3010# => vNsize <= v;
               when 16#3014# => vDmacntl <= v;
               when 16#3038# => vIntstat <= v;
               when 16#303C# => vInten <= v;
               when 16#3040# => vVdata <= v;
               when 16#6004# to 16#604C# => if (o mod 4 = 0) then gRegs((o - 16#6000#) / 4) <= v; end if;
               when 16#6060# => gInten <= v;
               when 16#6068# => gIntstat <= v;
               when 16#6080# => gWbdStart <= v;
               when 16#6084# => gWbdLsize <= v;
               when 16#608C# => gWbStride <= v;
               when 16#6090# => gWbdConfig <= v;
               when 16#9080# => pVstart <= v;
               when 16#9084# => pVsize <= v;
               when 16#9088# => pBlank <= v;
               when 16#908C# => pHstart <= v;
               when 16#9090# => pHsize <= v;
               when 16#9094# => pCntl <= v;
               when 16#9098# => pHintline <= v;
               when 16#909C# => pInten <= v;
               when 16#90A0# => pIntstat <= v;
               when 16#8064# => dGpioMask <= v;
               when 16#8068# => dGpioOut <= v;
               when 16#8070# => dInten <= v;
               when 16#8078# => dIntstat <= v;
               when 16#8000# to 16#805C# => if (o mod 4 = 0) then dRegs((o - 16#8000#) / 4) <= v; end if;
               when 16#7000# to 16#7FFC# => if (o mod 4 = 0) then dve(((o - 16#7000#) / 4) mod 64) <= v; end if;
               when others => null;
            end case;
         end if;

         ------------------------------------------------ summary to the SOLO's vid group
         summary_1 <= summary;
         if (TIMING_EXTERNAL = '0' and (summary /= summary_1 or vid_cleared = '1')) then
            sum_load <= '1';
         end if;

         if (reset = '1') then
            null;   -- video state survives a CPU reset; the JS model resets it with the machine
         end if;

      end if;
   end process;

end architecture;
