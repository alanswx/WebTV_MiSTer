-- Frame renderer testbench: renders one frame captured by sim/frame.mjs and writes it as a PPM.
--   frame_dir/ram.bin   8 MB box RAM (address order)
--   frame_dir/regs.hex  register values, one hex word per line, in the order below (render_test.sh)
-- The renderer runs through webtv_ddr3mux (client VIDEO) into a DDR3 model: box RAM at window
-- offset 0, framebuffer at 8 MB.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;

library work;
use work.pWebTVDDR3.all;

entity tb_render is
   generic (
      frame_dir    : string  := "../out/frame_3000000000/0";
      out_file     : string  := "out/render.ppm";
      ddr3_latency : integer := 12
   );
end entity;

architecture sim of tb_render is
   signal clk1x  : std_logic := '0';
   signal clk2x  : std_logic := '0';
   signal reset  : std_logic := '1';

   constant RAM_WORDS : integer := (8 * 1024 * 1024) / 8;
   constant FB_WORDS  : integer := 640 * 480 / 2;
   constant FB_BASE   : integer := 16#800000#;
   type t_mem is array(natural range <>) of std_logic_vector(63 downto 0);
   shared variable mem : t_mem(0 to RAM_WORDS + FB_WORDS - 1) := (others => (others => '0'));

   type t_regs is array(0 to 13) of std_logic_vector(31 downto 0);
   signal regs : t_regs := (others => (others => '0'));

   signal start, busy : std_logic := '0';
   signal d_request, d_rnw, d_granted2x, d_done : tDDR3Single := (others => '0');
   signal d_address  : tDDR3Addr := (others => (others => '0'));
   signal d_burst    : tDDR3Burst := (others => (others => '0'));
   signal d_mask     : tDDR3Mask := (others => (others => '0'));
   signal d_data     : tDDR3Data := (others => (others => '0'));
   signal d_dataRead : std_logic_vector(63 downto 0);
   signal ddr3_BUSY, ddr3_DOUT_READY, ddr3_WE, ddr3_RD : std_logic := '0';
   signal ddr3_DOUT, ddr3_DIN : std_logic_vector(63 downto 0) := (others => '0');
   signal ddr3_BURSTCNT, ddr3_BE : std_logic_vector(7 downto 0);
   signal ddr3_ADDR : std_logic_vector(28 downto 0);
begin
   clk1x <= not clk1x after 8 ns;
   clk2x <= not clk2x after 4 ns;

   irender : entity work.webtv_gfx_render
   port map (
      clk1x => clk1x, clk2x => clk2x, reset => reset, start => start, busy => busy, fb_base => to_unsigned(FB_BASE, 28),
      pot_vstart => regs(0), pot_vsize => regs(1), pot_hstart => regs(2), pot_hsize => regs(3), pot_cntl => regs(4),
      pot_blnkcol => regs(5), vid_nstart => regs(6), vid_dmacntl => regs(7), gfx_cntl => regs(8),
      gfx_ymapbase_master => regs(9), gfx_celsbase_master => regs(10), gfx_hcounterinit => regs(11),
      gfx_blanklines => regs(12), gfx_activelines => regs(13),
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

   iddr3mux : entity work.webtv_ddr3mux
   port map (
      clk1x => clk1x, clk2x => clk2x, reset => reset, error => open,
      ddr3_BUSY => ddr3_BUSY, ddr3_DOUT => ddr3_DOUT, ddr3_DOUT_READY => ddr3_DOUT_READY,
      ddr3_BURSTCNT => ddr3_BURSTCNT, ddr3_ADDR => ddr3_ADDR, ddr3_DIN => ddr3_DIN, ddr3_BE => ddr3_BE,
      ddr3_WE => ddr3_WE, ddr3_RD => ddr3_RD,
      rdram_request => d_request, rdram_rnw => d_rnw, rdram_address => d_address, rdram_burstcount => d_burst,
      rdram_writeMask => d_mask, rdram_dataWrite => d_data, rdram_granted2x => d_granted2x,
      rdram_done => d_done, rdram_dataRead => d_dataRead
   );

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
         if ddr3_RD = '1' then
            q_at(q_n) := now + ddr3_latency; q_addr(q_n) := to_integer(unsigned(ddr3_ADDR(24 downto 0)));
            q_cnt(q_n) := to_integer(unsigned(ddr3_BURSTCNT));
            q_n := q_n + 1;
         elsif ddr3_WE = '1' then
            w := to_integer(unsigned(ddr3_ADDR(24 downto 0)));
            assert w < RAM_WORDS + FB_WORDS report "DDR3 model: write outside the model" severity failure;
            d := mem(w);
            for b in 0 to 7 loop
               if ddr3_BE(b) = '1' then d(8*b+7 downto 8*b) := ddr3_DIN(8*b+7 downto 8*b); end if;
            end loop;
            mem(w) := d;
         end if;
         if q_n > 0 and now >= q_at(0) then
            w := q_addr(0) + beat;
            if w < RAM_WORDS + FB_WORDS then ddr3_DOUT <= mem(w); else ddr3_DOUT <= x"DEADBEEFDEADBEEF"; end if;
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

   process
      type char_file is file of character;
      file f : char_file;
      file rf : text;
      variable l : line;
      variable c : character;
      variable i : integer := 0;
      variable wd : std_logic_vector(63 downto 0);
      variable rv : std_logic_vector(31 downto 0);
      variable t0 : time;
      constant hdr : string := "P6" & LF & "640 480" & LF & "255" & LF;
   begin
      file_open(f, frame_dir & "/ram.bin", read_mode);
      while not endfile(f) and i < RAM_WORDS * 8 loop
         read(f, c);
         wd := mem(i / 8);
         wd(8 * (i mod 8) + 7 downto 8 * (i mod 8)) := std_logic_vector(to_unsigned(character'pos(c), 8));
         mem(i / 8) := wd;
         i := i + 1;
      end loop;
      file_close(f);
      file_open(rf, frame_dir & "/regs.hex", read_mode);
      for k in 0 to 13 loop
         readline(rf, l); hread(l, rv); regs(k) <= rv;
      end loop;
      file_close(rf);

      wait for 100 ns;
      wait until rising_edge(clk1x);
      reset <= '0';
      wait until rising_edge(clk1x);
      start <= '1';
      t0 := now;
      wait until rising_edge(clk1x);
      start <= '0';
      wait until rising_edge(clk1x);
      wait until rising_edge(clk1x) and busy = '0';
      report "frame rendered in " & integer'image((now - t0) / 16 ns) & " clk1x cycles";

      file_open(f, out_file, write_mode);
      for k in hdr'range loop write(f, hdr(k)); end loop;
      for p in 0 to 640 * 480 - 1 loop
         wd := mem(FB_BASE / 8 + p / 2);
         for b in 0 to 2 loop
            write(f, character'val(to_integer(unsigned(wd(32 * (p mod 2) + 8 * b + 7 downto 32 * (p mod 2) + 8 * b)))));
         end loop;
      end loop;
      file_close(f);
      report "wrote " & out_file;
      std.env.finish;
      wait;
   end process;
end architecture;
