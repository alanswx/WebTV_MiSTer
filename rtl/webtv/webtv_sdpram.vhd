-----------------------------------------------------------------
-- Simple dual-port RAM, one clock, registered read (q = mem[raddr] one cycle later):
-- the Quartus inference template for M10K blocks.
-----------------------------------------------------------------
library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

entity webtv_sdpram is
   generic
   (
      WIDTH : natural;
      AW    : natural
   );
   port
   (
      clk   : in  std_logic;
      we    : in  std_logic;
      waddr : in  unsigned(AW - 1 downto 0);
      wdata : in  std_logic_vector(WIDTH - 1 downto 0);
      raddr : in  unsigned(AW - 1 downto 0);
      q     : out std_logic_vector(WIDTH - 1 downto 0)
   );
end entity;

architecture arch of webtv_sdpram is
   type tMem is array(0 to 2 ** AW - 1) of std_logic_vector(WIDTH - 1 downto 0);
   signal mem : tMem;
begin
   process (clk)
   begin
      if rising_edge(clk) then
         if (we = '1') then
            mem(to_integer(waddr)) <= wdata;
         end if;
         q <= mem(to_integer(raddr));
      end if;
   end process;
end architecture;
