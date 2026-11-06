-----------------------------------------------------------------
-- WebTV DDR3 arbiter (simplified from N64_MiSTer's DDR3Mux)
--
-- N clients, fixed priority (client 0 highest). One transaction at a time: a read burst of up
-- to 255 beats or a single-beat write. Runs on clk2x (the DDR3 clock); request/done towards the
-- clients are clk1x-friendly (done is stretched to two clk2x cycles, as in the N64 core).
--
-- For reads, rdram_granted2x(i) pulses (clk2x) when the read is issued; clients that stream the
-- data themselves (the CPU caches) then take ddr3_DOUT on every ddr3_DOUT_READY. rdram_dataRead
-- holds the last beat, captured for the clk1x side.
--
-- DDR3 window: ddr3_ADDR is in 64-bit words; the core's window starts at byte 0x30000000
-- (ddr3_ADDR(28 downto 25) = "0011"), the same as the other MiSTer cores.
-----------------------------------------------------------------
library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

package pWebTVDDR3 is
   constant DDR3_CLIENTS     : integer := 5;
   constant DDR3_CPU         : integer := 0;
   constant DDR3_VIDEO       : integer := 1;
   constant DDR3_AUDIO       : integer := 2;
   constant DDR3_HPS         : integer := 3;  -- loader / disk DMA
   constant DDR3_FBW         : integer := 4;  -- frame renderer: framebuffer writes

   type tDDR3Single     is array(0 to DDR3_CLIENTS - 1) of std_logic;
   type tDDR3Addr       is array(0 to DDR3_CLIENTS - 1) of unsigned(27 downto 0);
   type tDDR3Burst      is array(0 to DDR3_CLIENTS - 1) of unsigned(9 downto 0);
   type tDDR3Mask       is array(0 to DDR3_CLIENTS - 1) of std_logic_vector(7 downto 0);
   type tDDR3Data       is array(0 to DDR3_CLIENTS - 1) of std_logic_vector(63 downto 0);
end package;

library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;
use work.pWebTVDDR3.all;

entity webtv_ddr3mux is
   port
   (
      clk1x            : in  std_logic;
      clk2x            : in  std_logic;
      reset            : in  std_logic;

      error            : out std_logic := '0';

      ddr3_BUSY        : in  std_logic;
      ddr3_DOUT        : in  std_logic_vector(63 downto 0);
      ddr3_DOUT_READY  : in  std_logic;
      ddr3_BURSTCNT    : out std_logic_vector(7 downto 0) := (others => '0');
      ddr3_ADDR        : out std_logic_vector(28 downto 0) := (others => '0');
      ddr3_DIN         : out std_logic_vector(63 downto 0) := (others => '0');
      ddr3_BE          : out std_logic_vector(7 downto 0) := (others => '0');
      ddr3_WE          : out std_logic := '0';
      ddr3_RD          : out std_logic := '0';

      rdram_request    : in  tDDR3Single;
      rdram_rnw        : in  tDDR3Single;
      rdram_address    : in  tDDR3Addr;      -- byte address in the window (low 3 bits ignored)
      rdram_burstcount : in  tDDR3Burst;     -- read beats (1..255); writes are one beat
      rdram_writeMask  : in  tDDR3Mask;
      rdram_dataWrite  : in  tDDR3Data;
      rdram_granted2x  : out tDDR3Single := (others => '0');
      rdram_done       : out tDDR3Single := (others => '0');
      rdram_dataRead   : out std_logic_vector(63 downto 0) := (others => '0')
   );
end entity;

architecture arch of webtv_ddr3mux is

   type tState is (IDLE, WAITREAD);
   signal state       : tState := IDLE;

   signal req_latched : tDDR3Single := (others => '0');
   type tDone is array(0 to DDR3_CLIENTS - 1) of std_logic_vector(1 downto 0);
   signal done        : tDone := (others => "00");
   signal lastIndex   : integer range 0 to DDR3_CLIENTS - 1 := 0;
   signal readCount   : unsigned(7 downto 0) := (others => '0');
   signal timeout     : unsigned(15 downto 0) := (others => '0');

   signal dataRead_2x     : std_logic_vector(63 downto 0) := (others => '0');
   signal doutReady_1     : std_logic := '0';
   signal captureNext     : std_logic := '0';

begin

   ddr3_ADDR(28 downto 25) <= "0011";

   -- last read beat for the clk1x side
   process (clk1x)
   begin
      if rising_edge(clk1x) then
         if (state = WAITREAD) then
            captureNext <= '1';
         end if;
         if (captureNext = '1') then
            if (ddr3_DOUT_READY = '1') then
               rdram_dataRead <= ddr3_DOUT;
               captureNext    <= '0';
            end if;
            if (doutReady_1 = '1') then
               rdram_dataRead <= dataRead_2x;
               captureNext    <= '0';
            end if;
         end if;
      end if;
   end process;

   process (clk2x)
      variable active : std_logic;
      variable index  : integer range 0 to DDR3_CLIENTS - 1;
   begin
      if rising_edge(clk2x) then

         error       <= '0';
         doutReady_1 <= ddr3_DOUT_READY;

         if (ddr3_BUSY = '0') then
            ddr3_WE <= '0';
            ddr3_RD <= '0';
         end if;

         -- latch requests, highest priority = lowest index
         active := '0';
         index  := 0;
         for i in DDR3_CLIENTS - 1 downto 0 loop
            if (rdram_request(i) = '1') then
               req_latched(i) <= '1';
            end if;
            if (req_latched(i) = '1') then
               active := '1';
               index  := i;
            end if;
            rdram_done(i) <= '0';
            done(i)       <= '0' & done(i)(1);
            if (done(i) /= "00") then
               rdram_done(i) <= '1';
            end if;
            rdram_granted2x(i) <= '0';
         end loop;

         if (reset = '1') then
            state       <= IDLE;
            req_latched <= (others => '0');
         else
            case (state) is
               when IDLE =>
                  timeout <= (others => '0');
                  if ((ddr3_BUSY = '0' or (ddr3_WE = '0' and ddr3_RD = '0')) and active = '1') then
                     req_latched(index)     <= '0';
                     lastIndex              <= index;
                     ddr3_ADDR(24 downto 0) <= std_logic_vector(rdram_address(index)(27 downto 3));
                     ddr3_DIN               <= rdram_dataWrite(index);
                     ddr3_BE                <= rdram_writeMask(index);
                     if (rdram_rnw(index) = '1') then
                        ddr3_RD                   <= '1';
                        ddr3_BURSTCNT             <= std_logic_vector(rdram_burstcount(index)(7 downto 0));
                        readCount                 <= rdram_burstcount(index)(7 downto 0);
                        rdram_granted2x(index)    <= '1';
                        state                     <= WAITREAD;
                     else
                        ddr3_WE                   <= '1';
                        ddr3_BURSTCNT             <= x"01";
                        done(index)               <= "11";
                     end if;
                  end if;

               when WAITREAD =>
                  timeout <= timeout + 1;
                  if (timeout = x"FFFF") then
                     error <= '1';
                  end if;
                  if (ddr3_DOUT_READY = '1') then
                     dataRead_2x <= ddr3_DOUT;
                     readCount   <= readCount - 1;
                     if (readCount = 1) then
                        state           <= IDLE;
                        done(lastIndex) <= "11";
                     end if;
                  end if;
            end case;
         end if;
      end if;
   end process;

end architecture;
