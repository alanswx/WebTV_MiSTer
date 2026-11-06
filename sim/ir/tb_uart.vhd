-- 16550 against the JS model (uartref.mjs): same op script, read values and the irq line compared
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;

entity tb_uart is
   generic (ops_file : string := "uart_ops.txt"; out_file : string := "uart_rtl.txt");
end entity;

architecture sim of tb_uart is
   constant DIV : integer := 10;          -- CLK_HZ / BAUD
   signal clk : std_logic := '0';
   signal rd, wr, done, irq, rxd, dcd : std_logic := '0';
   signal addr : unsigned(31 downto 0) := x"1E000000";
   signal din, dout : std_logic_vector(31 downto 0) := (others => '0');
begin
   clk <= not clk after 5 ns;

   idut : entity work.webtv_uart16550
   generic map (CLK_HZ => 10 * 115200, BAUD => 115200)
   port map (clk1x => clk, reset => '0', bus_addr => addr, bus_read => rd, bus_write => wr,
             bus_dataWrite => din, bus_dataRead => dout, bus_done => done, handles => open,
             irq_set => open, irq_clr => open, irq_level => irq, modem7e => open,
             line_txd => open, line_rxd => rxd, line_dcd => dcd, line_rts_n => open, mcr_out => open);

   process
      file f : text open read_mode is ops_file;
      file o : text open write_mode is out_file;
      variable l, ol : line;
      variable op : character;
      variable a, b : integer;
      variable res : string(1 to 2);
      function h(v : std_logic_vector(7 downto 0)) return string is
         constant hx : string(1 to 16) := "0123456789abcdef";
         variable n : integer := to_integer(unsigned(v));
      begin
         if n < 16 then return hx(n + 1 to n + 1); end if;
         return hx(n / 16 + 1) & hx(n mod 16 + 1);
      end function;
   begin
      rxd <= '1';
      for k in 1 to 20 loop wait until rising_edge(clk); end loop;
      while not endfile(f) loop
         readline(f, l); read(l, op); read(l, a);
         write(ol, op & " " & integer'image(a));
         if op = 'w' then
            read(l, b); write(ol, " " & integer'image(b));
            addr <= x"1E000000" + to_unsigned(4 * a, 32); din <= std_logic_vector(to_unsigned(b, 32)); wr <= '1';
            wait until rising_edge(clk); wr <= '0';
            wait until rising_edge(clk) and done = '1';
            write(ol, string'(" -"));
         elsif op = 'r' then
            addr <= x"1E000000" + to_unsigned(4 * a, 32); rd <= '1';
            wait until rising_edge(clk); rd <= '0';
            wait until rising_edge(clk) and done = '1';
            wait for 1 ns;
            write(ol, " " & h(dout(7 downto 0)));
         elsif op = 'x' then
            rxd <= '0'; for k in 1 to DIV loop wait until rising_edge(clk); end loop;
            for i in 0 to 7 loop
               if (a / 2 ** i) mod 2 = 1 then rxd <= '1'; else rxd <= '0'; end if;
               for k in 1 to DIV loop wait until rising_edge(clk); end loop;
            end loop;
            rxd <= '1'; for k in 1 to 3 * DIV loop wait until rising_edge(clk); end loop;
            write(ol, string'(" -"));
         else
            if a = 1 then dcd <= '1'; else dcd <= '0'; end if;
            write(ol, string'(" -"));
         end if;
         for k in 1 to 4 loop wait until rising_edge(clk); end loop;
         if irq = '1' then write(ol, string'(" 1")); else write(ol, string'(" 0")); end if;
         writeline(o, ol);
      end loop;
      std.env.finish;
   end process;
end architecture;
