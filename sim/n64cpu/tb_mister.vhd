-----------------------------------------------------------------
-- tb_mister: the MiSTer glue (rtl/webtv/webtv_mister.vhd) as the board sees it
--
--  * downloads the boot ROM through the hps_io ioctl port (16 bit, WIDE) with ioctl_wait
--  * DDR3 model for the core's window (RAM, ROM, framebuffers), filled with garbage first
--  * checks the ROM image in DDR3 and the cleared RAM, then lets the CPU boot
--  * decodes the UART (debug serial) and prints lines; counts rendered frames
-----------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;

entity tb_mister is
   generic (
      rom_file     : string  := "../../ext/webtv-bridge/data/flipped_merged_boot.bin";
      ram_bytes    : integer := 65536;     -- RAM cleared by the glue (the full 8 MB takes long in sim)
      run_us       : integer := 20000;     -- simulated time after the CPU starts
      fast_load    : boolean := false;     -- put the ROM into the DDR3 model directly, download only 64 bytes
      ddr3_latency : integer := 12
   );
end entity;

architecture sim of tb_mister is
   signal clk1x  : std_logic := '0';
   signal clk93  : std_logic := '0';
   signal clk2x  : std_logic := '0';
   signal locked : std_logic := '0';
   signal reset  : std_logic := '0';

   signal ioctl_download, ioctl_wr, ioctl_wait : std_logic := '0';
   signal ioctl_addr : std_logic_vector(26 downto 0) := (others => '0');
   signal ioctl_dout : std_logic_vector(15 downto 0) := (others => '0');

   signal uart_txd, running, rom_loaded, fb_en : std_logic;
   signal fb_base : std_logic_vector(31 downto 0);
   signal errors  : std_logic_vector(7 downto 0);
   signal vid_ce, hb, vb, hs, vs : std_logic;

   signal ddr3_BUSY, ddr3_DOUT_READY, ddr3_WE, ddr3_RD : std_logic := '0';
   signal ddr3_DOUT, ddr3_DIN : std_logic_vector(63 downto 0) := (others => '0');
   signal ddr3_BURSTCNT, ddr3_BE : std_logic_vector(7 downto 0);
   signal ddr3_ADDR : std_logic_vector(28 downto 0);

   constant MEM_WORDS : integer := (16 * 1024 * 1024) / 8;
   constant ROM_WORD0 : integer := (8 * 1024 * 1024) / 8;
   type t_mem is array(natural range <>) of std_logic_vector(63 downto 0);
   shared variable mem : t_mem(0 to MEM_WORDS - 1) := (others => x"A5A5A5A5A5A5A5A5");
   shared variable rom : t_mem(0 to (2 * 1024 * 1024) / 8 - 1) := (others => (others => '0'));
   shared variable rom_bytes : integer := 0;

   constant BAUD_DIV : integer := (62500000 + 57600) / 115200;
   signal frames : integer := 0;
begin
   clk1x <= not clk1x after 24 ns;
   clk93 <= not clk93 after 16 ns;
   clk2x <= not clk2x after 12 ns;

   idut : entity work.webtv_mister
   generic map (RAM_BYTES => ram_bytes)
   port map (
      clk1x => clk1x, clk93 => clk93, clk2x => clk2x, pll_locked => locked, reset => reset,
      autoboot_y => '1',
      ioctl_download => ioctl_download, ioctl_index => x"00", ioctl_wr => ioctl_wr,
      ioctl_addr => ioctl_addr, ioctl_dout => ioctl_dout, ioctl_wait => ioctl_wait,
      uart_rxd => '1', uart_txd => uart_txd,
      running => running, rom_loaded => rom_loaded, led => open, errors => errors,
      fb_en => fb_en, fb_base => fb_base,
      vid_ce => vid_ce, vid_hblank => hb, vid_vblank => vb, vid_hsync => hs, vid_vsync => vs,
      ddr3_BUSY => ddr3_BUSY, ddr3_DOUT => ddr3_DOUT, ddr3_DOUT_READY => ddr3_DOUT_READY,
      ddr3_BURSTCNT => ddr3_BURSTCNT, ddr3_ADDR => ddr3_ADDR, ddr3_DIN => ddr3_DIN, ddr3_BE => ddr3_BE,
      ddr3_WE => ddr3_WE, ddr3_RD => ddr3_RD
   );

   -- HPS: download the ROM file
   process
      type char_file is file of character;
      file f : char_file;
      variable c : character;
      variable i : integer := 0;
      variable w : std_logic_vector(63 downto 0);
      variable lo : std_logic_vector(7 downto 0);
      variable bad : integer := 0;
   begin
      file_open(f, rom_file, read_mode);
      while not endfile(f) loop
         read(f, c);
         w := rom(i / 8);
         w(8 * (i mod 8) + 7 downto 8 * (i mod 8)) := std_logic_vector(to_unsigned(character'pos(c), 8));
         rom(i / 8) := w;
         i := i + 1;
      end loop;
      file_close(f);
      rom_bytes := i;
      wait for 500 ns;
      wait until rising_edge(clk1x);
      locked <= '1';
      for k in 0 to 20 loop wait until rising_edge(clk1x); end loop;

      if fast_load then
         for k in 0 to rom_bytes / 8 - 1 loop mem(ROM_WORD0 + k) := rom(k); end loop;
         i := 64;
      else
         i := rom_bytes;
      end if;
      report "download " & integer'image(i) & " bytes";
      ioctl_download <= '1';
      for a in 0 to i / 2 - 1 loop
         wait until rising_edge(clk1x);
         while ioctl_wait = '1' loop wait until rising_edge(clk1x); end loop;
         w := rom(a / 4);
         ioctl_addr <= std_logic_vector(to_unsigned(2 * a, 27));
         ioctl_dout <= w(16 * (a mod 4) + 15 downto 16 * (a mod 4));
         ioctl_wr   <= '1';
         wait until rising_edge(clk1x);
         ioctl_wr   <= '0';
         -- hps_io: a few cycles between words
         wait until rising_edge(clk1x);
      end loop;
      wait until rising_edge(clk1x);
      while ioctl_wait = '1' loop wait until rising_edge(clk1x); end loop;
      ioctl_download <= '0';
      report "download done";

      wait until running = '1';
      for k in 0 to rom_bytes / 8 - 1 loop
         if mem(ROM_WORD0 + k) /= rom(k) then bad := bad + 1; end if;
      end loop;
      report "ROM check: " & integer'image(bad) & " bad words";
      bad := 0;
      for k in 0 to ram_bytes / 8 - 1 loop
         if mem(k) /= x"0000000000000000" then bad := bad + 1; end if;
      end loop;
      report "RAM clear check: " & integer'image(bad) & " bad words";
      report "CPU running";

      wait for run_us * 1 us;
      report "end: " & integer'image(frames) & " frames, fb_en " & std_logic'image(fb_en) &
             ", fb_base " & to_hstring(fb_base) & ", errors " & to_hstring(errors);
      std.env.finish;
   end process;

   process(clk1x)
      variable fe : std_logic := '0';
   begin
      if rising_edge(clk1x) then
         if vs = '1' and fe = '0' then frames <= frames + 1; end if;
         fe := vs;
      end if;
   end process;

   -- UART decoder (debug serial)
   process
      variable l : line;
      variable b : std_logic_vector(7 downto 0);
   begin
      wait until falling_edge(uart_txd);
      for k in 1 to BAUD_DIV + BAUD_DIV / 2 loop wait until rising_edge(clk1x); end loop;
      for n in 0 to 7 loop
         b(n) := uart_txd;
         for k in 1 to BAUD_DIV loop wait until rising_edge(clk1x); end loop;
      end loop;
      assert uart_txd = '1' report "UART: bad stop bit" severity error;
      if b = x"0A" then
         report "[uart] " & l.all;
         deallocate(l);
      elsif b /= x"0D" then
         write(l, character'val(to_integer(unsigned(b))));
      end if;
   end process;

   -- DDR3 model
   process(clk2x)
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
         if ddr3_BUSY = '0' then
            if ddr3_RD = '1' then
               q_at(q_n) := now + ddr3_latency; q_addr(q_n) := to_integer(unsigned(ddr3_ADDR(24 downto 0)));
               q_cnt(q_n) := to_integer(unsigned(ddr3_BURSTCNT));
               q_n := q_n + 1;
            elsif ddr3_WE = '1' then
               assert ddr3_ADDR(28 downto 25) = "0011" report "DDR3 write outside the window" severity failure;
               w := to_integer(unsigned(ddr3_ADDR(24 downto 0)));
               d := mem(w);
               for b in 0 to 7 loop
                  if ddr3_BE(b) = '1' then d(8*b+7 downto 8*b) := ddr3_DIN(8*b+7 downto 8*b); end if;
               end loop;
               mem(w) := d;
            end if;
         end if;
         if q_n > 0 and now >= q_at(0) then
            ddr3_DOUT <= mem(q_addr(0) + beat);
            ddr3_DOUT_READY <= '1';
            beat := beat + 1;
            if beat = q_cnt(0) then
               beat := 0;
               for k in 0 to 14 loop q_at(k) := q_at(k+1); q_addr(k) := q_addr(k+1); q_cnt(k) := q_cnt(k+1); end loop;
               q_n := q_n - 1;
            end if;
         end if;
      end if;
   end process;
end architecture;
