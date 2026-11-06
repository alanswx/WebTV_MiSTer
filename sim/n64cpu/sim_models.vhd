-- Behavioral stand-ins for the Intel (altera_mf) primitives used by the N64_MiSTer CPU,
-- so it can be simulated with GHDL. Same entity names/ports as the originals.

-------------------------------------------------------------------------------- dpram
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity dpram is
   generic (addr_width : integer := 8; data_width : integer := 8);
   port (
      clock_a   : in  std_logic;
      clken_a   : in  std_logic := '1';
      address_a : in  std_logic_vector(addr_width-1 downto 0);
      data_a    : in  std_logic_vector(data_width-1 downto 0);
      wren_a    : in  std_logic := '0';
      q_a       : out std_logic_vector(data_width-1 downto 0);
      clock_b   : in  std_logic;
      clken_b   : in  std_logic := '1';
      address_b : in  std_logic_vector(addr_width-1 downto 0);
      data_b    : in  std_logic_vector(data_width-1 downto 0) := (others => '0');
      wren_b    : in  std_logic := '0';
      q_b       : out std_logic_vector(data_width-1 downto 0)
   );
end entity;

architecture sim of dpram is
   type t_mem is array(0 to 2**addr_width-1) of std_logic_vector(data_width-1 downto 0);
   shared variable mem : t_mem := (others => (others => '0'));
begin
   process(clock_a) begin
      if rising_edge(clock_a) and clken_a = '1' then
         if wren_a = '1' then
            mem(to_integer(unsigned(address_a))) := data_a;
            q_a <= data_a;                       -- NEW_DATA
         else
            q_a <= mem(to_integer(unsigned(address_a)));
         end if;
      end if;
   end process;
   process(clock_b) begin
      if rising_edge(clock_b) and clken_b = '1' then
         if wren_b = '1' then
            mem(to_integer(unsigned(address_b))) := data_b;
            q_b <= data_b;
         else
            q_b <= mem(to_integer(unsigned(address_b)));
         end if;
      end if;
   end process;
end architecture;

-------------------------------------------------------------------------------- dpram_dif
-- Mixed-width: port B's lower addresses map to port A's least significant bits (altsyncram).
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity dpram_dif is
   generic (addr_width_a : integer := 8; data_width_a : integer := 8;
            addr_width_b : integer := 8; data_width_b : integer := 8);
   port (
      clock_a   : in  std_logic;
      address_a : in  std_logic_vector(addr_width_a-1 downto 0);
      data_a    : in  std_logic_vector(data_width_a-1 downto 0) := (others => '0');
      clken_a   : in  std_logic := '1';
      wren_a    : in  std_logic := '0';
      q_a       : out std_logic_vector(data_width_a-1 downto 0);
      cs_a      : in  std_logic := '1';
      clock_b   : in  std_logic;
      address_b : in  std_logic_vector(addr_width_b-1 downto 0) := (others => '0');
      data_b    : in  std_logic_vector(data_width_b-1 downto 0) := (others => '0');
      clken_b   : in  std_logic := '1';
      wren_b    : in  std_logic := '0';
      q_b       : out std_logic_vector(data_width_b-1 downto 0);
      cs_b      : in  std_logic := '1'
   );
end entity;

architecture sim of dpram_dif is
   -- storage in units of the narrower width
   constant W     : integer := minimum(data_width_a, data_width_b);
   constant DEPTH : integer := 2**addr_width_a * (data_width_a / W);
   constant RA    : integer := data_width_a / W;
   constant RB    : integer := data_width_b / W;
   type t_mem is array(0 to DEPTH-1) of std_logic_vector(W-1 downto 0);
   shared variable mem : t_mem := (others => (others => '0'));
begin
   process(clock_a)
      variable base : integer;
      variable q    : std_logic_vector(data_width_a-1 downto 0);
   begin
      if rising_edge(clock_a) and clken_a = '1' then
         base := to_integer(unsigned(address_a)) * RA;
         if wren_a = '1' and cs_a = '1' then
            for i in 0 to RA-1 loop mem(base+i) := data_a((i+1)*W-1 downto i*W); end loop;
         end if;
         for i in 0 to RA-1 loop q((i+1)*W-1 downto i*W) := mem(base+i); end loop;
         q_a <= q;
      end if;
   end process;
   process(clock_b)
      variable base : integer;
      variable q    : std_logic_vector(data_width_b-1 downto 0);
   begin
      if rising_edge(clock_b) and clken_b = '1' then
         base := to_integer(unsigned(address_b)) * RB;
         if wren_b = '1' and cs_b = '1' then
            for i in 0 to RB-1 loop mem(base+i) := data_b((i+1)*W-1 downto i*W); end loop;
         end if;
         for i in 0 to RB-1 loop q((i+1)*W-1 downto i*W) := mem(base+i); end loop;
         q_b <= q;
      end if;
   end process;
end architecture;

-------------------------------------------------------------------------------- RamMLAB
-- altdpram: registered write (address/data/wren on inclock), unregistered (async) read.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity RamMLAB is
   generic (width : natural; width_byteena : natural := 1; widthad : natural);
   port (
      inclock   : in  std_logic;
      wren      : in  std_logic;
      data      : in  std_logic_vector(width-1 downto 0);
      wraddress : in  std_logic_vector(widthad-1 downto 0);
      rdaddress : in  std_logic_vector(widthad-1 downto 0);
      q         : out std_logic_vector(width-1 downto 0)
   );
end entity;

architecture sim of RamMLAB is
   type t_mem is array(0 to 2**widthad-1) of std_logic_vector(width-1 downto 0);
   signal mem : t_mem := (others => (others => '0'));
begin
   process(inclock) begin
      if rising_edge(inclock) and wren = '1' then
         mem(to_integer(unsigned(wraddress))) <= data;
      end if;
   end process;
   q <= mem(to_integer(unsigned(rdaddress))) when not is_x(rdaddress) else (others => 'X');
end architecture;
