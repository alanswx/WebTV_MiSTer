-- Lock-step testbench: N64_MiSTer CPU running the WebTV boot ROM.
--
-- Memory model (WebTV LC2 physical map):
--   0x00000000-0x03ffffff  8 MB RAM (mirrored)
--   0x1f800000-0x1fffffff  2 MB boot ROM (mirrored)
--   everything else        MMIO: reads are replayed from the JS reference (mmio_file:
--                          "<pa> <size> <value>" hex per line, in order), writes are logged
--
-- The N64 CPU's memory interface keeps bytes in address order inside a 64-bit word, lowest
-- address in bits 7:0 (see N64_MiSTer memorymux.vhd); the model follows that.
--
-- Output (trace_file), one line per retired instruction, same format as sim/trace.mjs:
--   <n> <pc32> <op32> [r<k>=<64>]... [hi=..] [lo=..] [MR:..] [MW:..]
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;

library work;
use work.pexport.all;
use ieee.math_real.all;

entity tb_cpu is
   generic (
      rom_file   : string  := "../../ext/webtv-bridge/data/flipped_merged_boot.bin";
      mmio_file  : string  := "out/mmio.txt";
      trace_file : string  := "out/rtl_trace.txt";
      max_instr  : integer := 100000;
      sr_reset   : integer := 16#00400004#;   -- BEV | ERL
      config_reset : integer := 16#00026033#; -- JS reset value with K0 = 3 (cached)
      snap_dir   : string  := "";      -- start from a JS snapshot (sim/trace.mjs --snapshot): ram.bin + ss.txt
      first_idx  : integer := 0;       -- instruction index printed for the first traced instruction
      lockstep   : std_logic := '1';   -- Count = retired instructions / 2, as in the JS model
      ddr3_latency  : integer := 12;   -- DDR3 model read latency (clk2x cycles)
      ddr3_busy_pct : integer := 0;    -- DDR3 model: % of cycles with BUSY (back-pressure test)
      irq_file   : string  := "";      -- "<idx> <lines>" per line: interrupt lines as seen before instruction idx
      hps_load   : boolean := false;
      solo_ev_file : string := "";     -- "<idx> <k> <hex>": SOLO interrupt state after instruction idx (S: in the JS trace)   -- write the boot ROM into DDR3 through the core's HPS loader port
      irqat_file : string  := ""       -- IRQ_REPLAY: one issue number per line (instruction an interrupt preempts)
   );
end entity;

architecture sim of tb_cpu is
   -- clocks: 1x : 93 : 2x = 2 : 3 : 4, with aligned edges
   signal clk1x  : std_logic := '0';
   signal clk93  : std_logic := '0';
   signal clk2x  : std_logic := '0';
   signal reset_1x, reset_93 : std_logic := '1';
   signal SS_reset : std_logic := '1';
   signal SS_wren  : std_logic := '0';
   signal SS_Adr   : unsigned(11 downto 0) := (others => '0');
   signal SS_Data  : std_logic_vector(63 downto 0) := (others => '0');

   signal ddr3_DOUT       : std_logic_vector(63 downto 0) := (others => '0');
   signal ddr3_DOUT_READY : std_logic := '0';

   signal cpu_done   : std_logic;
   signal cpu_export : cpu_export_type;
   signal errs       : std_logic_vector(5 downto 0);
   signal core_errs  : std_logic_vector(7 downto 0);
   signal hps_request, hps_done : std_logic := '0';
   -- SOLO system units
   signal solo_irq       : std_logic;
   signal solo_init_we   : std_logic := '0';
   signal solo_init_addr : unsigned(15 downto 0) := (others => '0');
   signal solo_init_data : std_logic_vector(31 downto 0) := (others => '0');
   signal iic_init_we    : std_logic := '0';
   signal vid_init_we    : std_logic := '0';
   signal modem7e_set    : std_logic := '0';
   signal dbg_solo_rd    : std_logic;
   signal dbg_solo_addr  : unsigned(31 downto 0);
   -- IDE disk model
   signal ide_init_we    : std_logic := '0';
   signal img_mounted    : std_logic := '0';
   signal img_size       : unsigned(63 downto 0) := (others => '0');
   signal sd_lba         : unsigned(31 downto 0);
   signal sd_blk_cnt     : unsigned(5 downto 0);
   signal sd_rd, sd_wr   : std_logic;
   signal sd_ack, sd_buff_wr : std_logic := '0';
   signal sd_buff_addr   : unsigned(12 downto 0) := (others => '0');
   signal sd_buff_dout   : std_logic_vector(15 downto 0) := (others => '0');
   signal dbg_solo_data  : std_logic_vector(31 downto 0);
   signal dbg_tx, dbg_rx : std_logic := '0';
   signal dbg_tx_data, dbg_rx_data : std_logic_vector(7 downto 0) := (others => '0');
   signal solo_rd_bad    : integer := 0;
   signal hps_address : unsigned(27 downto 0) := (others => '0');
   signal hps_data    : std_logic_vector(63 downto 0) := (others => '0');
   signal irq_line   : std_logic := '0';
   signal irq_replay : std_logic := '0';
   signal replay_at  : unsigned(31 downto 0) := (others => '1');
   signal dbg_issued : unsigned(31 downto 0);

   -- WebTV memory system
   signal bus_tick : std_logic;
   signal ddr3_BUSY  : std_logic := '0';
   signal ddr3_BURSTCNT : std_logic_vector(7 downto 0);
   signal ddr3_ADDR  : std_logic_vector(28 downto 0);
   signal ddr3_DIN   : std_logic_vector(63 downto 0);
   signal ddr3_BE    : std_logic_vector(7 downto 0);
   signal ddr3_WE, ddr3_RD, ddr3_error : std_logic;
   signal bus_addr   : unsigned(31 downto 0);
   signal bus_read, bus_write, bus_done : std_logic := '0';
   signal bus_be     : std_logic_vector(3 downto 0);
   signal bus_dataWrite, bus_dataRead : std_logic_vector(31 downto 0) := (others => '0');

   -- MMIO log for the trace line of the next retired instruction
   shared variable mmio_log : line;

   -- queue of raw SOLO state loads (snapshot + forced interrupt state), drained on clk1x;
   -- addr 16#FFFF# pulses modem7e_set
   type t_iq is array(0 to 4095) of integer;
   shared variable iq_addr, iq_data_hi, iq_data_lo : t_iq;
   shared variable iq_head, iq_tail : integer := 0;
   procedure iq_push(a : integer; d : std_logic_vector(31 downto 0)) is
   begin
      iq_addr(iq_tail mod 4096) := a;
      iq_data_hi(iq_tail mod 4096) := to_integer(unsigned(d(31 downto 16)));
      iq_data_lo(iq_tail mod 4096) := to_integer(unsigned(d(15 downto 0)));
      iq_tail := iq_tail + 1;
   end procedure;

   constant RAM_WORDS : integer := (8 * 1024 * 1024) / 8;
   constant ROM_WORDS : integer := (2 * 1024 * 1024) / 8;
   type t_mem is array(natural range <>) of std_logic_vector(63 downto 0);
   shared variable ram : t_mem(0 to RAM_WORDS-1) := (others => (others => '0'));
   shared variable rom : t_mem(0 to ROM_WORDS-1) := (others => (others => '0'));

   function to_lower(s : string) return string is
      variable r : string(s'range) := s;
   begin
      for i in s'range loop
         if s(i) >= 'A' and s(i) <= 'F' then r(i) := character'val(character'pos(s(i)) + 32); end if;
      end loop;
      return r;
   end function;
   function hex(v : std_logic_vector) return string is
   begin
      return to_lower(to_hstring(v));
   end function;

   impure function is_ram(a : unsigned) return boolean is begin return a < x"04000000"; end function;
   impure function is_rom(a : unsigned) return boolean is begin return a >= x"1F800000"; end function;

   impure function mem_word(a : unsigned(31 downto 0)) return std_logic_vector is
   begin
      if is_ram(a) then return ram(to_integer(a(22 downto 3)));
      elsif is_rom(a) then return rom(to_integer(a(20 downto 3)));
      else return x"DEADBEEFDEADBEEF";
      end if;
   end function;
begin
   clk1x <= not clk1x after 24 ns;
   clk93 <= not clk93 after 16 ns;
   clk2x <= not clk2x after 12 ns;

   icore : entity work.webtv_core
   port map (
      clk1x => clk1x, clk93 => clk93, clk2x => clk2x,
      reset_1x => reset_1x, reset_93 => reset_93, reset_mem => '0',
      irqRequest => irq_line, IRQ_EXTERNAL => '1', solo_irq => solo_irq,
      dbg_tx => dbg_tx, dbg_tx_data => dbg_tx_data, dbg_rx => dbg_rx, dbg_rx_data => dbg_rx_data,
      modem7e_set => modem7e_set,
      solo_init_we => solo_init_we, solo_init_addr => solo_init_addr, solo_init_data => solo_init_data,
      iic_init_we => iic_init_we, iic_init_addr => solo_init_addr, iic_init_data => solo_init_data,
      vid_init_we => vid_init_we, vid_init_addr => solo_init_addr, vid_init_data => solo_init_data,
      ide_init_we => ide_init_we, ide_init_addr => solo_init_addr, ide_init_data => solo_init_data,
      img_mounted => img_mounted, img_size => img_size,
      sd_lba => sd_lba, sd_blk_cnt => sd_blk_cnt, sd_rd => sd_rd, sd_wr => sd_wr, sd_ack => sd_ack,
      sd_buff_addr => sd_buff_addr, sd_buff_dout => sd_buff_dout, sd_buff_din => open, sd_buff_wr => sd_buff_wr,
      dbg_solo_rd => dbg_solo_rd, dbg_solo_addr => dbg_solo_addr, dbg_solo_data => dbg_solo_data,
      bus_addr => bus_addr, bus_read => bus_read, bus_write => bus_write, bus_be => bus_be,
      bus_dataWrite => bus_dataWrite, bus_dataRead => bus_dataRead, bus_done => bus_done,
      bus_tick => bus_tick,
      hps_request => hps_request, hps_rnw => '0', hps_address => hps_address, hps_burstcount => 10x"001",
      hps_writeMask => x"FF", hps_dataWrite => hps_data, hps_done => hps_done, hps_dataRead => open,
      ddr3_BUSY => ddr3_BUSY, ddr3_DOUT => ddr3_DOUT, ddr3_DOUT_READY => ddr3_DOUT_READY,
      ddr3_BURSTCNT => ddr3_BURSTCNT, ddr3_ADDR => ddr3_ADDR, ddr3_DIN => ddr3_DIN, ddr3_BE => ddr3_BE,
      ddr3_WE => ddr3_WE, ddr3_RD => ddr3_RD,
      errors => core_errs,
      SS_reset => SS_reset, SS_wren => SS_wren, SS_Adr => SS_Adr, SS_Data => SS_Data,
      LOCKSTEP_COUNT => lockstep, IRQ_REPLAY => irq_replay, irqReplayAt => replay_at,
      dbg_issued => dbg_issued, cpu_done => cpu_done, cpu_export => cpu_export
   );
   errs <= core_errs(5 downto 0);

   ---------------------------------------------------------------- reset / init
   process
      type char_file is file of character;
      file f : char_file;
      variable c : character;
      variable i : integer := 0;
      variable w : std_logic_vector(63 downto 0);
      file sf : text;
      variable sl : line;
      variable slot : integer;
      variable sval : std_logic_vector(63 downto 0);
      variable fst  : file_open_status;
   begin
      file_open(f, rom_file, read_mode);
      while not endfile(f) and i < ROM_WORDS * 8 loop
         read(f, c);
         w := rom(i / 8);
         w(8 * (i mod 8) + 7 downto 8 * (i mod 8)) := std_logic_vector(to_unsigned(character'pos(c), 8));
         rom(i / 8) := w;
         i := i + 1;
      end loop;
      file_close(f);
      report "loaded " & integer'image(i) & " ROM bytes";

      if hps_load then
         -- move the image into DDR3 through the loader client (ROM at window offset 8 MB)
         wait for 200 ns;
         for k in 0 to (i + 7) / 8 - 1 loop
            wait until rising_edge(clk1x);
            hps_address <= to_unsigned(16#800000# + 8 * k, 28);
            hps_data    <= rom(k);
            rom(k)      := x"DEADBEEFDEADBEEF";      -- the model must now serve what was written
            hps_request <= '1';
            wait until rising_edge(clk1x);
            hps_request <= '0';
            while hps_done = '0' loop wait until rising_edge(clk1x); end loop;
         end loop;
         report "HPS loader wrote " & integer'image((i + 7) / 8) & " ROM words";
      end if;

      if snap_dir /= "" then
         file_open(f, snap_dir & "/ram.bin", read_mode);
         i := 0;
         while not endfile(f) and i < RAM_WORDS * 8 loop
            read(f, c);
            w := ram(i / 8);
            w(8 * (i mod 8) + 7 downto 8 * (i mod 8)) := std_logic_vector(to_unsigned(character'pos(c), 8));
            ram(i / 8) := w;
            i := i + 1;
         end loop;
         file_close(f);
         report "loaded " & integer'image(i) & " RAM bytes from " & snap_dir;
      end if;

      wait for 200 ns;
      wait until rising_edge(clk93);
      SS_reset <= '0';
      -- reset values for CP0 Status and Config (savestate slots 12 / 16)
      SS_Adr <= to_unsigned(64 + 12, 12); SS_Data <= std_logic_vector(to_unsigned(sr_reset, 64)); SS_wren <= '1';
      wait until rising_edge(clk93);
      SS_Adr <= to_unsigned(64 + 16, 12); SS_Data <= std_logic_vector(to_unsigned(config_reset, 64));
      wait until rising_edge(clk93);
      SS_Adr <= to_unsigned(64 + 11, 12); SS_Data <= x"00000000FFFFFFFF"; -- Compare (JS resets it to -1)
      wait until rising_edge(clk93);
      SS_wren <= '0';
      if snap_dir /= "" then
         -- let the CPU's register-file clear after SS_reset finish, then load the snapshot
         for k in 0 to 40 loop wait until rising_edge(clk93); end loop;
         file_open(sf, snap_dir & "/ss.txt", read_mode);
         while not endfile(sf) loop
            readline(sf, sl);
            read(sl, slot);
            hread(sl, sval);
            SS_Adr <= to_unsigned(slot, 12); SS_Data <= sval; SS_wren <= '1';
            wait until rising_edge(clk93);
         end loop;
         file_close(sf);
         SS_wren <= '0';
         -- SOLO system-unit state, IIC bus devices (addresses + 0x10000 in the queue)
         file_open(sf, snap_dir & "/solo.txt", read_mode);
         while not endfile(sf) loop
            readline(sf, sl);
            hread(sl, sval(15 downto 0));
            hread(sl, sval(63 downto 32));
            iq_push(to_integer(unsigned(sval(15 downto 0))), sval(63 downto 32));
         end loop;
         file_close(sf);
         file_open(sf, snap_dir & "/vid.txt", read_mode);
         while not endfile(sf) loop
            readline(sf, sl);
            hread(sl, sval(15 downto 0));
            hread(sl, sval(63 downto 32));
            iq_push(16#20000# + to_integer(unsigned(sval(15 downto 0))), sval(63 downto 32));
         end loop;
         file_close(sf);
         file_open(sf, snap_dir & "/iic.txt", read_mode);
         while not endfile(sf) loop
            readline(sf, sl);
            hread(sl, sval(15 downto 0));
            hread(sl, sval(63 downto 32));
            iq_push(16#10000# + to_integer(unsigned(sval(15 downto 0))), sval(63 downto 32));
            -- drain as we go: the queue is smaller than the IIC memory
            while iq_tail - iq_head > 3000 loop wait until rising_edge(clk1x); end loop;
         end loop;
         file_close(sf);
         -- IDE state (fff0 = image size in sectors); the size goes first so the drive is present
         file_open(fst, sf, snap_dir & "/ide.txt", read_mode);
         if fst = open_ok then
            while not endfile(sf) loop
               readline(sf, sl);
               hread(sl, sval(15 downto 0));
               hread(sl, sval(63 downto 32));
               iq_push(16#30000# + to_integer(unsigned(sval(15 downto 0))), sval(63 downto 32));
               while iq_tail - iq_head > 3000 loop wait until rising_edge(clk1x); end loop;
            end loop;
            file_close(sf);
         end if;
         while iq_tail > iq_head loop wait until rising_edge(clk1x); end loop;
      end if;
      for k in 0 to 40 loop wait until rising_edge(clk93); end loop;
      wait until rising_edge(clk1x);
      reset_1x <= '0';
      reset_93 <= '0';
      wait;
   end process;

   -- DDR3 model (MiSTer ddr3 port: Avalon-MM, 64 bit, read latency ddr3_latency clk2x cycles)
   process(clk2x)
      variable seed1, seed2 : positive := 7;
      variable rnd : real;
      type t_pending is array(0 to 15) of integer;
      variable q_at, q_addr, q_cnt : t_pending;
      variable q_n : integer := 0;
      variable now : integer := 0;
      variable beat : integer := 0;
      variable w : integer;
      variable d : std_logic_vector(63 downto 0);
   begin
      if rising_edge(clk2x) then
         now := now + 1;
         ddr3_DOUT_READY <= '0';
         -- accept a command
         if ddr3_BUSY = '0' then
            if ddr3_RD = '1' then
               assert q_n < 16 report "DDR3 model: too many reads" severity failure;
               q_at(q_n) := now + ddr3_latency; q_addr(q_n) := to_integer(unsigned(ddr3_ADDR(24 downto 0)));
               q_cnt(q_n) := to_integer(unsigned(ddr3_BURSTCNT));
               q_n := q_n + 1;
            elsif ddr3_WE = '1' then
               w := to_integer(unsigned(ddr3_ADDR(24 downto 0)));
               if w < RAM_WORDS then d := ram(w);
               elsif w - RAM_WORDS < ROM_WORDS then d := rom(w - RAM_WORDS);
               end if;
               for b in 0 to 7 loop
                  if ddr3_BE(b) = '1' then d(8*b+7 downto 8*b) := ddr3_DIN(8*b+7 downto 8*b); end if;
               end loop;
               if w < RAM_WORDS then ram(w) := d;
               elsif w - RAM_WORDS < ROM_WORDS then rom(w - RAM_WORDS) := d;
               end if;
            end if;
         end if;
         -- return read data, one beat per cycle, in order
         if q_n > 0 and now >= q_at(0) then
            w := q_addr(0) + beat;
            if w < RAM_WORDS then ddr3_DOUT <= ram(w);
            elsif w - RAM_WORDS < ROM_WORDS then ddr3_DOUT <= rom(w - RAM_WORDS);
            else ddr3_DOUT <= x"DEADBEEFDEADBEEF"; end if;
            ddr3_DOUT_READY <= '1';
            beat := beat + 1;
            if beat = q_cnt(0) then
               beat := 0;
               for k in 0 to 14 loop q_at(k) := q_at(k+1); q_addr(k) := q_addr(k+1); q_cnt(k) := q_cnt(k+1); end loop;
               q_n := q_n - 1;
            end if;
         end if;
         -- random command back-pressure
         ddr3_BUSY <= '0';
         if ddr3_busy_pct > 0 then
            uniform(seed1, seed2, rnd);
            if rnd * 100.0 < real(ddr3_busy_pct) then ddr3_BUSY <= '1'; end if;
         end if;
      end if;
   end process;

   -- SOLO raw-load queue (clk1x)
   process(clk1x)
   begin
      if rising_edge(clk1x) then
         solo_init_we <= '0';
         iic_init_we  <= '0';
         vid_init_we  <= '0';
         ide_init_we  <= '0';
         img_mounted  <= '0';
         modem7e_set  <= '0';
         if iq_head < iq_tail then
            if iq_addr(iq_head mod 4096) = 16#FFFF# then
               modem7e_set <= '1';
            elsif iq_addr(iq_head mod 4096) = 16#3FFF0# then
               -- IDE image size (sectors)
               img_mounted <= '1';
               img_size <= shift_left(to_unsigned(iq_data_hi(iq_head mod 4096), 48) * 65536 +
                                      to_unsigned(iq_data_lo(iq_head mod 4096), 64), 9)(63 downto 0);
            else
               if iq_addr(iq_head mod 4096) >= 16#30000# then ide_init_we <= '1';
               elsif iq_addr(iq_head mod 4096) >= 16#20000# then vid_init_we <= '1';
               elsif iq_addr(iq_head mod 4096) >= 16#10000# then iic_init_we <= '1';
               else solo_init_we <= '1'; end if;
               solo_init_addr <= to_unsigned(iq_addr(iq_head mod 4096) mod 65536, 16);
               solo_init_data <= std_logic_vector(to_unsigned(iq_data_hi(iq_head mod 4096), 16)) &
                                 std_logic_vector(to_unsigned(iq_data_lo(iq_head mod 4096), 16));
            end if;
            iq_head := iq_head + 1;
         end if;
      end if;
   end process;

   -- debug serial: print lines, answer 'y' to "Disk Boot?" (as sim/trace.mjs does)
   process(clk1x)
      variable dl : line;
      variable last : string(1 to 10) := (others => ' ');
   begin
      if rising_edge(clk1x) then
         dbg_rx <= '0';
         if dbg_tx = '1' then
            if dbg_tx_data = x"0A" then
               report "[dbg] " & last;
            elsif dbg_tx_data /= x"0D" then
               last := last(2 to 10) & character'val(to_integer(unsigned(dbg_tx_data)));
               if last = "Disk Boot?" then
                  dbg_rx <= '1'; dbg_rx_data <= x"79";
               end if;
            end if;
         end if;
      end if;
   end process;

   -- IDE disk model (hps_io block device): serves the sectors the JS run read (snap_dir/disk.txt)
   process
      file df : text;
      variable fst : file_open_status;
      variable dl : line;
      variable lba : std_logic_vector(31 downto 0);
      variable sec : std_logic_vector(4095 downto 0);
      variable a : integer;
      variable opened : boolean := false;
   begin
      wait until rising_edge(clk1x) and (sd_rd = '1' or sd_wr = '1');
      if sd_wr = '1' then
         report "IDE disk model: write of LBA " & hex(std_logic_vector(sd_lba)) & " (ignored)" severity warning;
         sd_ack <= '1';
         for k in 0 to 300 * (to_integer(sd_blk_cnt) + 1) loop wait until rising_edge(clk1x); end loop;
         sd_ack <= '0';
      else
         if not opened then
            file_open(fst, df, snap_dir & "/disk.txt", read_mode);
            assert fst = open_ok report "IDE disk model: no disk.txt" severity failure;
            opened := true;
         end if;
         report "IDE disk model: read LBA " & hex(std_logic_vector(sd_lba)) & " x" & integer'image(to_integer(sd_blk_cnt) + 1) &
                " at issue " & integer'image(to_integer(dbg_issued));
         sd_ack <= '1';
         a := 0;
         for b in 0 to to_integer(sd_blk_cnt) loop
            assert not endfile(df) report "IDE disk model: disk.txt exhausted" severity failure;
            readline(df, dl);
            hread(dl, lba);
            hread(dl, sec);
            if unsigned(lba) /= sd_lba + b then
               report "IDE disk model: read of LBA " & hex(std_logic_vector(sd_lba + b)) & ", reference read " & hex(lba) severity error;
            end if;
            for k in 0 to 255 loop
               wait until rising_edge(clk1x);
               -- word k = byte 2k | byte 2k+1 << 8 (sec holds the bytes in order, first byte at the top)
               sd_buff_addr <= to_unsigned(a, 13);
               sd_buff_dout(15 downto 8) <= sec(4095 - 16 * k - 8 downto 4095 - 16 * k - 15);
               sd_buff_dout(7 downto 0)  <= sec(4095 - 16 * k downto 4095 - 16 * k - 7);
               sd_buff_wr   <= '1';
               wait until rising_edge(clk1x);
               sd_buff_wr   <= '0';
               a := a + 1;
            end loop;
         end loop;
         wait until rising_edge(clk1x);
         sd_ack <= '0';
         report "IDE disk model: done at issue " & integer'image(to_integer(dbg_issued));
      end if;
   end process;

   -- MMIO bus model
   process(clk1x)
      file mf : text open read_mode is mmio_file;
      variable l : line;
      variable m_pa, m_sz, m_val : std_logic_vector(31 downto 0);
      variable sz, o, cnt : integer;
      variable v : std_logic_vector(31 downto 0);
      variable wait_cnt : integer := -1;
      variable first : integer;
   begin
      if rising_edge(clk1x) then
         bus_done <= '0';
         if dbg_solo_rd = '1' then
            -- read answered by the RTL SOLO: check it against the reference
            if endfile(mf) then
               report "MMIO replay file exhausted at SOLO read" severity failure;
            end if;
            readline(mf, l);
            hread(l, m_pa); hread(l, m_sz); hread(l, m_val);
            sz := to_integer(unsigned(m_sz));
            o  := to_integer(unsigned(m_pa(1 downto 0)));
            v  := std_logic_vector(shift_left(unsigned(m_val), 8 * (4 - sz - o)));
            first := 0;
            for b in 0 to 3 loop
               if b >= 4 - o - sz and b < 4 - o then
                  if dbg_solo_data(8*b+7 downto 8*b) /= v(8*b+7 downto 8*b) then first := 1; end if;
               end if;
            end loop;
            if unsigned(m_pa(31 downto 2)) /= dbg_solo_addr(31 downto 2) then
               report "SOLO read address mismatch: rtl " & hex(std_logic_vector(dbg_solo_addr)) & " ref " & hex(m_pa) severity warning;
               solo_rd_bad <= solo_rd_bad + 1;
            elsif first = 1 then
               report "SOLO read " & hex(m_pa) & ": rtl " & hex(dbg_solo_data) & " ref " & hex(v) severity warning;
               solo_rd_bad <= solo_rd_bad + 1;
            end if;
            write(mmio_log, " MR:" & hex(m_pa) & "/" & integer'image(sz) & "=" & hex(m_val));
         end if;
         if bus_read = '1' then
            if endfile(mf) then
               report "MMIO replay file exhausted at read of " & hex(std_logic_vector(bus_addr)) severity failure;
            end if;
            readline(mf, l);
            hread(l, m_pa); hread(l, m_sz); hread(l, m_val);
            if unsigned(m_pa(31 downto 2)) /= bus_addr(31 downto 2) then
               report "MMIO read address mismatch: rtl " & hex(std_logic_vector(bus_addr)) & " ref " & hex(m_pa) severity warning;
            end if;
            sz := to_integer(unsigned(m_sz));
            o  := to_integer(unsigned(m_pa(1 downto 0)));
            -- place the reference's right-aligned value at its byte lanes of the big-endian word
            v := std_logic_vector(shift_left(unsigned(m_val), 8 * (4 - sz - o)));
            bus_dataRead <= v;
            write(mmio_log, " MR:" & hex(m_pa) & "/" & integer'image(sz) & "=" & hex(m_val));
            wait_cnt := 2;
         elsif bus_write = '1' then
            cnt := 0; first := -1; v := (others => '0');
            for b in 3 downto 0 loop            -- bus_be(3) = byte offset 0
               if bus_be(b) = '1' then
                  if first < 0 then first := 3 - b; end if;
                  cnt := cnt + 1;
                  v := v(23 downto 0) & bus_dataWrite(8*b+7 downto 8*b);
               end if;
            end loop;
            write(mmio_log, " MW:" & hex(std_logic_vector(bus_addr + to_unsigned(first, 32))) & "/" & integer'image(cnt) & "=" & hex(v));
            wait_cnt := 2;
         end if;
         if wait_cnt = 0 then bus_done <= '1'; end if;
         if wait_cnt >= 0 then wait_cnt := wait_cnt - 1; end if;
      end if;
   end process;

   ---------------------------------------------------------------- interrupt replay targets
   irq_replay <= '1' when irqat_file /= "" else '0';
   process(clk93)
      file af : text;
      variable al : line;
      variable v : integer;
      variable opened : boolean := false;
   begin
      if rising_edge(clk93) then
         if not opened and irqat_file /= "" then
            file_open(af, irqat_file, read_mode);
            opened := true;
            if not endfile(af) then readline(af, al); read(al, v); replay_at <= to_unsigned(v, 32); end if;
         elsif opened and dbg_issued > replay_at and replay_at /= x"FFFFFFFF" then
            if not endfile(af) then readline(af, al); read(al, v); replay_at <= to_unsigned(v, 32);
            else replay_at <= (others => '1'); end if;
         end if;
      end if;
   end process;

   ---------------------------------------------------------------- trace writer
   process(clk93)
      file tf : text open write_mode is trace_file;
      variable l : line;
      variable n : integer := 0;
      variable prev : cpu_export_type := export_init;
      variable started : boolean := false;
      file irqf : text;
      variable irql : line;
      variable irq_open : boolean := false;
      variable irq_next_idx : integer := -1;
      variable irq_next_val : integer := 0;
      -- IRQ_REPLAY: the preempted instruction still shows up as an export (one per issued
      -- instruction); the JS model never ran it there, so it is left out of the trace
      file skf : text;
      variable skl : line;
      variable sk_open : boolean := false;
      variable sk_next : integer := -1;
      variable exports : integer := 0;
      file evf : text;
      variable evl : line;
      variable ev_open : boolean := false;
      variable ev_idx : integer := -1;
      variable ev_key : character;
      variable ev_val : std_logic_vector(31 downto 0);
      variable irq_bad_run, irq_bad_total, irq_bad_reported : integer := 0;
      impure function ev_fetch return boolean is
         variable c : character;
      begin
         if endfile(evf) then ev_idx := -1; return false; end if;
         readline(evf, evl);
         read(evl, ev_idx);
         read(evl, c);       -- space
         read(evl, ev_key);
         hread(evl, ev_val);
         return true;
      end function;
      impure function irq_fetch return boolean is
      begin
         if endfile(irqf) then irq_next_idx := -1; return false; end if;
         readline(irqf, irql);
         read(irql, irq_next_idx);
         read(irql, irq_next_val);
         return true;
      end function;
   begin
      if rising_edge(clk93) then
         if not irq_open and irq_file /= "" then
            file_open(irqf, irq_file, read_mode);
            irq_open := true;
            -- lines as they were before the first traced instruction
            while irq_fetch and irq_next_idx <= first_idx loop
               if irq_next_val mod 2 = 1 then irq_line <= '1'; else irq_line <= '0'; end if;
            end loop;
         end if;
         if not ev_open and solo_ev_file /= "" then
            file_open(evf, solo_ev_file, read_mode);
            ev_open := true;
            if not ev_fetch then null; end if;
         end if;
         -- (the RTL no longer exports a preempted instruction: nothing to skip)
         if false and not sk_open and irqat_file /= "" then
            file_open(skf, irqat_file, read_mode);
            sk_open := true;
            if not endfile(skf) then readline(skf, skl); read(skl, sk_next); end if;
         end if;
         if cpu_done = '1' and started and exports = sk_next then
            exports := exports + 1;
            sk_next := -1;
            if not endfile(skf) then readline(skf, skl); read(skl, sk_next); end if;
            prev := cpu_export;
         elsif cpu_done = '1' then
            if started then exports := exports + 1; end if;
            -- the line changes the reference saw before the next instruction
            if started and irq_next_idx = first_idx + n + 1 then
               if irq_next_val mod 2 = 1 then irq_line <= '1'; else irq_line <= '0'; end if;
               if not irq_fetch then null; end if;
            end if;
            if started then
               write(l, integer'image(first_idx + n) & " " & hex(std_logic_vector(cpu_export.pc(31 downto 0))) & " " & hex(std_logic_vector(cpu_export.opcode)));
               for r in 1 to 31 loop
                  if cpu_export.regs(r) /= prev.regs(r) then
                     write(l, " r" & integer'image(r) & "=" & hex(std_logic_vector(cpu_export.regs(r))));
                  end if;
               end loop;
               if cpu_export.hi /= prev.hi then write(l, " hi=" & hex(std_logic_vector(cpu_export.hi))); end if;
               if cpu_export.lo /= prev.lo then write(l, " lo=" & hex(std_logic_vector(cpu_export.lo))); end if;
               if mmio_log /= null then write(l, mmio_log.all); deallocate(mmio_log); end if;
               writeline(tf, l);
               -- SOLO interrupt state the reference had after this instruction
               while ev_open and ev_idx = n loop
                  case ev_key is
                     when 'g' => iq_push(16#58#, ev_val);
                     when 'a' => iq_push(16#68#, ev_val);
                     when 'd' => iq_push(16#74#, ev_val);
                     when 'v' => iq_push(16#80#, ev_val);
                     when 'r' => iq_push(16#F8C#, ev_val);   -- the IDE bit is the RTL's
                     when 'm' => if ev_val(0) = '1' then iq_push(16#FFFF#, ev_val); end if;
                     when others => null;   -- 't': the RTL timer makes its own
                  end case;
                  if not ev_fetch then null; end if;
               end loop;
               -- the SOLO's interrupt output against the reference's line (a few instructions of
               -- lag are normal: forced state lands when the instruction retires)
               if solo_irq /= irq_line then
                  irq_bad_run := irq_bad_run + 1;
                  if irq_bad_run = 6 then
                     irq_bad_total := irq_bad_total + 1;
                     if irq_bad_reported < 20 then
                        report "SOLO irq " & std_logic'image(solo_irq) & " but JS IRQL " & std_logic'image(irq_line) & " since instruction " & integer'image(first_idx + n - 5) severity warning;
                        irq_bad_reported := irq_bad_reported + 1;
                     end if;
                  end if;
               else
                  irq_bad_run := 0;
               end if;
               n := n + 1;
            end if;
            started := true;
            prev := cpu_export;
            if n >= max_instr then
               report "done: " & integer'image(n) & " instructions; SOLO read mismatches " & integer'image(solo_rd_bad) &
                      ", SOLO irq mismatches " & integer'image(irq_bad_total) severity note;
               std.env.finish;
            end if;
         end if;
         if errs /= "000000" then
            report "CPU error flags " & to_string(errs) severity failure;
         end if;
      end if;
   end process;
end architecture;
