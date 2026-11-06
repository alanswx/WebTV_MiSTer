-----------------------------------------------------------------
-- LC2 hardware-modem UART (NS16550 at 0x1E000000, 4-byte register stride), host side as the
-- webtv-bridge JS model (src/machine/uart16550.js); the line side is a real 8N1 serial port
-- (MiSTer UART pins -> the HPS, where the modem / PPP side runs).
--
-- Register semantics follow the JS model: IIR priorities (line status, RX data, THR empty,
-- modem status), THR-empty pending set by a TX write or by enabling ETBEI and cleared by an
-- IIR read that reports it, LSR read clears the extra bits (never set here), MSR read clears
-- the deltas, FCR bit 1 clears the RX FIFO.
-- Differences (the JS line side is instantaneous): TX bytes queue in a 2 KB FIFO towards the
-- pins; while it is 3/4 full, LSR THRE/TEMT read 0 and a TX write leaves THR-empty pending
-- until it drains, so software that waits for THRE / the interrupt does not overrun the line.
-- MSR: DSR and CTS are on (as the JS modem reports them), DCD = line_dcd, RI off.
--
-- The interrupt is RIO device 0 (irq_set / irq_clr on changes, irq_level for the re-raise);
-- a data read of 0x7E sets the SOLO's modem7e workaround flag (modem7e pulse), as the JS bus hook.
-----------------------------------------------------------------
library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

entity webtv_uart16550 is
   generic
   (
      CLK_HZ : natural := 62500000;
      BAUD   : natural := 115200
   );
   port
   (
      clk1x         : in  std_logic;
      reset         : in  std_logic;

      bus_addr      : in  unsigned(31 downto 0);
      bus_read      : in  std_logic;
      bus_write     : in  std_logic;
      bus_dataWrite : in  std_logic_vector(31 downto 0);
      bus_dataRead  : out std_logic_vector(31 downto 0) := (others => '0');
      bus_done      : out std_logic := '0';
      handles       : out std_logic;

      irq_set       : out std_logic := '0';
      irq_clr       : out std_logic := '0';
      irq_level     : out std_logic;
      modem7e       : out std_logic := '0';

      -- line side
      line_txd      : out std_logic := '1';
      line_rxd      : in  std_logic := '1';
      line_dcd      : in  std_logic := '0';
      line_rts_n    : out std_logic := '0';      -- '1': RX FIFO 3/4 full, hold off
      mcr_out       : out std_logic_vector(7 downto 0)
   );
end entity;

architecture arch of webtv_uart16550 is

   constant BAUD_DIV : natural := (CLK_HZ + BAUD / 2) / BAUD;

   signal ier      : std_logic_vector(3 downto 0) := (others => '0');
   signal lcr, mcr, scr, dll, dlm, fcr : std_logic_vector(7 downto 0) := (others => '0');
   signal msr      : std_logic_vector(7 downto 0) := x"33";
   signal thrPend  : std_logic := '0';
   signal thrLater : std_logic := '0';        -- THR-empty pending once the TX FIFO drains
   signal irq      : std_logic := '0';
   signal dcd_1    : std_logic := '0';

   -- RX FIFO (256)
   type tFifo is array(natural range <>) of std_logic_vector(7 downto 0);
   signal rxFifo   : tFifo(0 to 255);
   signal rxWr, rxRd : unsigned(7 downto 0) := (others => '0');
   signal rxCount  : unsigned(8 downto 0) := (others => '0');
   -- TX FIFO (2048, block RAM)
   signal txWe     : std_logic := '0';
   signal txWA     : unsigned(10 downto 0) := (others => '0');
   signal txWD     : std_logic_vector(7 downto 0) := (others => '0');
   signal txRA     : unsigned(10 downto 0) := (others => '0');
   signal txQ      : std_logic_vector(7 downto 0);
   signal txCount  : unsigned(11 downto 0) := (others => '0');
   signal txFull   : std_logic;

   -- bit engines
   signal tShift   : std_logic_vector(9 downto 0) := (others => '1');
   signal tBits    : integer range 0 to 10 := 0;
   signal tCnt     : integer range 0 to BAUD_DIV := 0;
   signal tWait    : integer range 0 to 2 := 0;
   signal txTail   : unsigned(10 downto 0) := (others => '0');
   signal rSync    : std_logic_vector(2 downto 0) := "111";
   signal rActive  : std_logic := '0';
   signal rCnt     : integer range 0 to 2 * BAUD_DIV := 0;
   signal rBits    : integer range 0 to 9 := 0;
   signal rShift   : std_logic_vector(7 downto 0) := (others => '0');

   function iirOf(ier_v : std_logic_vector(3 downto 0); rxNe, thr : std_logic; msr_v, fcr_v : std_logic_vector(7 downto 0))
      return std_logic_vector is
      variable f : std_logic_vector(7 downto 0);
   begin
      if (fcr_v(0) = '1') then f := x"C0"; else f := x"00"; end if;
      if (ier_v(0) = '1' and rxNe = '1') then return f or x"04"; end if;
      if (ier_v(1) = '1' and thr = '1') then return f or x"02"; end if;
      if (ier_v(3) = '1' and msr_v(3 downto 0) /= "0000") then return f; end if;
      return f or x"01";
   end function;

begin

   handles    <= '1' when bus_addr(31 downto 5) = x"1E00000" & "000" else '0';
   irq_level  <= irq;
   mcr_out    <= mcr;
   txFull     <= '1' when txCount >= 1536 else '0';
   line_rts_n <= '1' when rxCount >= 192 else '0';

   itx : entity work.webtv_sdpram
   generic map (WIDTH => 8, AW => 11)
   port map (clk => clk1x, we => txWe, waddr => txWA, wdata => txWD, raddr => txRA, q => txQ);

   process (clk1x)
      variable reg   : integer range 0 to 7;
      variable v     : std_logic_vector(7 downto 0);
      variable rxNe  : std_logic;
      variable push, pop, tpush, tpop : boolean;
      variable rb    : std_logic_vector(7 downto 0);
      variable nv, delta : std_logic_vector(7 downto 0);
      variable iirV  : std_logic_vector(7 downto 0);
      variable thrN  : std_logic;
      variable msrN  : std_logic_vector(7 downto 0);
      variable ierN  : std_logic_vector(3 downto 0);
      variable fcrN  : std_logic_vector(7 downto 0);
      variable clearRx : boolean;
   begin
      if rising_edge(clk1x) then
         bus_done <= '0';
         irq_set  <= '0';
         irq_clr  <= '0';
         modem7e  <= '0';
         txWe     <= '0';
         push := false; pop := false; tpush := false; tpop := false; clearRx := false;
         thrN := thrPend; msrN := msr; ierN := ier; fcrN := fcr;
         if (rxCount /= 0) then rxNe := '1'; else rxNe := '0'; end if;

         -- modem status: DCD changes (DSR, CTS stay on)
         dcd_1 <= line_dcd;
         if (line_dcd /= dcd_1) then
            nv    := line_dcd & "0110000";        -- DCD, RI off, DSR, CTS
            msrN  := nv(7 downto 4) & (msr(3 downto 0) or "1000");   -- delta DCD
         end if;

         -- TX FIFO drained below the mark: deliver the deferred THR-empty
         if (thrLater = '1' and txFull = '0') then
            thrN := '1'; thrLater <= '0';
         end if;

         -- registers
         if (bus_read = '1' or bus_write = '1') then
            bus_done <= '1';
            reg := to_integer(bus_addr(4 downto 2));
            v   := bus_dataWrite(7 downto 0);
            if (bus_read = '1') then
               rb := x"00";
               case reg is
                  when 0 =>
                     if (lcr(7) = '1') then rb := dll;
                     elsif (rxNe = '1') then
                        rb := rxFifo(to_integer(rxRd)); pop := true;
                        if (rb = x"7E") then modem7e <= '1'; end if;
                     end if;
                  when 1 => if (lcr(7) = '1') then rb := dlm; else rb := "0000" & ier; end if;
                  when 2 =>
                     rb := iirOf(ier, rxNe, thrPend, msr, fcr);
                     if (rb(3 downto 0) = x"2") then thrN := '0'; end if;
                  when 3 => rb := lcr;
                  when 4 => rb := mcr;
                  when 5 => rb := '0' & not txFull & not txFull & "0000" & rxNe;
                  when 6 => rb := msr; msrN := msrN(7 downto 4) & "0000";
                  when 7 => rb := scr;
               end case;
               bus_dataRead <= x"000000" & rb;
            else
               case reg is
                  when 0 =>
                     if (lcr(7) = '1') then dll <= v;
                     else
                        if (txCount < 2047) then tpush := true; end if;
                        if (txFull = '1') then thrLater <= '1'; else thrN := '1'; end if;
                     end if;
                  when 1 =>
                     if (lcr(7) = '1') then dlm <= v;
                     else
                        if (v(1) = '1' and ier(1) = '0') then thrN := '1'; end if;
                        ierN := v(3 downto 0);
                     end if;
                  when 2 =>
                     fcrN := v;
                     if (v(1) = '1') then clearRx := true; end if;
                  when 3 => lcr <= v;
                  when 4 => mcr <= v;
                  when 5 | 6 => null;
                  when 7 => scr <= v;
               end case;
            end if;
         end if;

         -- line side: TX (the head byte is txQ = mem[txRA] two cycles after it was counted)
         if (tBits = 0) then
            if (txCount /= 0) then
               if (tWait = 2) then
                  tShift <= '1' & txQ & '0';
                  tBits  <= 10;
                  tCnt   <= BAUD_DIV - 1;
                  tpop   := true;
                  tWait  <= 0;
               else
                  tWait <= tWait + 1;
               end if;
            end if;
         elsif (tCnt = 0) then
            tShift <= '1' & tShift(9 downto 1);
            tBits  <= tBits - 1;
            tCnt   <= BAUD_DIV - 1;
         else
            tCnt <= tCnt - 1;
         end if;
         if (tBits = 0) then line_txd <= '1'; else line_txd <= tShift(0); end if;

         -- line side: RX (8N1, sampled mid-bit)
         rSync <= rSync(1 downto 0) & line_rxd;
         if (rActive = '0') then
            if (rSync(2) = '0') then
               rActive <= '1';
               rCnt    <= BAUD_DIV + BAUD_DIV / 2 - 1;
               rBits   <= 0;
            end if;
         elsif (rCnt = 0) then
            if (rBits = 8) then
               rActive <= '0';
               if (rSync(2) = '1' and rxCount < 256) then push := true; end if;
            else
               rShift <= rSync(2) & rShift(7 downto 1);
               rBits  <= rBits + 1;
               rCnt   <= BAUD_DIV - 1;
            end if;
         else
            rCnt <= rCnt - 1;
         end if;

         -- FIFOs
         if clearRx then
            rxWr <= (others => '0'); rxRd <= (others => '0'); rxCount <= (others => '0');
            rxNe := '0';
         else
            if push then rxFifo(to_integer(rxWr)) <= rShift; rxWr <= rxWr + 1; end if;
            if pop then rxRd <= rxRd + 1; end if;
            if (push and not pop) then
               rxCount <= rxCount + 1; rxNe := '1';
            elsif (pop and not push) then
               rxCount <= rxCount - 1;
               if (rxCount = 1) then rxNe := '0'; end if;
            end if;
         end if;
         if tpush then txWe <= '1'; txWA <= txTail; txWD <= v; txTail <= txTail + 1; end if;
         if tpop then txRA <= txRA + 1; end if;
         if (tpush and not tpop) then txCount <= txCount + 1;
         elsif (tpop and not tpush) then txCount <= txCount - 1;
         end if;

         thrPend <= thrN;
         msr     <= msrN;
         ier     <= ierN;
         fcr     <= fcrN;

         -- interrupt line = IIR pending (JS update()) of the new state, set/clear on changes
         iirV := iirOf(ierN, rxNe, thrN, msrN, fcrN);
         if ((not iirV(0)) /= irq) then
            irq <= not iirV(0);
            if (iirV(0) = '0') then irq_set <= '1'; else irq_clr <= '1'; end if;
         end if;

         if (reset = '1') then
            ier <= (others => '0'); lcr <= (others => '0'); mcr <= (others => '0'); scr <= (others => '0');
            dll <= x"01"; dlm <= (others => '0'); fcr <= (others => '0'); msr <= x"33";
            thrPend <= '0'; thrLater <= '0'; irq <= '0';
            rxWr <= (others => '0'); rxRd <= (others => '0'); rxCount <= (others => '0');
            txTail <= (others => '0'); txRA <= (others => '0'); txCount <= (others => '0');
            tBits <= 0; tWait <= 0;
         end if;
      end if;
   end process;

end architecture;
