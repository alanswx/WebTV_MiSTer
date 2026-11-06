-----------------------------------------------------------------
-- WebTV SOLO1 devUnit IR receiver with a Sejin IR keyboard feeding it, as the webtv-bridge JS
-- model (src/machine/ir.js, after the wtvemac MAME driver wtvir.cpp, BSD-3-Clause).
--
-- Registers (SOLO 0x04004000 +): 0x000 DEV_IROLD (reads 0x00690000, microcode version),
-- 0x020 sample interval, 0x024 reject interval, 0x028 DEV_IRIN_TRANS_DATA, 0x02C statcntl.
--
-- Key events (key_strobe: 7-bit Sejin scancode + release) are queued; each becomes a 22-bit Sejin
-- packet sent as runs of equal bits, 48 sample ticks (15 us) a bit, bit 0 first. A run is readable
-- once it has ended; the packet's last run stays open as the idle line and is reported when the
-- next packet starts (its length including the idle time) or at the counter maximum (2047 ticks).
-- Packets are at least 20 ms apart. A TRANS_DATA read returns
--     SSSS | V | TTTTTTTTTTT  (runs readable, at most 14 | level | ticks)  or 0 when none is.
-- A 60 Hz poll raises DEV_INT_IRIN (irq_set) when a run is readable and TRANS_DATA has not been
-- read since the last one.
-----------------------------------------------------------------
library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

entity webtv_ir is
   generic
   (
      CLK_HZ   : natural := 62500000
   );
   port
   (
      clk1x         : in  std_logic;
      reset         : in  std_logic;

      bus_addr      : in  unsigned(15 downto 0);
      bus_read      : in  std_logic;
      bus_write     : in  std_logic;
      bus_dataWrite : in  std_logic_vector(31 downto 0);
      bus_dataRead  : out std_logic_vector(31 downto 0) := (others => '0');
      bus_done      : out std_logic := '0';
      handles       : out std_logic;

      irq_set       : out std_logic := '0';     -- DEV_INT_IRIN

      key_strobe    : in  std_logic := '0';
      key_code      : in  std_logic_vector(6 downto 0) := (others => '0');
      key_release   : in  std_logic := '0'
   );
end entity;

architecture arch of webtv_ir is

   constant BIT_TICKS : integer := 48;
   constant MAX_TICKS : integer := 2047;
   constant IDLE_TICKS: integer := 20000 / 15;     -- 20 ms between packets
   constant MAX_READY : integer := 14;

   signal tick, poll : std_logic;

   -- key events
   type tEv is array(0 to 31) of std_logic_vector(7 downto 0);
   signal evFifo    : tEv;
   signal evWr, evRd: unsigned(4 downto 0) := (others => '0');

   -- runs that have ended: level & ticks
   type tRuns is array(0 to 63) of std_logic_vector(11 downto 0);
   signal runFifo   : tRuns;
   signal rWr, rRd  : unsigned(5 downto 0) := (others => '0');
   signal rCount    : unsigned(6 downto 0) := (others => '0');

   -- transmitter
   signal sending   : std_logic := '0';
   signal pkt       : std_logic_vector(21 downto 0) := (others => '0');
   signal bitIdx    : integer range 0 to 22 := 0;
   signal runLevel  : std_logic := '0';
   signal runTicks  : integer range 0 to 4095 := 0;   -- length of the run being sent
   signal runLeft   : integer range 0 to 4095 := 0;   -- ticks until it ends
   signal hasTail   : std_logic := '0';               -- the last run, held open as the idle line
   signal tailLevel : std_logic := '0';
   signal tailTicks : integer range 0 to 4095 := 0;
   signal gap       : integer range 0 to IDLE_TICKS := IDLE_TICKS;

   signal waitRead  : std_logic := '0';
   signal sampleInt : std_logic_vector(15 downto 0) := (others => '0');
   signal rejectInt : std_logic_vector(7 downto 0) := (others => '0');
   signal statcntl  : std_logic_vector(7 downto 0) := (others => '0');

   function oddParity(d : std_logic_vector) return std_logic is
      variable p : std_logic := '0';
   begin
      for i in d'range loop p := p xor d(i); end loop;
      return p;
   end function;

   -- [1 P 0 SSSSSSS 0] [1 P 1 M DD 0100 0], bit 0 on the right (JS sejinPacket)
   function sejinPacket(sc : std_logic_vector(6 downto 0); rel : std_logic) return std_logic_vector is
      variable d : std_logic_vector(21 downto 0);
   begin
      d := std_logic_vector(to_unsigned(16#200508#, 22));
      d(5)            := '1';                     -- device id 1 (bits 6:5)
      d(18 downto 12) := sc;
      d(7)            := rel;
      d(9)            := oddParity(d(10 downto 0));   -- odd parity of bits 0..10 (bit 9 still 0)
      d(20)           := oddParity(d(21 downto 11));
      return d;
   end function;

   -- ticks of the run of equal bits starting at bit i
   function runLen(d : std_logic_vector(21 downto 0); i : integer) return integer is
      variable n : integer := 0;
   begin
      for k in 0 to 21 loop
         if k >= i then
            if d(k) = d(i) and n = (k - i) * BIT_TICKS then n := n + BIT_TICKS; end if;
         end if;
      end loop;
      return n;
   end function;

begin

   handles <= '1' when bus_addr(15 downto 12) = x"4" and
                       (bus_addr(11 downto 0) = x"000" or (bus_addr(11 downto 4) = x"02")) else '0';

   itick : entity work.webtv_bustick
   generic map (CLK_HZ => CLK_HZ, TICK_HZ => 66667)   -- 15 us
   port map (clk => clk1x, tick => tick);

   ipoll : entity work.webtv_bustick
   generic map (CLK_HZ => CLK_HZ, TICK_HZ => 60)
   port map (clk => clk1x, tick => poll);

   process (clk1x)
      variable pushRun : boolean;
      variable pushVal : std_logic_vector(11 downto 0);
      variable popRun  : boolean;
      variable ready   : integer range 0 to MAX_READY;
      variable o       : integer;
      variable ev      : std_logic_vector(7 downto 0);
      variable p       : std_logic_vector(21 downto 0);
      variable n       : integer;
   begin
      if rising_edge(clk1x) then
         bus_done <= '0';
         irq_set  <= '0';
         pushRun  := false;
         popRun   := false;

         if (rCount > MAX_READY) then ready := MAX_READY; else ready := to_integer(rCount); end if;

         -- key events
         if (key_strobe = '1' and evWr + 1 /= evRd) then
            evFifo(to_integer(evWr)) <= key_release & key_code;
            evWr <= evWr + 1;
         end if;

         -- transmitter, one step per 15 us tick (stalls while the run FIFO is full)
         if (tick = '1' and rCount < 60) then
            if (gap < IDLE_TICKS) then gap <= gap + 1; end if;
            if (hasTail = '1') then
               if (tailTicks + 1 >= MAX_TICKS) then
                  pushRun := true; pushVal := tailLevel & std_logic_vector(to_unsigned(MAX_TICKS, 11));
                  hasTail <= '0';
               else
                  tailTicks <= tailTicks + 1;
               end if;
            end if;
            if (sending = '1') then
               if (runLeft <= 1) then
                  -- the run ends
                  n := bitIdx + runTicks / BIT_TICKS;
                  if (n >= 22) then
                     -- last run of the packet: it stays open as the idle line
                     sending   <= '0';
                     hasTail   <= '1';
                     tailLevel <= runLevel;
                     tailTicks <= runTicks;
                     gap       <= 0;
                  else
                     pushRun := true; pushVal := runLevel & std_logic_vector(to_unsigned(runTicks, 11));
                     bitIdx   <= n;
                     runLevel <= pkt(n);
                     runTicks <= runLen(pkt, n);
                     runLeft  <= runLen(pkt, n);
                  end if;
               else
                  runLeft <= runLeft - 1;
               end if;
            elsif (evWr /= evRd and gap = IDLE_TICKS and not (hasTail = '1' and tailTicks + 1 >= MAX_TICKS)) then
               -- next packet: its first edge ends the idle line
               if (hasTail = '1') then
                  pushRun := true; pushVal := tailLevel & std_logic_vector(to_unsigned(tailTicks, 11));
                  hasTail <= '0';
               end if;
               ev := evFifo(to_integer(evRd));
               evRd <= evRd + 1;
               p := sejinPacket(ev(6 downto 0), ev(7));
               pkt      <= p;
               sending  <= '1';
               bitIdx   <= 0;
               runLevel <= p(0);
               runTicks <= runLen(p, 0);
               runLeft  <= runLen(p, 0);
            end if;
         end if;

         -- 60 Hz poll
         if (poll = '1' and ready > 0 and waitRead = '0') then
            waitRead <= '1';
            irq_set  <= '1';
         end if;

         -- registers
         if (bus_read = '1' or bus_write = '1') then
            bus_done <= '1';
            o := to_integer(bus_addr(11 downto 0));
            bus_dataRead <= (others => '0');
            if (bus_read = '1') then
               case o is
                  when 16#000# => bus_dataRead <= x"00690000";
                  when 16#020# => bus_dataRead <= x"0000" & sampleInt;
                  when 16#024# => bus_dataRead <= x"000000" & rejectInt;
                  when 16#028# =>
                     waitRead <= '0';
                     if (ready > 0) then
                        bus_dataRead <= x"0000" & std_logic_vector(to_unsigned(ready, 4)) & runFifo(to_integer(rRd));
                        popRun := true;
                     end if;
                  when 16#02C# => bus_dataRead <= x"000000" & statcntl;
                  when others => null;
               end case;
            else
               case o is
                  when 16#020# => sampleInt <= bus_dataWrite(15 downto 0);
                  when 16#024# => rejectInt <= bus_dataWrite(7 downto 0);
                  when 16#02C# => statcntl  <= bus_dataWrite(7 downto 2) & '0' & bus_dataWrite(0);
                  when others => null;
               end case;
            end if;
         end if;

         if pushRun then
            runFifo(to_integer(rWr)) <= pushVal;
            rWr <= rWr + 1;
         end if;
         if popRun then rRd <= rRd + 1; end if;
         if (pushRun and not popRun) then rCount <= rCount + 1;
         elsif (popRun and not pushRun) then rCount <= rCount - 1;
         end if;

         if (reset = '1') then
            evWr <= (others => '0'); evRd <= (others => '0');
            rWr <= (others => '0'); rRd <= (others => '0'); rCount <= (others => '0');
            sending <= '0'; hasTail <= '0'; gap <= IDLE_TICKS; waitRead <= '0';
            sampleInt <= (others => '0'); rejectInt <= (others => '0'); statcntl <= (others => '0');
         end if;
      end if;
   end process;

end architecture;
