-- IR receiver against the JS model (irref.mjs): same key events, TRANS_DATA read every 1 ms
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;

entity tb_ir is
   generic (events_file : string := "events.txt"; out_file : string := "rtl.txt"; end_us : integer := 1900000);
end entity;

architecture sim of tb_ir is
   signal clk : std_logic := '0';
   signal now_us : integer := 0;
   signal rd, done : std_logic := '0';
   signal dout : std_logic_vector(31 downto 0);
   signal ks, krel : std_logic := '0';
   signal kcode : std_logic_vector(6 downto 0) := (others => '0');
begin
   clk <= not clk after 500 ns;     -- 1 MHz: one cycle = 1 us

   idut : entity work.webtv_ir
   generic map (CLK_HZ => 1000000)
   port map (clk1x => clk, reset => '0', bus_addr => x"4028", bus_read => rd, bus_write => '0',
             bus_dataWrite => (others => '0'), bus_dataRead => dout, bus_done => done, handles => open,
             irq_set => open, key_strobe => ks, key_code => kcode, key_release => krel);

   process
      file ef : text open read_mode is events_file;
      file ofile : text open write_mode is out_file;
      variable l, o : line;
      variable et, esc, erel : integer;
      variable have : boolean := false;
   begin
      for t in 0 to end_us loop
         wait until rising_edge(clk);
         ks <= '0'; rd <= '0';
         if not have and not endfile(ef) then
            readline(ef, l); read(l, et); read(l, esc); read(l, erel); have := true;
         end if;
         if have and et <= t then
            ks <= '1'; kcode <= std_logic_vector(to_unsigned(esc, 7));
            if erel = 1 then krel <= '1'; else krel <= '0'; end if;
            have := false;
         end if;
         if t mod 1000 = 0 then rd <= '1'; end if;
         if done = '1' and unsigned(dout) /= 0 then
            write(o, integer'image(t) & " " & to_hstring(dout(15 downto 0))); writeline(ofile, o);
         end if;
      end loop;
      std.env.finish;
   end process;
end architecture;
