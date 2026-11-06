-- Behavioral cpu_mul (replaces the altera_mult_add version): registered 64x64 -> 128,
-- signed or unsigned on both operands.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity cpu_mul is
   port (
      clk       : in  std_logic;
      sign      : in  std_logic;
      value1_in : in  std_logic_vector(63 downto 0);
      value2_in : in  std_logic_vector(63 downto 0);
      result    : out std_logic_vector(127 downto 0)
   );
end entity;

architecture sim of cpu_mul is
begin
   process(clk) begin
      if rising_edge(clk) then
         if sign = '1' then
            result <= std_logic_vector(signed(value1_in) * signed(value2_in));
         else
            result <= std_logic_vector(unsigned(value1_in) * unsigned(value2_in));
         end if;
      end if;
   end process;
end architecture;
