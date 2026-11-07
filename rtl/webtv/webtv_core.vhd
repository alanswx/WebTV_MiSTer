-----------------------------------------------------------------
-- WebTV LC2 core: CPU (R4640, forked from N64_MiSTer) + memory system
--
--   cpu --mem_*--> webtv_memmux --RAM/ROM--> webtv_ddr3mux --> MiSTer DDR3 port
--                               --MMIO-----> bus_* ports (SOLO, modem, IDE ... live outside for now)
--   webtv_bustick: LC2 bus clock (83.58 MHz) from clk93, drives Count; also exported for the SOLO
--
-- DDR3 window (byte offsets from 0x30000000): RAM at RAM_BASE (8 MB), boot ROM at ROM_BASE (2 MB).
-- The HPS loader client (ROM image, savestates, disk DMA later) shares the DDR3 mux at the lowest
-- priority. Video/audio clients are reserved and tied off until the SOLO units exist.
--
-- Test ports (lockstep, irq replay, export, savestate) are what sim/n64cpu/tb_cpu.vhd uses to run
-- the core in lock-step with the JS reference; on hardware they are tied to their defaults.
-----------------------------------------------------------------
library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

library work;
use work.pexport.all;
use work.pWebTVDDR3.all;

entity webtv_core is
   generic
   (
      RAM_BASE : unsigned(27 downto 0) := x"0000000";
      ROM_BASE : unsigned(27 downto 0) := x"0800000";
      CLK93_HZ : natural := 93750000;
      CLK1X_HZ : natural := 62500000;
      FB_BASE0 : unsigned(27 downto 0) := x"0C00000";     -- two 640x480x32 framebuffers
      FB_BASE1 : unsigned(27 downto 0) := x"0E00000";
      PIX_HZ   : natural := 25175000
   );
   port
   (
      clk1x            : in  std_logic;
      clk93            : in  std_logic;
      clk2x            : in  std_logic;
      reset_1x         : in  std_logic;
      reset_93         : in  std_logic;
      reset_mem        : in  std_logic := '0';  -- DDR3 mux only: stays out of reset while the CPU is held, so the HPS can load
      cold_reset       : in  std_logic := '0';  -- power-on / OSD reset: SOLO units back to their power-up state
      dcache_on        : in  std_logic := '1';  -- CPU caches (quasi-static: change only while the CPU is held)
      icache_on        : in  std_logic := '1';

      -- CPU interrupt: from the SOLO, or (IRQ_EXTERNAL = '1', lock-step testbench) from irqRequest
      irqRequest       : in  std_logic := '0';
      IRQ_EXTERNAL     : in  std_logic := '0';
      solo_irq         : out std_logic;

      -- SOLO system-unit I/O
      serial_id        : in  std_logic_vector(63 downto 0) := x"ca0000c0ffee0101";
      soft_reset       : out std_logic;
      led              : out std_logic_vector(31 downto 0);
      dbg_tx           : out std_logic;
      dbg_tx_data      : out std_logic_vector(7 downto 0);
      dbg_rx           : in  std_logic := '0';
      dbg_rx_data      : in  std_logic_vector(7 downto 0) := (others => '0');
      modem7e_set      : in  std_logic := '0';
      solo_init_we     : in  std_logic := '0';
      solo_init_addr   : in  unsigned(15 downto 0) := (others => '0');
      solo_init_data   : in  std_logic_vector(31 downto 0) := (others => '0');
      iic_init_we      : in  std_logic := '0';
      iic_init_addr    : in  unsigned(15 downto 0) := (others => '0');
      iic_init_data    : in  std_logic_vector(31 downto 0) := (others => '0');
      vid_init_we      : in  std_logic := '0';
      vid_init_addr    : in  unsigned(15 downto 0) := (others => '0');
      vid_init_data    : in  std_logic_vector(31 downto 0) := (others => '0');
      ide_init_we      : in  std_logic := '0';
      ide_init_addr    : in  unsigned(15 downto 0) := (others => '0');
      ide_init_data    : in  std_logic_vector(31 downto 0) := (others => '0');

      -- hardware modem UART (16550) line side: 8N1 serial, carrier detect, flow control
      modem_txd        : out std_logic;
      modem_rxd        : in  std_logic := '1';
      modem_dcd        : in  std_logic := '0';
      modem_rts_n      : out std_logic;
      modem_mcr        : out std_logic_vector(7 downto 0);

      -- IR keyboard: one event per strobe (Sejin scancode, release)
      ir_key_strobe    : in  std_logic := '0';
      ir_key_code      : in  std_logic_vector(6 downto 0) := (others => '0');
      ir_key_release   : in  std_logic := '0';

      -- IDE disk image (hps_io block device, WIDE)
      img_mounted      : in  std_logic := '0';
      img_size         : in  unsigned(63 downto 0) := (others => '0');
      sd_lba           : out unsigned(31 downto 0);
      sd_blk_cnt       : out unsigned(5 downto 0);
      sd_rd            : out std_logic;
      sd_wr            : out std_logic;
      sd_ack           : in  std_logic := '0';
      sd_buff_addr     : in  unsigned(12 downto 0) := (others => '0');
      sd_buff_dout     : in  std_logic_vector(15 downto 0) := (others => '0');
      sd_buff_din      : out std_logic_vector(15 downto 0);
      sd_buff_wr       : in  std_logic := '0';

      -- MMIO bus: everything that is not RAM / boot ROM / SOLO system units
      bus_addr         : out unsigned(31 downto 0);
      bus_read         : out std_logic;
      bus_write        : out std_logic;
      bus_be           : out std_logic_vector(3 downto 0);
      bus_dataWrite    : out std_logic_vector(31 downto 0);
      bus_dataRead     : in  std_logic_vector(31 downto 0);
      bus_done         : in  std_logic;
      bus_tick         : out std_logic;   -- one pulse per LC2 bus clock (clk93 domain)

      -- video: the last completed frame (640x480, 32 bit R,G,B,0 in address order) and the timing
      fb_display       : out unsigned(27 downto 0);
      fb_frame         : out std_logic;   -- pulse when fb_display changes
      vid_hblank, vid_vblank, vid_hsync, vid_vsync : out std_logic;
      vid_ce           : out std_logic;

      -- HPS loader: DDR3 client (byte address in the core's window, clk2x handshake as the mux)
      hps_request      : in  std_logic := '0';
      hps_rnw          : in  std_logic := '1';
      hps_address      : in  unsigned(27 downto 0) := (others => '0');
      hps_burstcount   : in  unsigned(9 downto 0) := (others => '0');
      hps_writeMask    : in  std_logic_vector(7 downto 0) := (others => '0');
      hps_dataWrite    : in  std_logic_vector(63 downto 0) := (others => '0');
      hps_done         : out std_logic;
      hps_dataRead     : out std_logic_vector(63 downto 0);

      -- MiSTer DDR3 port
      ddr3_BUSY        : in  std_logic;
      ddr3_DOUT        : in  std_logic_vector(63 downto 0);
      ddr3_DOUT_READY  : in  std_logic;
      ddr3_BURSTCNT    : out std_logic_vector(7 downto 0);
      ddr3_ADDR        : out std_logic_vector(28 downto 0);
      ddr3_DIN         : out std_logic_vector(63 downto 0);
      ddr3_BE          : out std_logic_vector(7 downto 0);
      ddr3_WE          : out std_logic;
      ddr3_RD          : out std_logic;

      errors           : out std_logic_vector(7 downto 0);
      dbg_retired_cnt  : out unsigned(31 downto 0);           -- instructions issued (clk93), for bring-up displays
      dbg_pc           : out unsigned(31 downto 0);
      dbg_scr          : out std_logic_vector(159 downto 0);  -- last 5 words written to 0x1E00001C (boot ROM exception dump)
      -- bring-up branch trace: the last 1024 non-sequential PCs (count & pc), frozen when the CPU
      -- reaches the boot ROM exception vectors (0xBFC00380..0xBFC003FF); read port on clk1x
      dbg_ide          : out std_logic_vector(95 downto 0);  -- state & total & last access (addr low 16, data low 16) & count
      trace_frozen     : out std_logic;
      trace_wi         : out unsigned(9 downto 0);
      trace_ra         : in  unsigned(9 downto 0) := (others => '0');
      trace_q          : out std_logic_vector(63 downto 0);  -- 5:0 CPU, 6 DDR3 timeout, 7 memmux

      -- savestate port (CPU state load: reset values, JS snapshots)
      SS_reset         : in  std_logic := '0';
      SS_wren          : in  std_logic := '0';
      SS_Adr           : in  unsigned(11 downto 0) := (others => '0');
      SS_Data          : in  std_logic_vector(63 downto 0) := (others => '0');

      -- test / debug
      LOCKSTEP_COUNT   : in  std_logic := '0';
      IRQ_REPLAY       : in  std_logic := '0';
      irqReplayAt      : in  unsigned(31 downto 0) := (others => '1');
-- synthesis translate_off
      cpu_done         : out std_logic;
      cpu_export       : out cpu_export_type;
-- synthesis translate_on
      dbg_issued       : out unsigned(31 downto 0);
      dbg_solo_rd      : out std_logic;                      -- SOLO system unit answered a read (bus_done)
      dbg_solo_addr    : out unsigned(31 downto 0);
      dbg_solo_data    : out std_logic_vector(31 downto 0)
   );
end entity;

architecture arch of webtv_core is

   signal mem_request, mem_rnw, mem_req64 : std_logic;
   signal mem_address   : unsigned(31 downto 0);
   signal mem_size      : unsigned(2 downto 0);
   signal mem_writeMask : std_logic_vector(7 downto 0);
   signal mem_dataWrite : std_logic_vector(63 downto 0);
   signal mem_dataRead  : std_logic_vector(63 downto 0);
   signal mem_done      : std_logic;

   signal d_request, d_rnw, d_granted2x, d_done : tDDR3Single;
   signal d_address  : tDDR3Addr;
   signal d_burst    : tDDR3Burst;
   signal d_mask     : tDDR3Mask;
   signal d_data     : tDDR3Data;
   signal d_dataRead : std_logic_vector(63 downto 0);

   signal tick       : std_logic;
   signal countExt   : std_logic;
   signal retired    : std_logic;
   signal tcInc1, tcInc2 : std_logic;
   signal cpuIrq     : std_logic;
   signal soloIrq    : std_logic;
   signal iicCntl    : std_logic_vector(4 downto 1);
   signal iicScl, iicSda : std_logic;

   -- MMIO bus from the memmux, split between the SOLO system units and the outside
   signal m_addr     : unsigned(31 downto 0);
   signal m_read, m_write, m_done : std_logic;
   signal m_be       : std_logic_vector(3 downto 0);
   signal m_dataWrite, m_dataRead : std_logic_vector(31 downto 0);
   signal s_handles, s_sel, s_read, s_write, s_done : std_logic;
   signal s_dataRead : std_logic_vector(31 downto 0);
   signal v_handles, v_sel, v_read, v_write, v_done : std_logic;
   signal v_dataRead : std_logic_vector(31 downto 0);
   signal v_selRead  : std_logic := '0';
   signal vidSum, vidEnSet, vidCleared : std_logic_vector(7 downto 0);
   signal vidLoad, pixCe : std_logic;
   signal frameStart, rBusy, rBusy_1 : std_logic;
   signal r_pot_vstart, r_pot_vsize, r_pot_hstart, r_pot_hsize, r_pot_cntl, r_pot_blnkcol : std_logic_vector(31 downto 0);
   signal r_vid_nstart, r_vid_dmacntl, r_gfx_cntl, r_gfx_ymap, r_gfx_cels : std_logic_vector(31 downto 0);
   signal r_gfx_hci, r_gfx_bl, r_gfx_al : std_logic_vector(31 downto 0);
   signal fbDraw     : std_logic := '0';      -- buffer being drawn (0: FB_BASE0)
   signal fbShown    : unsigned(27 downto 0) := FB_BASE1;
   signal fbDrawBase : unsigned(27 downto 0);
   signal rStart     : std_logic;
   signal s_selRead  : std_logic := '0';
   signal i_handles, i_sel, i_read, i_write, i_done : std_logic;
   signal i_dataRead : std_logic_vector(31 downto 0);
   signal i_selRead  : std_logic := '0';
   signal ideSet, ideClr, ideLevel : std_logic;
   signal retCnt     : unsigned(15 downto 0) := (others => '0');
   signal retCnt32   : unsigned(31 downto 0) := (others => '0');
   signal cpuPc, pcR : unsigned(31 downto 0) := (others => '0');
   signal scrHist    : std_logic_vector(159 downto 0) := (others => '0');
   signal ideState   : std_logic_vector(15 downto 0);
   signal ideTotal   : std_logic_vector(31 downto 0);
   signal ideLastA, ideLastD, ideCnt : std_logic_vector(15 downto 0) := (others => '0');
   type tTrace is array(0 to 1023) of std_logic_vector(63 downto 0);
   signal traceMem   : tTrace;
   signal trWi       : unsigned(9 downto 0) := (others => '0');
   signal trFrozen   : std_logic := '0';
   signal trPrev     : unsigned(31 downto 0) := (others => '0');
   signal r_handles, r_sel, r_read, r_write, r_done, irIrq : std_logic;
   signal r_dataRead : std_logic_vector(31 downto 0);
   signal r_selRead  : std_logic := '0';
   signal u_handles, u_sel, u_read, u_write, u_done : std_logic;
   signal u_dataRead : std_logic_vector(31 downto 0);
   signal u_selRead  : std_logic := '0';
   signal uSet, uClr, uLevel, uM7e : std_logic;
   signal s_wasRead  : std_logic := '0';
   signal s_lastAddr : unsigned(31 downto 0) := (others => '0');

begin

   countExt <= not LOCKSTEP_COUNT;
   bus_tick <= tick;

   icpu : entity work.cpu
   port map (
      clk1x => clk1x, clk93 => clk93, clk2x => clk2x,
      ce_1x => '1', ce_93 => '1',
      reset_1x => reset_1x, reset_93 => reset_93, preNMI => '0',
      INSTRCACHEON => icache_on, DATACACHEON => dcache_on, DATACACHESLOW => "0000",
      DATACACHEFORCEWEB => '0', DATACACHETLBON => '0', RANDOMMISS => "0000",
      DISABLE_BOOTCOUNT => '0', DISABLE_DTLBMINI => '0',
      irqRequest => cpuIrq,
      LOCKSTEP_COUNT => LOCKSTEP_COUNT, COUNT_EXTERNAL => countExt, countTick => tick,
      IRQ_REPLAY => IRQ_REPLAY, irqReplayAt => irqReplayAt, dbg_issued => dbg_issued, dbg_retired => retired, dbg_pc => cpuPc,
      irqCartRequest => '0', cpuPaused => '0',
      error_instr => errors(0), error_stall => errors(1), error_FPU => errors(2),
      error_exception => errors(3), error_fifo => errors(4), error_TLB => errors(5),
      mem_request => mem_request, mem_rnw => mem_rnw, mem_address => mem_address,
      mem_req64 => mem_req64, mem_size => mem_size, mem_writeMask => mem_writeMask,
      mem_dataWrite => mem_dataWrite, mem_dataRead => mem_dataRead, mem_done => mem_done,
      rdram_granted2x => d_granted2x(DDR3_CPU), rdram_done => '0',
      ddr3_DOUT => ddr3_DOUT, ddr3_DOUT_READY => ddr3_DOUT_READY,
      ram_done => '0', ram_rnw => '0', ram_dataRead => (others => '0'),
-- synthesis translate_off
      cpu_done => cpu_done, cpu_export => cpu_export,
-- synthesis translate_on
      SS_reset => SS_reset, loading_savestate => '0',
      SS_DataWrite => SS_Data, SS_Adr => SS_Adr, SS_wren_CPU => SS_wren, SS_rden_CPU => '0',
      SS_DataRead_CPU => open, SS_idle => open
   );

   imemmux : entity work.webtv_memmux
   generic map (RAM_BASE => RAM_BASE, ROM_BASE => ROM_BASE)
   port map (
      clk1x => clk1x, reset => reset_1x, error => errors(7),
      mem_request => mem_request, mem_rnw => mem_rnw, mem_address => mem_address, mem_req64 => mem_req64,
      mem_size => mem_size, mem_writeMask => mem_writeMask, mem_dataWrite => mem_dataWrite,
      mem_dataRead => mem_dataRead, mem_done => mem_done,
      rdram_request => d_request(DDR3_CPU), rdram_rnw => d_rnw(DDR3_CPU), rdram_address => d_address(DDR3_CPU),
      rdram_burstcount => d_burst(DDR3_CPU), rdram_writeMask => d_mask(DDR3_CPU), rdram_dataWrite => d_data(DDR3_CPU),
      rdram_done => d_done(DDR3_CPU), rdram_dataRead => d_dataRead,
      bus_addr => m_addr, bus_read => m_read, bus_write => m_write, bus_be => m_be,
      bus_dataWrite => m_dataWrite, bus_dataRead => m_dataRead, bus_done => m_done
   );

   ---------------------------------------------------------------- SOLO system units
   s_sel   <= '1' when (m_addr(31 downto 16) = x"0400" and s_handles = '1') else '0';
   s_read  <= m_read and s_sel;
   s_write <= m_write and s_sel;
   v_sel   <= '1' when (m_addr(31 downto 16) = x"0400" and v_handles = '1') else '0';
   v_read  <= m_read and v_sel;
   v_write <= m_write and v_sel;

   bus_addr      <= m_addr;
   bus_be        <= m_be;
   bus_dataWrite <= m_dataWrite;
   i_sel   <= i_handles;
   -- IR receiver (in lock-step runs its reads stay on the replayed MMIO bus: key presses come from JS)
   r_sel   <= '1' when (m_addr(31 downto 16) = x"0400" and r_handles = '1' and LOCKSTEP_COUNT = '0') else '0';
   r_read  <= m_read and r_sel;
   r_write <= m_write and r_sel;
   -- modem UART (lock-step: replayed, its line side runs on JS time)
   u_sel   <= u_handles and not LOCKSTEP_COUNT;
   u_read  <= m_read and u_sel;
   u_write <= m_write and u_sel;
   i_read  <= m_read and i_sel;
   i_write <= m_write and i_sel;
   bus_read      <= m_read and not s_sel and not v_sel and not i_sel and not r_sel and not u_sel;
   bus_write     <= m_write and not s_sel and not v_sel and not i_sel and not r_sel and not u_sel;

   m_done     <= s_done or v_done or i_done or r_done or u_done or bus_done;
   m_dataRead <= s_dataRead when s_selRead = '1' else v_dataRead when v_selRead = '1' else
                 i_dataRead when i_selRead = '1' else r_dataRead when r_selRead = '1' else
                 u_dataRead when u_selRead = '1' else bus_dataRead;

   process (clk1x)
   begin
      if rising_edge(clk1x) then
         if (m_read = '1' or m_write = '1') then
            s_selRead  <= s_sel;
            v_selRead  <= v_sel;
            i_selRead  <= i_sel;
            r_selRead  <= r_sel;
            u_selRead  <= u_sel;
            s_wasRead  <= m_read;
            s_lastAddr <= m_addr;
         end if;
      end if;
   end process;

   dbg_solo_rd   <= ((s_done and s_selRead) or (v_done and v_selRead) or (i_done and i_selRead)) and s_wasRead;
   dbg_solo_addr <= s_lastAddr;
   dbg_solo_data <= s_dataRead when s_selRead = '1' else v_dataRead when v_selRead = '1' else i_dataRead;

   tcInc1 <= retired when LOCKSTEP_COUNT = '1' else '0';
   tcInc2 <= tick    when LOCKSTEP_COUNT = '0' else '0';

   cpuIrq   <= irqRequest when IRQ_EXTERNAL = '1' else soloIrq;
   solo_irq <= soloIrq;

   isolo : entity work.webtv_solo_sys
   port map (
      clk1x => clk1x, clk93 => clk93, reset => reset_1x, cold_reset => cold_reset,
      bus_addr => m_addr(15 downto 0), bus_read => s_read, bus_write => s_write, bus_be => m_be,
      bus_dataWrite => m_dataWrite, bus_dataRead => s_dataRead, bus_done => s_done, handles => s_handles,
      irq => soloIrq,
      modem7e_set => modem7e_set or uM7e,
      tc_inc1 => tcInc1, tc_inc2 => tcInc2,
      soft_reset => soft_reset, led => led, gpio_out => open, gpio_en => open,
      iic_cntl => iicCntl, iic_scl => iicScl, iic_sda => iicSda, serial_id => serial_id,
      dbg_tx => dbg_tx, dbg_tx_data => dbg_tx_data, dbg_rx => dbg_rx, dbg_rx_data => dbg_rx_data,
      vid_cleared => vidCleared, vid_load => vidLoad, vid_level => vidSum, vid_en_set => vidEnSet,
      dev_set => "00000" & irIrq & "00",
      -- (outside lock-step the RIO status bits stay latched until software clears them, as on the
      -- chip; the JS model lowers them with the device line, which lock-step runs must follow)
      rio_set => "0000" & ideSet & uSet & "00",
      rio_clr => ("0000" & ideClr & uClr & "00") and (7 downto 0 => LOCKSTEP_COUNT),
      rio_level => "0000" & ideLevel & uLevel & "00",
      init_we => solo_init_we, init_addr => solo_init_addr, init_data => solo_init_data
   );

   dbg_retired_cnt <= retCnt32;
   dbg_pc          <= pcR;
   dbg_scr         <= scrHist;
   dbg_ide         <= ideState & ideTotal & ideLastA & ideLastD & ideCnt;
   process (clk1x)
   begin
      if rising_edge(clk1x) then
         if (i_done = '1') then
            ideCnt   <= std_logic_vector(unsigned(ideCnt) + 1);
            ideLastA <= std_logic_vector(s_lastAddr(23 downto 8)) ;
            ideLastD <= std_logic_vector(s_lastAddr(7 downto 0)) & i_dataRead(7 downto 0);
         end if;
      end if;
   end process;
   trace_frozen    <= trFrozen;
   trace_wi        <= trWi;
   process (clk1x)
   begin
      if rising_edge(clk1x) then
         trace_q <= traceMem(to_integer(trace_ra));
      end if;
   end process;
   process (clk1x)
   begin
      if rising_edge(clk1x) then
         if (m_write = '1' and m_addr = x"1E00001C") then
            scrHist <= scrHist(127 downto 0) & m_dataWrite;
         end if;
      end if;
   end process;

   ---------------------------------------------------------------- IDE disk (RIO device 1)
   -- retired-instruction count (CPU clock) for the lock-step busy time
   process (clk93)
   begin
      if rising_edge(clk93) then
         if (retired = '1') then retCnt <= retCnt + 1; end if;
         if (retired = '1') then
            retCnt32 <= retCnt32 + 1; pcR <= cpuPc;
            trPrev   <= cpuPc;
            if (trFrozen = '0' and cpuPc /= trPrev + 4) then
               traceMem(to_integer(trWi)) <= std_logic_vector(retCnt32) & std_logic_vector(cpuPc);
               trWi <= trWi + 1;
               if (cpuPc(31 downto 7) = x"BFC003" & "1") then trFrozen <= '1'; end if;
            end if;
         end if;
         if (reset_93 = '1' and SS_reset = '1') then trFrozen <= '0'; end if;
      end if;
   end process;

   iide : entity work.webtv_ide
   port map (
      clk1x => clk1x, reset => reset_1x,
      bus_addr => m_addr, bus_read => i_read, bus_write => i_write, bus_dataWrite => m_dataWrite,
      bus_dataRead => i_dataRead, bus_done => i_done, handles => i_handles,
      irq_set => ideSet, irq_clr => ideClr, irq_level => ideLevel,
      LOCKSTEP => LOCKSTEP_COUNT, retired_cnt => retCnt,
      img_mounted => img_mounted, img_size => img_size,
      sd_lba => sd_lba, sd_blk_cnt => sd_blk_cnt, sd_rd => sd_rd, sd_wr => sd_wr, sd_ack => sd_ack,
      sd_buff_addr => sd_buff_addr, sd_buff_dout => sd_buff_dout, sd_buff_din => sd_buff_din, sd_buff_wr => sd_buff_wr,
      dbg_state => ideState, dbg_total => ideTotal,
      init_we => ide_init_we, init_addr => ide_init_addr, init_data => ide_init_data
   );

   ---------------------------------------------------------------- hardware modem UART (RIO device 0)
   iuart : entity work.webtv_uart16550
   generic map (CLK_HZ => CLK1X_HZ, BAUD => 115200)
   port map (
      clk1x => clk1x, reset => reset_1x,
      bus_addr => m_addr, bus_read => u_read, bus_write => u_write, bus_dataWrite => m_dataWrite,
      bus_dataRead => u_dataRead, bus_done => u_done, handles => u_handles,
      irq_set => uSet, irq_clr => uClr, irq_level => uLevel, modem7e => uM7e,
      line_txd => modem_txd, line_rxd => modem_rxd, line_dcd => modem_dcd, line_rts_n => modem_rts_n, mcr_out => modem_mcr
   );

   ---------------------------------------------------------------- IR receiver (devUnit, DEV_INT_IRIN)
   iir : entity work.webtv_ir
   generic map (CLK_HZ => CLK1X_HZ)
   port map (
      clk1x => clk1x, reset => reset_1x,
      bus_addr => m_addr(15 downto 0), bus_read => r_read, bus_write => r_write, bus_dataWrite => m_dataWrite,
      bus_dataRead => r_dataRead, bus_done => r_done, handles => r_handles,
      irq_set => irIrq,
      key_strobe => ir_key_strobe, key_code => ir_key_code, key_release => ir_key_release
   );

   ipixce : entity work.webtv_bustick
   generic map (CLK_HZ => CLK1X_HZ, TICK_HZ => PIX_HZ)
   port map (clk => clk1x, tick => pixCe);

   ivid : entity work.webtv_solo_vid
   port map (
      clk1x => clk1x, reset => reset_1x, pix_ce => pixCe, TIMING_EXTERNAL => LOCKSTEP_COUNT,
      bus_addr => m_addr(15 downto 0), bus_read => v_read, bus_write => v_write, bus_be => m_be,
      bus_dataWrite => m_dataWrite, bus_dataRead => v_dataRead, bus_done => v_done, handles => v_handles, req_read => m_read,
      sum_level => vidSum, sum_load => vidLoad, en_set => vidEnSet, vid_cleared => vidCleared(0) or vidCleared(1) or vidCleared(2) or vidCleared(3) or vidCleared(4) or vidCleared(5) or vidCleared(6) or vidCleared(7),
      hcount => open, vcount => open, hblank => vid_hblank, vblank => vid_vblank, hsync => vid_hsync, vsync => vid_vsync,
      frame_start => frameStart,
      pot_vstart => r_pot_vstart, pot_vsize => r_pot_vsize, pot_hstart => r_pot_hstart, pot_hsize => r_pot_hsize,
      pot_cntl => r_pot_cntl, pot_blankColor => r_pot_blnkcol, vid_nstart => r_vid_nstart, vid_dmacntl => r_vid_dmacntl,
      gfx_cntl => r_gfx_cntl, gfx_ymapbase_master => r_gfx_ymap, gfx_celsbase_master => r_gfx_cels,
      gfx_hcounterinit => r_gfx_hci, gfx_blanklines => r_gfx_bl, gfx_activelines => r_gfx_al,
      init_we => vid_init_we, init_addr => vid_init_addr, init_data => vid_init_data
   );

   ---------------------------------------------------------------- frame renderer (DDR3 client VIDEO)
   -- a frame is drawn at every vblank (skipped if the previous one is still being drawn) into the
   -- buffer that is not shown; when it is done, it becomes the shown one
   vid_ce     <= pixCe;
   fbDrawBase <= FB_BASE0 when fbDraw = '0' else FB_BASE1;
   rStart     <= frameStart and not rBusy;
   fb_display <= fbShown;

   irender : entity work.webtv_gfx_render
   generic map (RAM_BASE => RAM_BASE)
   port map (
      clk1x => clk1x, clk2x => clk2x, reset => reset_mem, start => rStart, busy => rBusy,
      fb_base => fbDrawBase,
      pot_vstart => r_pot_vstart, pot_vsize => r_pot_vsize, pot_hstart => r_pot_hstart, pot_hsize => r_pot_hsize,
      pot_cntl => r_pot_cntl, pot_blnkcol => r_pot_blnkcol, vid_nstart => r_vid_nstart, vid_dmacntl => r_vid_dmacntl,
      gfx_cntl => r_gfx_cntl, gfx_ymapbase_master => r_gfx_ymap, gfx_celsbase_master => r_gfx_cels,
      gfx_hcounterinit => r_gfx_hci, gfx_blanklines => r_gfx_bl, gfx_activelines => r_gfx_al,
      rdram_request => d_request(DDR3_VIDEO), rdram_rnw => d_rnw(DDR3_VIDEO), rdram_address => d_address(DDR3_VIDEO),
      rdram_burstcount => d_burst(DDR3_VIDEO), rdram_writeMask => d_mask(DDR3_VIDEO), rdram_dataWrite => d_data(DDR3_VIDEO),
      rdram_done => d_done(DDR3_VIDEO), rdram_granted2x => d_granted2x(DDR3_VIDEO),
      ddr3_DOUT => ddr3_DOUT, ddr3_DOUT_READY => ddr3_DOUT_READY,
      fbw_request => d_request(DDR3_FBW), fbw_address => d_address(DDR3_FBW), fbw_dataWrite => d_data(DDR3_FBW),
      fbw_done => d_done(DDR3_FBW)
   );
   d_rnw(DDR3_FBW)   <= '0';
   d_burst(DDR3_FBW) <= 10x"001";
   d_mask(DDR3_FBW)  <= x"FF";

   process (clk1x)
   begin
      if rising_edge(clk1x) then
         rBusy_1  <= rBusy;
         fb_frame <= '0';
         if (rBusy_1 = '1' and rBusy = '0') then
            if (fbDraw = '0') then fbShown <= FB_BASE0; else fbShown <= FB_BASE1; end if;
            fbDraw   <= not fbDraw;
            fb_frame <= '1';
         end if;
      end if;
   end process;

   iiic : entity work.webtv_iic
   port map (
      clk1x => clk1x, iic_cntl => iicCntl, scl_out => iicScl, sda_out => iicSda,
      init_we => iic_init_we, init_addr => iic_init_addr, init_data => iic_init_data
   );

   -- reserved clients (SOLO video / audio DMA)
   gidle : for i in DDR3_AUDIO to DDR3_AUDIO generate
      d_request(i) <= '0'; d_rnw(i) <= '1'; d_address(i) <= (others => '0'); d_burst(i) <= (others => '0');
      d_mask(i) <= (others => '0'); d_data(i) <= (others => '0');
   end generate;

   d_request(DDR3_HPS) <= hps_request;
   d_rnw(DDR3_HPS)     <= hps_rnw;
   d_address(DDR3_HPS) <= hps_address;
   d_burst(DDR3_HPS)   <= hps_burstcount;
   d_mask(DDR3_HPS)    <= hps_writeMask;
   d_data(DDR3_HPS)    <= hps_dataWrite;
   hps_done            <= d_done(DDR3_HPS);
   hps_dataRead        <= d_dataRead;

   iddr3mux : entity work.webtv_ddr3mux
   port map (
      clk1x => clk1x, clk2x => clk2x, reset => reset_mem, error => errors(6),
      ddr3_BUSY => ddr3_BUSY, ddr3_DOUT => ddr3_DOUT, ddr3_DOUT_READY => ddr3_DOUT_READY,
      ddr3_BURSTCNT => ddr3_BURSTCNT, ddr3_ADDR => ddr3_ADDR, ddr3_DIN => ddr3_DIN, ddr3_BE => ddr3_BE,
      ddr3_WE => ddr3_WE, ddr3_RD => ddr3_RD,
      rdram_request => d_request, rdram_rnw => d_rnw, rdram_address => d_address, rdram_burstcount => d_burst,
      rdram_writeMask => d_mask, rdram_dataWrite => d_data, rdram_granted2x => d_granted2x,
      rdram_done => d_done, rdram_dataRead => d_dataRead
   );

   ibustick : entity work.webtv_bustick
   generic map (CLK_HZ => CLK93_HZ)
   port map (clk => clk93, tick => tick);

end architecture;
