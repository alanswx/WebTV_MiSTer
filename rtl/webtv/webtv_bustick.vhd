-----------------------------------------------------------------
-- WebTV system bus tick: one pulse per LC2 bus clock (83.58 MHz on the real box: CPU 167.17 MHz / 2),
-- generated from the core clock with a fractional accumulator. Drives the CPU's Count and the
-- SOLO's TCOUNT so both advance exactly as on the hardware, whatever the core clock is.
-----------------------------------------------------------------
library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;
use IEEE.math_real.all;

entity webtv_bustick is
   generic
   (
      CLK_HZ  : natural := 93750000;   -- clock this runs on (the CPU clock, clk93)
      TICK_HZ : natural := 83583582    -- LC2 bus clock
   );
   port
   (
      clk   : in  std_logic;
      ce    : in  std_logic := '1';
      tick  : out std_logic := '0'
   );
end entity;

architecture arch of webtv_bustick is
   -- 32-bit phase accumulator: step = TICK_HZ / CLK_HZ * 2^32 (TICK_HZ must be < CLK_HZ)
   constant STEP : unsigned(32 downto 0) := shift_left(to_unsigned(integer(real(TICK_HZ) / real(CLK_HZ) * 2.0**30), 33), 2);
   signal acc    : unsigned(32 downto 0) := (others => '0');
begin
   process (clk)
      variable next_acc : unsigned(32 downto 0);
   begin
      if rising_edge(clk) then
         tick <= '0';
         if (ce = '1') then
            next_acc := ('0' & acc(31 downto 0)) + STEP;
            acc      <= next_acc;
            tick     <= next_acc(32);
         end if;
      end if;
   end process;
end architecture;
