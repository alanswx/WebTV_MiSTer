-----------------------------------------------------------------
-- WebTV LC2 IIC bus: the devices behind the SOLO's bit-banged DEV_IICCNTL register
--   0xA0  AT24C01A NVRAM, 128 bytes, 8-byte page wrap on writes
--   0x88  Bt827, 0x8C SAA7187, 0xB6 audio encoder, 0xC2 tuner: 256-byte register files
-- Follows the webtv-bridge JS model (src/machine/i2c.js) step for step, including its quirks
-- (a device's register pointer is only re-armed by a repeated START), so the lock-step
-- testbench sees the same SDA bits.
--
-- The master's SCL/SDA come from the SOLO register (iic_cntl: 4 CLKOEN, 3 CLKO, 2 DATAOEN,
-- 1 DATAO; a disabled output floats high). Every change is one bus event, as JS I2cBus.set().
--
-- init_*: raw state load for JS snapshots (see sim/trace.mjs iic.txt)
--   0x0000  scl | sdaM << 1 | sdaS << 2 | state << 4 | bits << 8 | nbits << 16 | dev << 20 | reading << 23 | outByte << 24
--   0x0001  next state | masterNack << 3
--   0x0010+d  device d (1..5) pointer | gotPtr << 8
--   0x1000+i  device memory byte i (nvram 0..127, then 256 per register device)
-----------------------------------------------------------------
library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

entity webtv_iic is
   port
   (
      clk1x      : in  std_logic;
      iic_cntl   : in  std_logic_vector(4 downto 1);
      scl_out    : out std_logic;              -- bus levels as read back through DEV_IICCNTL
      sda_out    : out std_logic;

      init_we    : in  std_logic := '0';
      init_addr  : in  unsigned(15 downto 0) := (others => '0');
      init_data  : in  std_logic_vector(31 downto 0) := (others => '0')
   );
end entity;

architecture arch of webtv_iic is

   constant S_IDLE  : integer := 0;
   constant S_ADDR  : integer := 1;
   constant S_WRITE : integer := 2;
   constant S_READ  : integer := 3;
   constant S_MACK  : integer := 4;
   constant S_SACK  : integer := 5;
   constant S_NACK  : integer := 6;

   -- device memories (block RAM): read address = the selected device's pointer, data one cycle later
   signal memWe  : std_logic := '0';
   signal memWA  : unsigned(10 downto 0) := (others => '0');
   signal memWD  : std_logic_vector(7 downto 0) := (others => '0');
   signal memRA  : unsigned(10 downto 0);
   signal memQ   : std_logic_vector(7 downto 0);

   type tPtr is array(1 to 5) of unsigned(7 downto 0);
   signal ptr    : tPtr := (others => (others => '0'));
   signal gotPtr : std_logic_vector(1 to 5) := (others => '0');

   signal scl, sdaM : std_logic := '1';
   signal sdaS      : std_logic := '1';
   signal state     : integer range 0 to 7 := S_IDLE;
   signal nxt       : integer range 0 to 7 := S_IDLE;
   signal bits      : std_logic_vector(7 downto 0) := (others => '0');
   signal nbits     : integer range 0 to 15 := 0;
   signal dev       : integer range 0 to 5 := 0;
   signal reading   : std_logic := '0';
   signal outByte   : std_logic_vector(7 downto 0) := (others => '0');
   signal mNack     : std_logic := '0';

   signal sclNew, sdaNew : std_logic;

   function devIndex(a7 : std_logic_vector(6 downto 0)) return integer is
   begin
      case a7 is
         when "1010000" => return 1;   -- 0xA0 nvram
         when "1000100" => return 2;   -- 0x88 bt827
         when "1000110" => return 3;   -- 0x8C saa7187
         when "1011011" => return 4;   -- 0xB6 audenc
         when "1100001" => return 5;   -- 0xC2 tuner
         when others    => return 0;
      end case;
   end function;

   function memIndex(d : integer; p : unsigned(7 downto 0)) return integer is
   begin
      if d <= 1 then return to_integer(p(6 downto 0)); end if;
      return 128 + (d - 2) * 256 + to_integer(p);
   end function;

begin

   imem : entity work.webtv_sdpram
   generic map (WIDTH => 8, AW => 11)
   port map (clk => clk1x, we => memWe, waddr => memWA, wdata => memWD, raddr => memRA, q => memQ);
   memRA <= to_unsigned(memIndex(dev, ptr(dev)), 11) when dev /= 0 else (others => '0');

   sclNew  <= iic_cntl(3) when iic_cntl(4) = '1' else '1';
   sdaNew  <= iic_cntl(1) when iic_cntl(2) = '1' else '1';
   scl_out <= scl;
   sda_out <= sdaM and sdaS;

   process (clk1x)
      variable b    : std_logic_vector(7 downto 0);
      variable p    : unsigned(7 downto 0);
      variable d    : integer range 0 to 5;
      variable ob   : std_logic_vector(7 downto 0);

      -- readByte() of the selected device; returns the byte, advances the pointer
      procedure loadRead is
      begin
         p  := ptr(dev);
         ob := memQ;                     -- mem(memIndex(dev, ptr(dev))), set up long before
         if dev = 1 then ptr(dev) <= '0' & (p(6 downto 0) + 1); else ptr(dev) <= p + 1; end if;
         outByte <= ob;
         nbits   <= 0;
         state   <= S_READ;
         sdaS    <= ob(7);
      end procedure;
   begin
      if rising_edge(clk1x) then
         memWe <= '0';

         if (sclNew /= scl or sdaNew /= sdaM) then
            scl  <= sclNew;
            sdaM <= sdaNew;

            if (scl = '1' and sclNew = '1') then
               -- SDA changed while SCL high: START / STOP
               if (sdaNew = '0') then
                  state <= S_ADDR; bits <= (others => '0'); nbits <= 0; sdaS <= '1';
                  if (dev /= 0) then gotPtr(dev) <= '0'; end if;
               else
                  state <= S_IDLE; sdaS <= '1'; dev <= 0;
               end if;

            elsif (scl = '0' and sclNew = '1') then
               -- rising edge
               case state is
                  when S_ADDR | S_WRITE =>
                     bits  <= bits(6 downto 0) & sdaNew;
                     nbits <= nbits + 1;
                  when S_MACK =>
                     mNack <= sdaNew;
                  when others => null;
               end case;

            elsif (scl = '1' and sclNew = '0') then
               -- falling edge
               case state is
                  when S_ADDR =>
                     if (nbits = 8) then
                        d := devIndex(bits(7 downto 1));
                        dev     <= d;
                        reading <= bits(0);
                        if (d /= 0) then
                           sdaS  <= '0';
                           state <= S_SACK;
                           if (bits(0) = '1') then nxt <= S_READ; else nxt <= S_WRITE; end if;
                        else
                           sdaS  <= '1';
                           state <= S_NACK;
                        end if;
                     end if;
                  when S_WRITE =>
                     if (nbits = 8) then
                        -- writeByte()
                        if (gotPtr(dev) = '0') then
                           if dev = 1 then ptr(dev) <= '0' & unsigned(bits(6 downto 0)); else ptr(dev) <= unsigned(bits); end if;
                           gotPtr(dev) <= '1';
                        else
                           p := ptr(dev);
                           memWe <= '1';
                           memWA <= to_unsigned(memIndex(dev, p), 11);
                           memWD <= bits;
                           if dev = 1 then ptr(dev) <= '0' & p(6 downto 3) & (p(2 downto 0) + 1);   -- page wrap
                           else ptr(dev) <= p + 1; end if;
                        end if;
                        sdaS  <= '0';
                        state <= S_SACK;
                        nxt   <= S_WRITE;
                     end if;
                  when S_SACK =>
                     sdaS  <= '1';
                     bits  <= (others => '0');
                     nbits <= 0;
                     if (nxt = S_READ) then loadRead;
                     else state <= nxt; end if;
                  when S_READ =>
                     if (nbits + 1 = 8) then
                        sdaS  <= '1';
                        state <= S_MACK;
                     else
                        sdaS  <= outByte(6 - nbits);
                     end if;
                     nbits <= nbits + 1;
                  when S_MACK =>
                     if (mNack = '1') then state <= S_IDLE; sdaS <= '1';
                     else loadRead; end if;
                  when S_NACK =>
                     state <= S_IDLE;
                  when others => null;
               end case;
            end if;
         end if;

         if (init_we = '1') then
            if (init_addr = x"0000") then
               scl     <= init_data(0);
               sdaM    <= init_data(1);
               sdaS    <= init_data(2);
               state   <= to_integer(unsigned(init_data(6 downto 4)));
               bits    <= init_data(15 downto 8);
               nbits   <= to_integer(unsigned(init_data(19 downto 16)));
               dev     <= to_integer(unsigned(init_data(22 downto 20)));
               reading <= init_data(23);
               outByte <= init_data(31 downto 24);
            elsif (init_addr = x"0001") then
               nxt   <= to_integer(unsigned(init_data(2 downto 0)));
               mNack <= init_data(3);
            elsif (init_addr >= x"0011" and init_addr <= x"0015") then
               ptr(to_integer(init_addr(2 downto 0)))    <= unsigned(init_data(7 downto 0));
               gotPtr(to_integer(init_addr(2 downto 0))) <= init_data(8);
            elsif (init_addr >= x"1000" and init_addr < x"1480") then
               memWe <= '1';
               memWA <= init_addr(10 downto 0);
               memWD <= init_data(7 downto 0);
            end if;
         end if;

      end if;
   end process;

end architecture;
