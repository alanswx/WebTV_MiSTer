-----------------------------------------------------------------
-- WebTV SOLO1: system units
--   busUnit  0x0000  chip id/control, interrupt fabric (bus/gpio/aud/dev/vid/rio/tim groups),
--                    error/fence registers, TCOUNT/TCOMPARE system timer, reset cause
--   romUnit  0x1000  SYSCONFIG, ROM control
--   devUnit  0x4000  LED, DS2401 serial id (bit-banged), IIC pins, GPIO
--                    (IR 0x000/0x020-0x02c and parallel port 0x200-0x22f are external units;
--                    the IIC devices are in webtv_iic.vhd)
--   memUnit  0x5000  SDRAM control (stored only)
--   sucUnit  0xA000  debug serial (TX byte out, RX FIFO)
-- Behaviour follows the webtv-bridge JS model (src/machine/solo.js), which is the golden
-- reference in the lock-step testbench; register semantics are from the SOLO1 spec.
--
-- Bus: word access from webtv_memmux (bus_addr = offset in the SOLO window, word aligned,
-- big-endian data, bus_be(3) = byte at offset 0). `handles` says (combinationally, from bus_addr)
-- whether this block answers the address; everything else in the SOLO window goes to the other
-- units (video, audio, IR, parallel port, IIC devices).
--
-- Interrupt groups use the SOLO set/clear convention: write the stat/enable register to set
-- bits, the +0x100 alias to clear them. Peripherals raise group bits with the *_set inputs.
--
-- TCOUNT counts the LC2 bus clock. It is kept as a 33-bit half-tick counter on clk93:
-- tc_inc2 (bus_tick) adds 2, tc_inc1 adds 1 (lock-step test mode: one half tick per instruction,
-- like the JS model where TCOUNT = cycles / 2). The timer fires once per TCOMPARE write, when the
-- half-tick counter reaches TCOMPARE * 2 + (the counter's parity at the write) -- the exact point
-- where the JS model's scheduled event fires.
--
-- init_*: raw state load (JS snapshots) and, in the testbench, forcing of the interrupt state
-- owned by units that are not in RTL yet. Offsets as the registers; extras: 0x0048 TCOUNT
-- half-tick counter, 0x0050 bit0 timer parity / bit1 timer armed / bit2 watchdog enabled,
-- 0x0008 busStatSoft, 0x4008 SSID state (idCntl | state << 4 | bit << 8 | bitIdx << 16).
-----------------------------------------------------------------
library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

entity webtv_solo_sys is
   generic
   (
      CHIP_ID    : std_logic_vector(31 downto 0) := x"03120000";
      SYS_CONFIG : std_logic_vector(31 downto 0) := x"003f8700"
   );
   port
   (
      clk1x         : in  std_logic;
      clk93         : in  std_logic;
      reset         : in  std_logic;                       -- clk1x
      cold_reset    : in  std_logic := '0';                -- power-on / front-panel reset: back to the
                                                           -- power-up state (JS Solo.reset(), resetCause 1)

      bus_addr      : in  unsigned(15 downto 0);
      bus_read      : in  std_logic;
      bus_write     : in  std_logic;
      bus_be        : in  std_logic_vector(3 downto 0);
      bus_dataWrite : in  std_logic_vector(31 downto 0);
      bus_dataRead  : out std_logic_vector(31 downto 0) := (others => '0');
      bus_done      : out std_logic := '0';
      handles       : out std_logic;                      -- from bus_addr/bus_write, valid with the strobes

      irq           : out std_logic;                       -- to the CPU (Int0 / IP2)

      -- interrupt sources from the other units (one-cycle pulses, clk1x)
      gpio_set      : in  std_logic_vector(31 downto 0) := (others => '0');
      aud_set       : in  std_logic_vector(7 downto 0) := (others => '0');
      dev_set       : in  std_logic_vector(7 downto 0) := (others => '0');
      vid_set       : in  std_logic_vector(7 downto 0) := (others => '0');
      rio_set       : in  std_logic_vector(7 downto 0) := (others => '0');
      rio_clr       : in  std_logic_vector(7 downto 0) := (others => '0'); -- IntGroup.lower (IDE setIrq(false))
      dev_level     : in  std_logic_vector(7 downto 0) := (others => '0'); -- re-raise after a clear while still active
      rio_level     : in  std_logic_vector(7 downto 0) := (others => '0');
      aud_cleared   : out std_logic_vector(7 downto 0) := (others => '0');
      vid_cleared   : out std_logic_vector(7 downto 0) := (others => '0');
      vid_load      : in  std_logic := '0';                -- video unit: BUS_VIDINTSTAT <= vid_level
      vid_level     : in  std_logic_vector(7 downto 0) := (others => '0');
      vid_en_set    : in  std_logic_vector(7 downto 0) := (others => '0'); -- and BUS_INTEN.video
      modem7e_set   : in  std_logic := '0';                -- see the modem7e note below

      -- system timer ticks (clk93)
      tc_inc1       : in  std_logic := '0';
      tc_inc2       : in  std_logic := '0';

      soft_reset    : out std_logic := '0';                -- RESETCAUSE write with the software bit
      led           : out std_logic_vector(31 downto 0);
      gpio_out      : out std_logic_vector(31 downto 0);
      gpio_en       : out std_logic_vector(31 downto 0);
      gpio_in       : in  std_logic_vector(31 downto 0) := (others => '1');
      iic_cntl      : out std_logic_vector(4 downto 1);    -- 4 CLKOEN, 3 CLKO, 2 DATAOEN, 1 DATAO
      iic_scl       : in  std_logic := '1';
      iic_sda       : in  std_logic := '1';
      serial_id     : in  std_logic_vector(63 downto 0);   -- DS2401 ROM, byte 0 in bits 7:0
      dbg_tx        : out std_logic := '0';
      dbg_tx_data   : out std_logic_vector(7 downto 0) := (others => '0');
      dbg_rx        : in  std_logic := '0';
      dbg_rx_data   : in  std_logic_vector(7 downto 0) := (others => '0');

      init_we       : in  std_logic := '0';
      init_addr     : in  unsigned(15 downto 0) := (others => '0');
      init_data     : in  std_logic_vector(31 downto 0) := (others => '0')
   );
end entity;

architecture arch of webtv_solo_sys is

   subtype word is std_logic_vector(31 downto 0);
   type tWords is array(natural range <>) of word;

   constant B_VIDEO : integer := 7;
   constant B_AUDIO : integer := 6;
   constant B_RIO   : integer := 5;
   constant B_DEV   : integer := 4;
   constant B_TIMER : integer := 3;
   constant B_FENCE : integer := 2;

   -- busUnit
   signal chpcntl     : word := x"0001ffff";
   signal wdEnable    : std_logic := '0';
   signal busEn       : word := (others => '0');
   signal busStatSoft : word := (others => '0');
   signal errStat     : word := (others => '0');
   signal errEn       : word := (others => '0');
   signal fence       : tWords(0 to 4) := (others => (others => '0'));
   signal wdValue     : word := (others => '0');
   signal lowRW       : tWords(0 to 3) := (others => (others => '0'));
   signal tcompare    : word := (others => '0');
   signal tparity     : std_logic := '0';
   signal tarmed      : std_logic := '0';
   signal gpioStat, gpioEnI, gpioPol : word := (others => '0');
   signal audStat, audEn : word := (others => '0');
   signal devStat, devEn : word := (others => '0');
   signal vidStat, vidEn : word := (others => '0');
   signal rioStat, rioEn, rioPol : word := (others => '0');
   signal timStat, timEn : word := (others => '0');
   signal resetCause  : word := x"00000001";               -- RESETCAUSE_SWITCH
   signal jfence      : tWords(0 to 3) := (others => (others => '0'));
   signal bootMode, useBootMode : word := (others => '0');
   signal modem7e     : std_logic := '0';

   -- romUnit / memUnit
   signal romCntl0, romCntl1 : word := (others => '0');
   signal memRegs     : tWords(0 to 4) := (x"00000003", x"00000400", x"00000000", x"00000000", x"adbadffa");

   -- devUnit
   signal ledR        : word := (others => '1');
   signal nvCntl      : std_logic_vector(4 downto 1) := (others => '0');
   signal gpioOutR, gpioEnR : word := (others => '0');
   constant SSID_IDLE : integer := 0; constant SSID_RESET : integer := 1; constant SSID_PRESENCE : integer := 2;
   constant SSID_COMMAND : integer := 3; constant SSID_READROM : integer := 4; constant SSID_PULSESTART : integer := 5;
   constant SSID_PULSEEND : integer := 6; constant SSID_BIT : integer := 7;
   signal idCntl      : std_logic := '0';                   -- bit 1 of DEV_IDCNTL
   signal idState     : integer range 0 to 7 := SSID_IDLE;
   signal idBit       : std_logic := '0';
   signal idBitIdx    : integer range 0 to 63 := 0;

   -- sucUnit RX FIFO
   type tFifo is array(0 to 15) of std_logic_vector(7 downto 0);
   signal rxFifo      : tFifo;
   signal rxWr, rxRd  : unsigned(3 downto 0) := (others => '0');
   signal rxCount     : unsigned(4 downto 0) := (others => '0');

   -- TCOUNT (clk93)
   signal hc          : unsigned(32 downto 0) := (others => '0');
   signal hcInit      : unsigned(32 downto 0) := (others => '0');
   signal hcInitTgl   : std_logic := '0';
   signal hcInitTgl93 : std_logic := '0';
   signal fireTgl     : std_logic := '0';
   signal fireTgl1x   : std_logic := '0';

   signal busStatW    : word;
   signal devStatEff  : word;

   function active(stat, en : word) return std_logic is
   begin
      if (stat and en) /= x"00000000" then return '1'; end if;
      return '0';
   end function;

   signal rRead, rWrite : std_logic := '0';
   signal rAddr  : unsigned(15 downto 0) := (others => '0');
   signal rBe    : std_logic_vector(3 downto 0) := (others => '0');
   signal rData  : std_logic_vector(31 downto 0) := (others => '0');

   function handled(a : unsigned(15 downto 0); wr : std_logic) return std_logic is
      variable o : integer;
   begin
      o := to_integer(a(11 downto 0));
      case to_integer(a(15 downto 12)) is
         when 16#0# | 16#1# | 16#5# | 16#A# => return '1';
         when 16#4# =>
            if o = 16#000# or (o >= 16#020# and o < 16#030#) or (o >= 16#200# and o < 16#230#) then
               return '0';
            end if;
            return '1';
         when others => return '0';
      end case;
   end function;

begin

   handles  <= handled(bus_addr, bus_write);

   -- requests are registered once (timing: the register decode starts from flip-flops)
   process (clk1x)
   begin
      if rising_edge(clk1x) then
         rRead  <= bus_read;
         rWrite <= bus_write;
         rAddr  <= bus_addr;
         rBe    <= bus_be;
         rData  <= bus_dataWrite;
      end if;
   end process;
   led      <= ledR;
   gpio_out <= gpioOutR;
   gpio_en  <= gpioEnR;
   iic_cntl <= nvCntl;

   -- the gpio group feeds dev bit 7 (DEV_INT_GPIO) as a level
   devStatEff <= devStat(31 downto 8) & active(gpioStat, gpioEnI) & devStat(6 downto 0);

   process (all)
      variable s : word;
   begin
      s := busStatSoft;
      s(B_VIDEO) := s(B_VIDEO) or active(vidStat, vidEn);
      s(B_AUDIO) := s(B_AUDIO) or active(audStat, audEn);
      s(B_RIO)   := s(B_RIO)   or active(rioStat, rioEn);
      s(B_DEV)   := s(B_DEV)   or active(devStatEff, devEn);
      s(B_TIMER) := s(B_TIMER) or active(timStat, timEn);
      s(B_FENCE) := s(B_FENCE) or active(errStat, errEn);
      busStatW <= s;
   end process;

   irq <= active(busStatW, busEn);

   ---------------------------------------------------------------- TCOUNT / timer (clk93)
   process (clk93)
      variable n : unsigned(32 downto 0);
   begin
      if rising_edge(clk93) then
         n := hc;
         if (tc_inc1 = '1') then n := hc + 1; end if;
         if (tc_inc2 = '1') then n := hc + 2; end if;
         hc <= n;
         if ((tc_inc1 = '1' or tc_inc2 = '1') and tarmed = '1' and n = unsigned(tcompare) & tparity) then
            fireTgl <= not fireTgl;
         end if;
         hcInitTgl93 <= hcInitTgl;
         if (hcInitTgl93 /= hcInitTgl) then
            hc <= hcInit;
         end if;
      end if;
   end process;

   ---------------------------------------------------------------- registers (clk1x)
   process (clk1x)
      variable o   : integer;
      variable v   : word;
      variable r   : word;
      variable seq, old : unsigned(1 downto 0);
   begin
      if rising_edge(clk1x) then

         bus_done    <= '0';
         soft_reset  <= '0';
         dbg_tx      <= '0';
         aud_cleared <= (others => '0');
         vid_cleared <= (others => '0');

         -- sources
         gpioStat <= gpioStat or gpio_set;
         audStat  <= audStat or (x"000000" & aud_set);
         devStat  <= devStat or (x"000000" & dev_set);
         vidStat  <= vidStat or (x"000000" & vid_set);
         rioStat  <= (rioStat and not (x"000000" & rio_clr)) or (x"000000" & rio_set);
         if (modem7e_set = '1') then modem7e <= '1'; end if;

         fireTgl1x <= fireTgl;
         if (fireTgl1x /= fireTgl) then
            timStat(3) <= '1';
            tarmed     <= '0';
         end if;

         if (dbg_rx = '1' and rxCount < 16) then
            rxFifo(to_integer(rxWr)) <= dbg_rx_data;
            rxWr    <= rxWr + 1;
            rxCount <= rxCount + 1;
         end if;

         o := to_integer(rAddr(11 downto 0));
         v := rData;
         for b in 0 to 3 loop
            if (rBe(b) = '0') then v(8 * b + 7 downto 8 * b) := x"00"; end if;
         end loop;

         ------------------------------------------------ reads
         if (rRead = '1') then
            bus_done <= '1';
            r := (others => '0');
            case to_integer(rAddr(15 downto 12)) is
               when 16#0# =>
                  case o is
                     when 16#000# => r := CHIP_ID;
                     when 16#004# => r := chpcntl;
                     when 16#008# | 16#108# =>
                        if (modem7e = '1') then modem7e <= '0'; r := x"00000001";
                        else r := busStatW and busEn; end if;
                     when 16#050# => r := busStatW;
                     when 16#00C# | 16#10C# => r := busEn;
                     when 16#010# | 16#110# | 16#054# => r := errStat;
                     when 16#014# | 16#114# => if (modem7e = '0') then r := errEn; end if;
                     when 16#01C# => r := fence(0);
                     when 16#020# => r := fence(1);
                     when 16#024# => r := fence(2);
                     when 16#028# => r := fence(3);
                     when 16#02C# => r := fence(4);
                     when 16#030# => r := wdValue;
                     when 16#034# => r := lowRW(0);
                     when 16#038# => r := lowRW(1);
                     when 16#03C# => r := lowRW(2);
                     when 16#040# => r := lowRW(3);
                     when 16#048# => r := std_logic_vector(hc(32 downto 1));
                     when 16#04C# => r := tcompare;
                     when 16#058# | 16#060# | 16#158# => r := gpioStat;
                     when 16#05C# | 16#15C# => r := gpioEnI;
                     when 16#064# => r := gpioPol;
                     when 16#068# | 16#06C# | 16#168# => r := audStat;
                     when 16#070# | 16#170# => r := audEn;
                     when 16#074# | 16#078# | 16#174# => r := devStatEff;
                     when 16#07C# | 16#17C# => r := devEn;
                     when 16#080# | 16#084# | 16#180# => r := vidStat;
                     when 16#088# | 16#188# => r := vidEn;
                     when 16#08C# | 16#090# | 16#18C# => r := rioStat;
                     when 16#094# => r := rioPol;
                     when 16#098# | 16#198# => r := rioEn;
                     when 16#09C# | 16#0A0# | 16#19C# => r := timStat;
                     when 16#0A4# | 16#1A4# => r := timEn;
                     when 16#0A8# => r := resetCause;
                     when 16#0B0# => r := jfence(0);
                     when 16#0B4# => r := jfence(1);
                     when 16#0B8# => r := jfence(2);
                     when 16#0BC# => r := jfence(3);
                     when 16#0C8# => r := bootMode;
                     when 16#0CC# => r := useBootMode;
                     when others => null;
                  end case;
               when 16#1# =>
                  case o is
                     when 16#000# => r := SYS_CONFIG;
                     when 16#004# => r := romCntl0;
                     when 16#008# => r := romCntl1;
                     when others => null;
                  end case;
               when 16#4# =>
                  case o is
                     when 16#004# => r := ledR;
                     when 16#008# =>
                        -- DS2401 read slot (timing ignored, as in the JS/MAME models)
                        idBit <= '0';
                        r(1) := idCntl;
                        if (idState = SSID_PRESENCE) then
                           idState <= SSID_COMMAND; idBitIdx <= 0;
                        elsif (idState = SSID_PULSEEND) then
                           idState <= SSID_BIT;
                        elsif (idState = SSID_BIT) then
                           idState <= SSID_READROM;
                           r(0)  := serial_id(idBitIdx);
                           idBit <= serial_id(idBitIdx);
                           if (idBitIdx = 63) then idState <= SSID_IDLE; idBitIdx <= 0;
                           else idBitIdx <= idBitIdx + 1; end if;
                        end if;
                     when 16#00C# => r := 26x"0" & iic_scl & nvCntl(4 downto 1) & iic_sda;
                     when 16#010# => r := (gpio_in and not gpioEnR) or (gpioOutR and gpioEnR);
                     when 16#014# | 16#114# => r := gpioOutR;
                     when 16#018# | 16#118# => r := gpioEnR;
                     when others => null;
                  end case;
               when 16#5# =>
                  case o is
                     when 16#000# => r := memRegs(0);
                     when 16#004# => r := memRegs(1);
                     when 16#008# => r := memRegs(2);
                     when 16#00C# => r := memRegs(3);
                     when 16#010# => r := memRegs(4);
                     when others => null;
                  end case;
               when 16#A# =>
                  case o is
                     when 16#010# => r := x"00000100";                         -- TFFMAX (TX always drained)
                     when 16#040# =>                                           -- RFFHR
                        if (rxCount /= 0) then
                           r := x"000000" & rxFifo(to_integer(rxRd));
                           rxRd    <= rxRd + 1;
                           rxCount <= rxCount - 1;
                           if (dbg_rx = '1') then rxCount <= rxCount; end if;
                        end if;
                     when 16#04C# => r := 27x"0" & std_logic_vector(rxCount);  -- RFFCNT
                     when 16#050# => r := x"00000100";                         -- RFFMAX
                     when 16#AB8# => r := x"00000010";                         -- SUCSC0_GPIOVAL
                     when others => null;
                  end case;
               when others => null;
            end case;
            bus_dataRead <= r;
         end if;

         ------------------------------------------------ writes
         if (rWrite = '1') then
            bus_done <= '1';
            case to_integer(rAddr(15 downto 12)) is
               when 16#0# =>
                  case o is
                     when 16#004# =>
                        seq := unsigned(v(31 downto 30)); old := unsigned(chpcntl(31 downto 30));
                        if (seq /= old) then
                           if (wdEnable = '0' and seq = 3) then wdEnable <= '1';
                           elsif (wdEnable = '1' and seq = 0) then wdEnable <= '0'; end if;
                        end if;
                        chpcntl <= v;
                     when 16#008# | 16#050# => busStatSoft(7 downto 0) <= busStatSoft(7 downto 0) or v(7 downto 0);
                     when 16#108# =>
                        busStatSoft <= busStatSoft and not v;
                        if (v(B_TIMER) = '1') then timStat <= (others => '0'); end if;
                     when 16#00C# => busEn <= busEn or v;
                     when 16#10C# => busEn <= busEn and not v;
                     when 16#010# | 16#054# => errStat(7 downto 0) <= errStat(7 downto 0) or v(7 downto 0);
                     when 16#110# => errStat <= errStat and not v;
                     when 16#014# => errEn(7 downto 0) <= errEn(7 downto 0) or v(7 downto 0);
                     when 16#114# => errEn <= errEn and not v;
                     when 16#01C# => fence(0) <= v;
                     when 16#020# => fence(1) <= v;
                     when 16#024# => fence(2) <= v;
                     when 16#028# => fence(3) <= v;
                     when 16#02C# => fence(4) <= v;
                     when 16#030# => wdValue <= v;
                     when 16#034# => lowRW(0) <= v;
                     when 16#038# => lowRW(1) <= v;
                     when 16#03C# => lowRW(2) <= v;
                     when 16#040# => lowRW(3) <= v;
                     when 16#04C# =>
                        tcompare   <= v;
                        tparity    <= hc(0);
                        if (v /= x"00000000") then tarmed <= '1'; else tarmed <= '0'; end if;
                        timStat(3) <= '0';
                     when 16#058# | 16#060# => gpioStat <= gpioStat or v or gpio_set;
                     when 16#158# => gpioStat <= gpioStat and not v;
                     when 16#05C# =>
                        gpioEnI <= gpioEnI or v;
                        if ((gpioEnI or v) /= x"00000000") then
                           devEn(7) <= '1'; busEn(B_DEV) <= '1';
                        end if;
                     when 16#15C# => gpioEnI <= gpioEnI and not v;
                     when 16#064# => gpioPol <= v;
                     when 16#068# | 16#06C# => audStat <= audStat or v;
                     when 16#168# => audStat <= audStat and not v; aud_cleared <= v(7 downto 0);
                     when 16#070# =>
                        audEn <= audEn or v;
                        if ((audEn or v) /= x"00000000") then busEn(B_AUDIO) <= '1'; end if;
                     when 16#170# => audEn <= audEn and not v;
                     when 16#074# | 16#078# => devStat <= devStat or v;
                     when 16#174# => devStat <= (devStat and not v) or (x"000000" & (v(7 downto 0) and dev_level));
                     when 16#07C# =>
                        devEn <= devEn or v;
                        if ((devEn or v) /= x"00000000") then busEn(B_DEV) <= '1'; end if;
                     when 16#17C# => devEn <= devEn and not v;
                     when 16#080# | 16#084# => vidStat <= vidStat or v;
                     when 16#180# => vidStat <= vidStat and not v; vid_cleared <= v(7 downto 0);
                     when 16#088# => vidEn <= vidEn or v;
                     when 16#188# => vidEn <= vidEn and not v;
                     when 16#08C# | 16#090# => rioStat <= rioStat or v;
                     when 16#18C# => rioStat <= (rioStat and not v) or (x"000000" & (v(7 downto 0) and rio_level));
                     when 16#094# => rioPol <= v;
                     when 16#098# =>
                        rioEn <= rioEn or v;
                        if ((rioEn or v) /= x"00000000") then busEn(B_RIO) <= '1'; end if;
                     when 16#198# => rioEn <= rioEn and not v;
                     when 16#09C# | 16#0A0# => timStat <= timStat or v;
                     when 16#19C# => timStat <= timStat and not v;
                     when 16#0A4# =>
                        timEn <= timEn or v;
                        if ((timEn or v) /= x"00000000") then busEn(B_TIMER) <= '1'; end if;
                     when 16#1A4# => timEn <= timEn and not v;
                     when 16#0A8# =>
                        if (v(2) = '1') then
                           resetCause <= 29x"0" & v(2 downto 0);
                           soft_reset <= '1';
                        else
                           resetCause <= resetCause or v;
                        end if;
                     when 16#0AC# => resetCause <= resetCause and not v;
                     when 16#0B0# => jfence(0) <= v;
                     when 16#0B4# => jfence(1) <= v;
                     when 16#0B8# => jfence(2) <= v;
                     when 16#0BC# => jfence(3) <= v;
                     when 16#0C8# => bootMode <= v;
                     when 16#0CC# => useBootMode <= v;
                     when others => null;                                      -- incl. 0x118 watchdog kick
                  end case;
               when 16#1# =>
                  case o is
                     when 16#004# => romCntl0 <= v;
                     when 16#008# => romCntl1 <= v;
                     when others => null;
                  end case;
               when 16#4# =>
                  case o is
                     when 16#004# => ledR <= v;
                     when 16#008# =>
                        idCntl <= v(1);
                        if (v(1) = '1') then
                           if (idState = SSID_RESET) then idState <= SSID_PRESENCE;
                           elsif (idState = SSID_COMMAND) then
                              if (idBitIdx = 7) then idState <= SSID_READROM; idBitIdx <= 0;
                              else idBitIdx <= idBitIdx + 1; end if;
                           elsif (idState = SSID_PULSESTART) then idState <= SSID_PULSEEND;
                           end if;
                        else
                           if (idState = SSID_IDLE) then idState <= SSID_RESET;
                           elsif (idState = SSID_READROM) then idState <= SSID_PULSESTART;
                           end if;
                        end if;
                     when 16#00C# => nvCntl <= v(4 downto 1);
                     when 16#014# => gpioOutR <= gpioOutR or v;
                     when 16#114# => gpioOutR <= gpioOutR and not v;
                     when 16#018# => gpioEnR <= gpioEnR or v;
                     when 16#118# => gpioEnR <= gpioEnR and not v;
                     when others => null;
                  end case;
               when 16#5# =>
                  case o is
                     when 16#000# => memRegs(0) <= v;
                     when 16#004# => memRegs(1) <= v;
                     when 16#008# => memRegs(2) <= v;
                     when 16#00C# => memRegs(3) <= v;
                     when 16#010# => memRegs(4) <= v;
                     when others => null;
                  end case;
               when 16#A# =>
                  if (o = 16#000#) then                                        -- TFFHR
                     dbg_tx      <= '1';
                     dbg_tx_data <= v(7 downto 0);
                  end if;
               when others => null;
            end case;
         end if;

         ------------------------------------------------ video unit summary (JS SoloVideo.updateSummary / enableSummary)
         if (vid_load = '1') then
            vidStat <= x"000000" & vid_level;
         end if;
         if (vid_en_set /= x"00") then
            vidEn(7 downto 0) <= vidEn(7 downto 0) or vid_en_set;
            busEn(B_VIDEO)    <= '1';
         end if;

         ------------------------------------------------ raw state load / force (snapshots, testbench)
         if (cold_reset = '1') then
            chpcntl <= x"0001ffff"; wdEnable <= '0'; wdValue <= (others => '0');
            busEn <= (others => '0'); busStatSoft <= (others => '0');
            errStat <= (others => '0'); errEn <= (others => '0');
            fence <= (others => (others => '0')); lowRW <= (others => (others => '0'));
            jfence <= (others => (others => '0'));
            tcompare <= (others => '0'); tarmed <= '0';
            gpioStat <= (others => '0'); gpioEnI <= (others => '0'); gpioPol <= (others => '0');
            audStat <= (others => '0'); audEn <= (others => '0');
            devStat <= (others => '0'); devEn <= (others => '0');
            vidStat <= (others => '0'); vidEn <= (others => '0');
            rioStat <= (others => '0'); rioEn <= (others => '0'); rioPol <= (others => '0');
            timStat <= (others => '0'); timEn <= (others => '0');
            resetCause <= x"00000001";
            bootMode <= (others => '0'); useBootMode <= (others => '0');
            modem7e <= '0';
            romCntl0 <= (others => '0'); romCntl1 <= (others => '0');
            memRegs <= (x"00000003", x"00000400", x"00000000", x"00000000", x"adbadffa");
            ledR <= (others => '1'); nvCntl <= (others => '0');
            gpioOutR <= (others => '0'); gpioEnR <= (others => '0');
            idCntl <= '0'; idState <= SSID_IDLE;
            rxWr <= (others => '0'); rxRd <= (others => '0'); rxCount <= (others => '0');
         end if;

         if (init_we = '1') then
            v := init_data;
            case to_integer(init_addr) is
               when 16#0004# => chpcntl <= v;
               when 16#0008# => busStatSoft <= v;
               when 16#000C# => busEn <= v;
               when 16#0010# => errStat <= v;
               when 16#0014# => errEn <= v;
               when 16#001C# => fence(0) <= v;
               when 16#0020# => fence(1) <= v;
               when 16#0024# => fence(2) <= v;
               when 16#0028# => fence(3) <= v;
               when 16#002C# => fence(4) <= v;
               when 16#0030# => wdValue <= v;
               when 16#0034# => lowRW(0) <= v;
               when 16#0038# => lowRW(1) <= v;
               when 16#003C# => lowRW(2) <= v;
               when 16#0040# => lowRW(3) <= v;
               when 16#0048# => hcInit <= '0' & unsigned(v); hcInitTgl <= not hcInitTgl;
               when 16#004C# => tcompare <= v;
               when 16#0050# => tparity <= v(0); tarmed <= v(1); wdEnable <= v(2);
               when 16#0058# => gpioStat <= v;
               when 16#005C# => gpioEnI <= v;
               when 16#0064# => gpioPol <= v;
               when 16#0068# => audStat <= v;
               when 16#0070# => audEn <= v;
               when 16#0074# => devStat <= v;
               when 16#007C# => devEn <= v;
               when 16#0080# => vidStat <= v;
               when 16#0088# => vidEn <= v;
               when 16#008C# => rioStat <= v;
               when 16#0094# => rioPol <= v;
               when 16#0098# => rioEn <= v;
               when 16#0F8C# => rioStat <= (rioStat and x"00000008") or (v and x"FFFFFFF7");   -- all but the IDE (RTL) bit
               when 16#009C# => timStat <= v;
               when 16#00A4# => timEn <= v;
               when 16#00A8# => resetCause <= v;
               when 16#00B0# => jfence(0) <= v;
               when 16#00B4# => jfence(1) <= v;
               when 16#00B8# => jfence(2) <= v;
               when 16#00BC# => jfence(3) <= v;
               when 16#00C8# => bootMode <= v;
               when 16#00CC# => useBootMode <= v;
               when 16#1004# => romCntl0 <= v;
               when 16#1008# => romCntl1 <= v;
               when 16#4004# => ledR <= v;
               when 16#4008# =>
                  idCntl   <= v(1);
                  idState  <= to_integer(unsigned(v(6 downto 4)));
                  idBit    <= v(8);
                  idBitIdx <= to_integer(unsigned(v(21 downto 16)));
               when 16#400C# => nvCntl <= v(4 downto 1);
               when 16#4014# => gpioOutR <= v;
               when 16#4018# => gpioEnR <= v;
               when 16#5000# => memRegs(0) <= v;
               when 16#5004# => memRegs(1) <= v;
               when 16#5008# => memRegs(2) <= v;
               when 16#500C# => memRegs(3) <= v;
               when 16#5010# => memRegs(4) <= v;
               when others => null;
            end case;
         end if;

         if (reset = '1') then
            -- registers keep their values across a CPU reset except what the JS model's
            -- Solo.reset() sets at power-up; power-up state comes from the signal defaults
            null;
         end if;

      end if;
   end process;

end architecture;
