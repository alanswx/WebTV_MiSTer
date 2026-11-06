library IEEE;
use IEEE.std_logic_1164.all;  
use IEEE.numeric_std.all;   
use ieee.math_real.all;  

library mem;
use work.pFunctions.all;

entity cpu_instrcache is
   port 
   (
      clk1x             : in  std_logic;
      clk93             : in  std_logic;
      clk2x             : in  std_logic;
      reset_93          : in  std_logic;
      ce_93             : in  std_logic;
      
      ram_request       : out std_logic := '0';
      ram_active        : in  std_logic := '0';
      ram_grant         : in  std_logic := '0';
      ram_done          : in  std_logic := '0';
      ddr3_DOUT         : in  std_logic_vector(63 downto 0);
      ddr3_DOUT_READY   : in  std_logic;
      
      read_select       : in  std_logic;
      read_addr1        : in  unsigned(31 downto 0);
      read_addr2        : in  unsigned(31 downto 0);
      read_addrCompare1 : in  unsigned(31 downto 0);
      read_addrCompare2 : in  unsigned(31 downto 0);
      read_hit          : out std_logic;
      read_data         : out std_logic_vector(31 downto 0) := (others => '0');
      
      fill_request      : in  std_logic;
      fill_addrData     : in  unsigned(31 downto 0);
      fill_addrTag      : in  unsigned(31 downto 0);
      fill_done         : out std_logic := '0';
      
      CacheCommandEna   : in  std_logic;
      CacheCommand      : in  unsigned(4 downto 0);
      CacheCommandAddr  : in  unsigned(31 downto 0);
      
      TagLo_Valid       : in  std_logic;
      TagLo_Addr        : in  unsigned(19 downto 0);

      SS_reset          : in  std_logic
   );
end entity;

-- WebTV: R4640 geometry -- 8 KB (was 16 KB), 32-byte lines, 256 lines indexed by addr(12:5),
-- direct mapped, so index CACHE loops sized from Config cover the whole cache.
architecture arch of cpu_instrcache is

   -- tags
   signal tag_address_a    : std_logic_vector(7 downto 0) := (others => '0');
   signal tag_data_a       : std_logic_vector(20 downto 0) := (others => '0');
   signal tag_wren_a       : std_logic := '0';
   signal tag_address_b1   : std_logic_vector(7 downto 0);
   signal tag_address_b2   : std_logic_vector(7 downto 0);
   signal tag_q_b1         : std_logic_vector(20 downto 0);
   signal tag_q_b2         : std_logic_vector(20 downto 0);
   signal fill_addrTag_sav : unsigned(12 downto 0) := (others => '0');

   signal read_hit1        : std_logic;
   signal read_hit2        : std_logic;

   -- data
   signal fill_addrTag_1x  : unsigned(7 downto 0) := (others => '0');
   signal fill_addrTag_2x  : unsigned(7 downto 0) := (others => '0');
   signal ram_grant_2x     : std_logic := '0';
   signal cache_addr_a     : unsigned(9 downto 0) := (others => '0');
   signal cache_wr_a       : std_logic;
   
   signal cache_address_b  : std_logic_vector(10 downto 0);
   signal cache_q_b        : std_logic_vector(31 downto 0);
   
   -- state machine
   type tState is
   (
      IDLE,
      CLEARCACHE,
      FILL
   );
   signal state : tstate := IDLE;
   
   signal fill_latched : std_logic := '0';

   -- WebTV: a CACHE command that arrives while the cache is busy (FILL, CLEARCACHE) was dropped:
   -- it is a one-clock pulse, only looked at in IDLE, and nothing stalls the pipeline for it. A
   -- flush loop's own fetches start fills, so part of every I-cache flush was lost and stale code
   -- could run after the OS loads code. Hold it (one deep) and retire it in IDLE. Same fix as
   -- SGIIndy_MiSTer's cpu_instrcache.vhd.
   signal cmd_pending  : std_logic := '0';
   signal cmd_code     : unsigned(4 downto 0) := (others => '0');
   signal cmd_addr     : unsigned(31 downto 0) := (others => '0');
   signal cmd_code_eff : unsigned(4 downto 0);
   signal cmd_addr_eff : unsigned(31 downto 0);
   signal cmd_ena_eff  : std_logic;
   
begin 

   -- use two tag rams, so different fetch paths can be calculated in parallel to improve timing

   read_hit <= read_hit2 when (read_select = '1') else read_hit1;

   ------------------ tags
   itagram1 : entity mem.RamMLAB
   generic map
   (
      width      => 21, -- 20 bits(31..12) of address + 1 bit valid
      widthad    => 8
   )
   port map
   (
      inclock    => clk93,
      wren       => tag_wren_a,
      data       => tag_data_a,
      wraddress  => tag_address_a,
      rdaddress  => tag_address_b1,
      q          => tag_q_b1
   );
   
   tag_address_b1 <= std_logic_vector(read_addr1(12 downto 5));
   read_hit1      <= '1' when (unsigned(tag_q_b1(19 downto 0)) = read_addrCompare1(31 downto 12) and tag_q_b1(20) = '1') else '0';
   
   itagram2 : entity mem.RamMLAB
   generic map
   (
      width      => 21, -- 20 bits(31..12) of address + 1 bit valid
      widthad    => 8
   )
   port map
   (
      inclock    => clk93,
      wren       => tag_wren_a,
      data       => tag_data_a,
      wraddress  => tag_address_a,
      rdaddress  => tag_address_b2,
      q          => tag_q_b2
   );
   
   tag_address_b2 <= std_logic_vector(read_addr2(12 downto 5));
   read_hit2      <= '1' when (unsigned(tag_q_b2(19 downto 0)) = read_addrCompare2(31 downto 12) and tag_q_b2(20) = '1') else '0';

   -- WebTV: a command held while busy (cmd_pending) is retired in IDLE
   cmd_ena_eff  <= CacheCommandEna or cmd_pending;
   cmd_code_eff <= CacheCommand     when (CacheCommandEna = '1') else cmd_code;
   cmd_addr_eff <= CacheCommandAddr when (CacheCommandEna = '1') else cmd_addr;

   --------- data
   
   process (clk1x)
   begin
      if rising_edge(clk1x) then
         fill_addrTag_1x <= fill_addrTag_sav(12 downto 5);
      end if;
   end process;
   
   process (clk2x)
   begin
      if rising_edge(clk2x) then
      
         fill_addrTag_2x <= fill_addrTag_1x;
      
         if (ram_grant = '1'and ram_active = '1') then
            ram_grant_2x <= '1';
         end if;
         
         if (ram_grant = '1') then
            cache_addr_a <= fill_addrTag_2x & "00";
         elsif (ddr3_DOUT_READY = '1') then
            cache_addr_a <= cache_addr_a + 1;
            if (ram_grant_2x = '1' and cache_addr_a(1 downto 0) = "11") then
               ram_grant_2x <= '0';
            end if;
         end if;
         
      end if;
   end process;

   cache_wr_a    <= ram_grant_2x and ddr3_DOUT_READY;

   icache: entity work.dpram_dif
   generic map 
   ( 
      addr_width_a  => 10,
      data_width_a  => 64,
      addr_width_b  => 11,
      data_width_b  => 32
   )
   port map
   (
      clock_a     => clk2x,
      address_a   => std_logic_vector(cache_addr_a),
      data_a      => ddr3_DOUT,
      wren_a      => cache_wr_a,
      
      clock_b     => clk93,
      clken_b     => ce_93,
      address_b   => cache_address_b,
      data_b      => x"00000000",
      wren_b      => '0',
      q_b         => cache_q_b
   );
   
   cache_address_b <= std_logic_vector(fill_addrTag_sav(12 downto 2))  when (state /= IDLE) else
                      std_logic_vector(read_addr2(12 downto 2)) when (read_select = '1') else
                      std_logic_vector(read_addr1(12 downto 2));
   
   read_data       <= byteswap32(cache_q_b);
   
   process (clk93)
   begin
      if rising_edge(clk93) then

         tag_wren_a  <= '0';
         fill_done   <= '0';
         ram_request <= '0';
         
         if (fill_request = '1') then
            fill_latched <= '1';
         end if;

         if (CacheCommandEna = '1' and state /= IDLE) then   -- WebTV: hold it, see cmd_pending
            cmd_pending <= '1';
            cmd_code    <= CacheCommand;
            cmd_addr    <= CacheCommandAddr;
         end if;

         if (SS_reset = '1') then
            cmd_pending    <= '0';
            state          <= CLEARCACHE;
            tag_data_a     <= (others => '0');
            tag_address_a  <= (others => '0');
            tag_wren_a     <= '1';
            fill_latched   <= '0';
         else

            case(state) is
            
               when IDLE =>
                  fill_addrTag_sav <= fill_addrTag(12 downto 0);
                  if (cmd_ena_eff = '1' and (cmd_code_eff = 5x"00" or cmd_code_eff = 5x"10" or cmd_code_eff = 5x"14")) then -- WebTV: 14 = Fill I
                     -- HACK!
                     -- todo: should only clear if tag matches
                     tag_wren_a     <= '1';
                     tag_data_a     <= (others => '0');
                     tag_address_a  <= std_logic_vector(cmd_addr_eff(12 downto 5));
                     cmd_pending    <= '0';
                  elsif (cmd_ena_eff = '1' and cmd_code_eff = 5x"08") then
                     tag_wren_a     <= '1';
                     tag_data_a     <= TagLo_Valid & std_logic_vector(TagLo_Addr(19 downto 0));
                     tag_address_a  <= std_logic_vector(cmd_addr_eff(12 downto 5));
                     cmd_pending    <= '0';
                  elsif (cmd_ena_eff = '1') then
                     cmd_pending    <= '0';   -- WebTV: a code this cache ignores
                  elsif (fill_request = '1' or fill_latched = '1') then
                     state          <= FILL;
                     ram_request    <= '1';
                     fill_latched   <= '0';
                  end if;
                  
               when CLEARCACHE =>
                  tag_wren_a     <= '1';
                  if (tag_address_a /= 8x"FF") then
                     tag_address_a <= std_logic_vector(unsigned(tag_address_a) + 1);
                  else
                     state          <= IDLE;
                  end if;
                  
               when FILL =>
                  if (ram_done = '1') then
                     state          <= IDLE;
                     tag_wren_a     <= '1';
                     tag_data_a     <= '1' & std_logic_vector(fill_addrData(31 downto 12));
                     tag_address_a  <= std_logic_vector(fill_addrTag_sav(12 downto 5));
                     fill_done      <= '1'; 
                  end if;
                  
            end case;  
            
         end if;

      end if;
   end process;

   
end architecture;




























