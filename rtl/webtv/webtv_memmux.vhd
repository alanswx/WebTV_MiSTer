-----------------------------------------------------------------
-- WebTV LC2 memory mux (replaces N64_MiSTer's memorymux)
--
-- Takes the CPU's memory requests (clk1x domain, N64_MiSTer cpu.vhd protocol) and sends them to:
--   0x00000000-0x03FFFFFF  RAM   8 MB, mirrored        -> DDR3 client, DDR3 offset RAM_BASE
--   0x1F800000-0x1FFFFFFF  ROMU  2 MB boot ROM, mirrored -> DDR3 client, DDR3 offset ROM_BASE (writes dropped)
--   everything else        MMIO  (SOLO 0x04000000, modem 0x1E000000, IDE 0x1E400000, ROML ...)
--
-- Data formats
--   CPU side / DDR3: bytes in address order inside a 64-bit word, lowest address in bits 7:0
--   (same as N64_MiSTer, and the same as the HPS's view of DDR3, so images load unswapped).
--   MMIO bus: native big-endian 32-bit word at bus_addr (word aligned); bus_be(3) = byte at
--   offset 0 (bits 31:24) ... bus_be(0) = byte at offset 3 (bits 7:0). Reads return the whole word;
--   the mux picks the requested bytes.
--
-- Cache line fills (mem_size "100", 4 x 64 bit) are passed to the DDR3 mux as 4-beat bursts; the
-- caches take the data straight from ddr3_DOUT when they see rdram_granted2x.
-----------------------------------------------------------------
library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

entity webtv_memmux is
   generic
   (
      RAM_BASE : unsigned(27 downto 0) := x"0000000";   -- byte offset in the core's DDR3 window
      ROM_BASE : unsigned(27 downto 0) := x"0800000"
   );
   port
   (
      clk1x            : in  std_logic;
      reset            : in  std_logic;

      error            : out std_logic := '0';

      -- CPU (N64_MiSTer cpu.vhd memory port)
      mem_request      : in  std_logic;
      mem_rnw          : in  std_logic;
      mem_address      : in  unsigned(31 downto 0);
      mem_req64        : in  std_logic;
      mem_size         : in  unsigned(2 downto 0);
      mem_writeMask    : in  std_logic_vector(7 downto 0);
      mem_dataWrite    : in  std_logic_vector(63 downto 0);
      mem_dataRead     : out std_logic_vector(63 downto 0) := (others => '0');
      mem_done         : out std_logic := '0';

      -- DDR3 mux client
      rdram_request    : out std_logic := '0';
      rdram_rnw        : out std_logic := '0';
      rdram_address    : out unsigned(27 downto 0) := (others => '0');
      rdram_burstcount : out unsigned(9 downto 0) := (others => '0');
      rdram_writeMask  : out std_logic_vector(7 downto 0) := (others => '0');
      rdram_dataWrite  : out std_logic_vector(63 downto 0) := (others => '0');
      rdram_done       : in  std_logic;
      rdram_dataRead   : in  std_logic_vector(63 downto 0);

      -- MMIO bus
      bus_addr         : out unsigned(31 downto 0) := (others => '0');
      bus_read         : out std_logic := '0';
      bus_write        : out std_logic := '0';
      bus_be           : out std_logic_vector(3 downto 0) := (others => '0');
      bus_dataWrite    : out std_logic_vector(31 downto 0) := (others => '0');
      bus_dataRead     : in  std_logic_vector(31 downto 0);
      bus_done         : in  std_logic
   );
end entity;

architecture arch of webtv_memmux is

   type tState is (IDLE, WAITRAM, WAITBUS);
   signal state     : tState := IDLE;
   signal last_addr : unsigned(31 downto 0) := (others => '0');

   function byteswap32(v : std_logic_vector(31 downto 0)) return std_logic_vector is
   begin
      return v(7 downto 0) & v(15 downto 8) & v(23 downto 16) & v(31 downto 24);
   end function;

begin

   process (clk1x)
      variable memWord : unsigned(27 downto 0);
      variable lane    : std_logic_vector(31 downto 0);
      variable mask    : std_logic_vector(3 downto 0);
   begin
      if rising_edge(clk1x) then

         error         <= '0';
         mem_done      <= '0';
         rdram_request <= '0';
         bus_read      <= '0';
         bus_write     <= '0';

         if (reset = '1') then

            state <= IDLE;

         else

            case (state) is
               when IDLE =>
                  if (mem_request = '1') then

                     last_addr <= mem_address;

                     -- DDR3 write data/mask: 64-bit accesses come with the 32-bit halves swapped,
                     -- 32-bit ones carry their word in the low half (N64_MiSTer memorymux)
                     rdram_rnw        <= mem_rnw;
                     rdram_burstcount <= 7x"00" & mem_size;
                     rdram_dataWrite  <= mem_dataWrite(31 downto 0) & mem_dataWrite(63 downto 32);
                     rdram_writeMask  <= mem_writeMask(3 downto 0) & mem_writeMask(7 downto 4);
                     if (mem_req64 = '0') then
                        rdram_dataWrite <= mem_dataWrite(31 downto 0) & mem_dataWrite(31 downto 0);
                        if (mem_address(2) = '1') then
                           rdram_writeMask <= mem_writeMask(3 downto 0) & "0000";
                        else
                           rdram_writeMask <= "0000" & mem_writeMask(3 downto 0);
                        end if;
                     end if;

                     if (mem_address < x"04000000") then                       -- RAM
                        rdram_address <= RAM_BASE + (5x"0" & mem_address(22 downto 3) & "000");
                        rdram_request <= '1';
                        state         <= WAITRAM;

                     elsif (mem_address >= x"1F800000" and mem_address < x"20000000") then  -- boot ROM
                        rdram_address <= ROM_BASE + (7x"0" & mem_address(20 downto 3) & "000");
                        if (mem_rnw = '1') then
                           rdram_request <= '1';
                           state         <= WAITRAM;
                        else
                           mem_done      <= '1';                                -- flash writes ignored
                        end if;

                     else                                                       -- MMIO
                        bus_addr      <= mem_address(31 downto 2) & "00";
                        if (mem_req64 = '1') then
                           lane := mem_dataWrite(63 downto 32);
                           mask := mem_writeMask(7 downto 4);
                        else
                           lane := mem_dataWrite(31 downto 0);
                           mask := mem_writeMask(3 downto 0);
                        end if;
                        bus_dataWrite <= byteswap32(lane);
                        bus_be        <= mask(0) & mask(1) & mask(2) & mask(3);
                        if (mem_rnw = '1') then
                           bus_be     <= "1111";
                           bus_read   <= '1';
                        else
                           bus_write  <= '1';
                        end if;
                        state         <= WAITBUS;
                     end if;

                  end if;

               when WAITRAM =>
                  if (rdram_done = '1') then
                     mem_done <= '1';
                     state    <= IDLE;
                     -- single accesses: the requested bytes move to the bottom (cache fills
                     -- take their data from ddr3_DOUT directly)
                     case (last_addr(2 downto 0)) is
                        when "000"  => mem_dataRead <= rdram_dataRead;
                        when "001"  => mem_dataRead(7 downto 0)  <= rdram_dataRead(15 downto 8);
                        when "010"  => mem_dataRead(15 downto 0) <= rdram_dataRead(31 downto 16);
                        when "011"  => mem_dataRead(7 downto 0)  <= rdram_dataRead(31 downto 24);
                        when "100"  => mem_dataRead(31 downto 0) <= rdram_dataRead(63 downto 32);
                        when "101"  => mem_dataRead(7 downto 0)  <= rdram_dataRead(47 downto 40);
                        when "110"  => mem_dataRead(15 downto 0) <= rdram_dataRead(63 downto 48);
                        when others => mem_dataRead(7 downto 0)  <= rdram_dataRead(63 downto 56);
                     end case;
                  end if;

               when WAITBUS =>
                  if (bus_done = '1') then
                     mem_done <= '1';
                     state    <= IDLE;
                     -- big-endian bus word -> bytes in address order, requested bytes at the bottom
                     case (last_addr(1 downto 0)) is
                        when "00"   => mem_dataRead(31 downto 0) <= byteswap32(bus_dataRead);
                        when "01"   => mem_dataRead(7 downto 0)  <= bus_dataRead(23 downto 16);
                        when "10"   => mem_dataRead(15 downto 0) <= bus_dataRead(7 downto 0) & bus_dataRead(15 downto 8);
                        when others => mem_dataRead(7 downto 0)  <= bus_dataRead(7 downto 0);
                     end case;
                  end if;

            end case;

         end if;
      end if;
   end process;

end architecture;
