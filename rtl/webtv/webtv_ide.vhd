-----------------------------------------------------------------
-- WebTV IDE disk (ATA PIO) on the SOLO RIO bus, as the webtv-bridge JS model (src/machine/ide.js)
--
--   cs0: 0x1E400000 + 4*n  (data, error/feature, count, sector, cyl lo, cyl hi, drive/head,
--                           status/command), cs1: 0x1E800018 alt status / device control,
--                           0x1E80001C drive address (reads 0xFF). Other offsets: read 0.
-- Every access is a 32-bit word; register values are in the low bits.
--
-- Backing store: a MiSTer hps_io block device (sd_* ports, WIDE = 16-bit words, 512-byte
-- blocks). Data words follow the ATA convention (word = byte0 | byte1 << 8), the image is the
-- raw drive dump, as for the JS model.
--
-- Commands as the JS model: READ SECTORS / MULTIPLE, WRITE SECTORS / MULTIPLE, READ VERIFY,
-- IDENTIFY, SET MULTIPLE, INIT PARAMS, DIAGNOSTIC, READ NATIVE MAX, CHECK POWER, seek /
-- recalibrate, the accepted no-op commands, SECURITY SET/UNLOCK/ERASE (data block taken, done).
-- The drive is never locked.
--
-- Raw state load (init_*, JS snapshots): 0x0000.. registers (see the init process), 0x1000 + k
-- buffer word k, 0x0010 = a read in progress (restarted from the registers, busy for init_data
-- more instructions).
--
-- Timing: the JS model keeps the drive busy for 2000 CPU instructions after a sector read or
-- write starts (sched.after). With LOCKSTEP = '1' the same count runs on retired instructions
-- (exact replay against JS traces); otherwise the drive is busy until the HPS has moved the
-- data (plus BUSY_MIN clk1x cycles).
--
-- The RIO interrupt (device 1) follows the JS setIrq calls: irq_set when it is raised with
-- nIEN clear, irq_clr when it is lowered (or raised while nIEN is set); irq_level is the line
-- the SOLO re-raises from when software clears its status bit.
-----------------------------------------------------------------
library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

entity webtv_ide is
   generic
   (
      BUSY_INSTR : natural := 2001;   -- JS 2000, + the command store itself (retires after the start)
      BUSY_MIN   : natural := 64
   );
   port
   (
      clk1x            : in  std_logic;
      reset            : in  std_logic;

      -- MMIO (physical word address)
      bus_addr         : in  unsigned(31 downto 0);
      bus_read         : in  std_logic;
      bus_write        : in  std_logic;
      bus_dataWrite    : in  std_logic_vector(31 downto 0);
      bus_dataRead     : out std_logic_vector(31 downto 0) := (others => '0');
      bus_done         : out std_logic := '0';
      handles          : out std_logic;

      irq_set          : out std_logic := '0';
      irq_clr          : out std_logic := '0';
      irq_level        : out std_logic;

      LOCKSTEP         : in  std_logic := '0';
      retired_cnt      : in  unsigned(15 downto 0) := (others => '0');  -- retired CPU instructions (wraps)

      -- block device (hps_io)
      img_mounted      : in  std_logic;
      img_size         : in  unsigned(63 downto 0);
      sd_lba           : out unsigned(31 downto 0) := (others => '0');
      sd_blk_cnt       : out unsigned(5 downto 0) := (others => '0');
      sd_rd            : out std_logic := '0';
      sd_wr            : out std_logic := '0';
      sd_ack           : in  std_logic;
      sd_buff_addr     : in  unsigned(12 downto 0);
      sd_buff_dout     : in  std_logic_vector(15 downto 0);
      sd_buff_din      : out std_logic_vector(15 downto 0);
      sd_buff_wr       : in  std_logic;

      -- raw state load (JS snapshots): see the init process
      init_we          : in  std_logic := '0';
      init_addr        : in  unsigned(15 downto 0) := (others => '0');
      init_data        : in  std_logic_vector(31 downto 0) := (others => '0')
   );
end entity;

architecture arch of webtv_ide is

   constant ST_ERR  : integer := 0;
   constant ST_DRQ  : integer := 3;
   constant ST_DSC  : integer := 4;
   constant ST_DRDY : integer := 6;
   constant ST_BSY  : integer := 7;
   constant S_IDLE  : std_logic_vector(7 downto 0) := x"50";   -- DRDY | DSC
   constant S_DRQ   : std_logic_vector(7 downto 0) := x"58";   -- DRDY | DSC | DRQ
   constant S_BSY   : std_logic_vector(7 downto 0) := x"90";   -- BSY | DSC
   constant S_ERR   : std_logic_vector(7 downto 0) := x"51";   -- DRDY | DSC | ERR
   constant S_IDNF  : std_logic_vector(7 downto 0) := x"41";   -- DRDY | ERR

   -- registers
   signal rError    : std_logic_vector(7 downto 0) := x"01";
   signal rFeature  : std_logic_vector(7 downto 0) := x"00";
   signal rCount    : unsigned(7 downto 0) := x"01";
   signal rSector   : unsigned(7 downto 0) := x"01";
   signal rCylLo    : unsigned(7 downto 0) := x"00";
   signal rCylHi    : unsigned(7 downto 0) := x"00";
   signal rDrvHead  : std_logic_vector(7 downto 0) := x"00";
   signal rStatus   : std_logic_vector(7 downto 0) := x"00";
   signal rDevCtl   : std_logic_vector(7 downto 0) := x"00";
   signal rCmd      : std_logic_vector(7 downto 0) := x"00";
   signal rMultiple : unsigned(4 downto 0) := to_unsigned(1, 5);
   signal irq       : std_logic := '0';

   -- transfer
   signal haveDisk  : std_logic := '0';
   signal total     : unsigned(31 downto 0) := (others => '0');   -- sectors
   signal cyls      : unsigned(15 downto 0) := (others => '0');
   signal bufValid  : std_logic := '0';    -- JS buf != null (read data / IDENTIFY)
   signal wbufValid : std_logic := '0';    -- JS wbuf != null (write data)
   signal secCmd    : std_logic := '0';    -- the write buffer is a SECURITY data block
   signal bufPos    : unsigned(12 downto 0) := (others => '0');   -- bytes
   signal bufLen    : unsigned(13 downto 0) := (others => '0');   -- bytes
   signal xferRemain: unsigned(8 downto 0) := (others => '0');
   signal xferLba   : unsigned(31 downto 0) := (others => '0');
   signal xferN     : unsigned(4 downto 0) := (others => '0');
   signal identMode : std_logic := '0';

   -- sector buffer: 16 sectors x 256 words
   signal bufWe     : std_logic;
   signal bufWA     : unsigned(11 downto 0);
   signal bufWD     : std_logic_vector(15 downto 0);
   signal bufRA     : unsigned(11 downto 0);
   signal bufQ      : std_logic_vector(15 downto 0);
   signal cpuWe     : std_logic := '0';
   signal cpuWA     : unsigned(11 downto 0) := (others => '0');
   signal cpuWD     : std_logic_vector(15 downto 0) := (others => '0');
   signal sdWriting : std_logic := '0';

   -- sequencer
   type tState is (IDLE, RD1, RD2, WR, SETLBA, SETLBA_DIV, START_READ, FINISH, WRITE_START, VERIFY_DONE);
   signal state     : tState := IDLE;
   signal ret       : tState := IDLE;
   signal reqRd     : std_logic := '0';
   signal reqWr     : std_logic := '0';
   signal reqAddr   : unsigned(23 downto 0) := (others => '0');
   signal reqData   : std_logic_vector(31 downto 0) := (others => '0');
   signal lbaArg    : unsigned(31 downto 0) := (others => '0');
   signal divQ, divR: unsigned(31 downto 0) := (others => '0');
   signal divN      : integer range 0 to 32 := 0;
   signal xferPending : std_logic := '0';  -- JS: an ide-read / ide-write event is scheduled
   signal afterRead : std_logic := '0';    -- ... and it is the finish of a read (else of a write)
   signal sdAck1    : std_logic := '0';
   signal busyCnt   : unsigned(15 downto 0) := (others => '0');   -- free-running mode: clk1x cycles
   signal busyStart : unsigned(15 downto 0) := (others => '0');   -- lock-step: retired_cnt at the start
   signal dataIn    : std_logic := '0';    -- HPS transfer finished
   signal initBusy  : std_logic := '0';    -- START_READ from a snapshot: busy time from init
   signal initCnt   : unsigned(15 downto 0) := (others => '0');
   signal reset_1   : std_logic := '0';

   -- geometry: cyls = min(16383, total / 1008), computed after a mount
   signal geoN      : integer range 0 to 33 := 0;
   signal geoQ, geoR: unsigned(31 downto 0) := (others => '0');

   function present(hd : std_logic; dh : std_logic_vector(7 downto 0)) return boolean is
   begin
      return hd = '1' and dh(4) = '0';
   end function;

   -- register index of an IDE address: 0..7 cs0, 8 alt status / devctl, 9 drive address, 15 other
   function regIndex(a : unsigned(23 downto 0)) return integer is
   begin
      if (a(23 downto 22) = "10") then
         if (a(21 downto 0) = 16#18#) then return 8; end if;
         if (a(21 downto 0) = 16#1C#) then return 9; end if;
         return 15;
      elsif (a(23 downto 22) = "01" and a(21 downto 5) = 0) then
         return to_integer(a(4 downto 2));
      end if;
      return 15;
   end function;

   -- IDENTIFY data (JS identify())
   function ident(i : integer; cy : unsigned(15 downto 0); tot : unsigned(31 downto 0);
                  mult : unsigned(4 downto 0)) return std_logic_vector is
      constant SERIAL : string(1 to 20) := "WTVEMU0001          ";
      constant FW     : string(1 to 8)  := "1.0     ";
      constant MODEL  : string(1 to 40) := "WebTV Emulated Disk                     ";
      variable t   : unsigned(31 downto 0);
      variable chs : unsigned(31 downto 0);
      function sw(s : string; k : integer) return std_logic_vector is
      begin
         return std_logic_vector(to_unsigned(character'pos(s(s'low + 2 * k)), 8)) &
                std_logic_vector(to_unsigned(character'pos(s(s'low + 2 * k + 1)), 8));
      end function;
   begin
      t := tot;
      if t > x"0FFFFFFF" then t := x"0FFFFFFF"; end if;
      chs := resize(cy * to_unsigned(16 * 63, 16), 32);
      case i is
         when 0  => return x"0040";
         when 1 | 54 => return std_logic_vector(cy);
         when 3 | 55 => return x"0010";
         when 6 | 56 => return x"003F";
         when 10 to 19 => return sw(SERIAL, i - 10);
         when 23 to 26 => return sw(FW, i - 23);
         when 27 to 46 => return sw(MODEL, i - 27);
         when 47 => return x"8010";
         when 49 => return x"0200";
         when 51 => return x"0200";
         when 53 => return x"0001";
         when 57 => return std_logic_vector(chs(15 downto 0));
         when 58 => return std_logic_vector(chs(31 downto 16));
         when 59 => return x"01" & "000" & std_logic_vector(mult);
         when 60 => return std_logic_vector(t(15 downto 0));
         when 61 => return std_logic_vector(t(31 downto 16));
         when 80 => return x"001E";
         when 82 => return x"0002";
         when 128 => return x"0001";
         when others => return x"0000";
      end case;
   end function;

begin

   handles   <= '1' when bus_addr >= x"1E400000" and bus_addr <= x"1E80001F" else '0';
   irq_level <= irq and not rDevCtl(1);

   ---------------------------------------------------------------- sector buffer
   ibuf : entity work.webtv_sdpram
   generic map (WIDTH => 16, AW => 12)
   port map (clk => clk1x, we => bufWe, waddr => bufWA, wdata => bufWD, raddr => bufRA, q => bufQ);

   bufWe <= sd_buff_wr when sdWriting = '0' and sd_ack = '1' else cpuWe;
   bufWA <= sd_buff_addr(11 downto 0) when sd_ack = '1' else cpuWA;
   bufWD <= sd_buff_dout when sd_ack = '1' else cpuWD;
   bufRA <= sd_buff_addr(11 downto 0) when sd_ack = '1' else bufPos(12 downto 1);
   sd_buff_din <= bufQ;

   ---------------------------------------------------------------- main
   process (clk1x)
      variable v      : std_logic_vector(31 downto 0);
      variable lba    : unsigned(31 downto 0);
      variable n      : unsigned(8 downto 0);
      variable bs     : unsigned(4 downto 0);
      variable c      : unsigned(7 downto 0);
      variable w      : std_logic_vector(15 downto 0);
      variable reg    : integer range 0 to 15;

      impure function getLba return unsigned is
         variable cyl : unsigned(31 downto 0);
         variable t   : unsigned(31 downto 0);
      begin
         if (rDrvHead(6) = '1') then
            return unsigned("0000" & rDrvHead(3 downto 0) & std_logic_vector(rCylHi) & std_logic_vector(rCylLo) & std_logic_vector(rSector));
         end if;
         cyl := resize(rCylHi & rCylLo, 32);
         t   := shift_left(cyl, 4) + resize(unsigned(rDrvHead(3 downto 0)), 32);   -- cyl * 16 + head
         return shift_left(t, 6) - t + resize(rSector, 32) - 1;                     -- * 63 + sector - 1
      end function;

      -- JS blockSize(): READ/WRITE MULTIPLE move min(multiple, remaining) sectors per DRQ block
      impure function blockSize(cmd : std_logic_vector(7 downto 0); rem_n : unsigned(8 downto 0)) return unsigned is
      begin
         if (cmd = x"C4" or cmd = x"C5") then
            if (rem_n < resize(rMultiple, 9)) then return rem_n(4 downto 0); end if;
            return rMultiple;
         end if;
         return to_unsigned(1, 5);
      end function;

      -- JS setIrq(s): the RIO line follows s && !nIEN
      procedure setIrq(s : std_logic) is
      begin
         irq <= s;
         if (s = '1' and rDevCtl(1) = '0') then irq_set <= '1'; else irq_clr <= '1'; end if;
      end procedure;

      procedure doneCmd is
      begin
         rError  <= x"00";
         rStatus <= S_IDLE;
         setIrq('1');
      end procedure;

      procedure abortCmd is
      begin
         rError  <= x"04";
         rStatus <= S_ERR;
         setIrq('1');
      end procedure;

      procedure resetRegs is
      begin
         rError <= x"01"; rFeature <= x"00"; rCount <= x"01"; rSector <= x"01";
         rCylLo <= x"00"; rCylHi <= x"00"; rDrvHead <= x"00";
         if (haveDisk = '1') then rStatus <= S_IDLE; else rStatus <= x"00"; end if;
         rDevCtl <= x"00"; bufValid <= '0'; wbufValid <= '0'; bufPos <= (others => '0');
         xferRemain <= (others => '0'); rCmd <= x"00"; rMultiple <= to_unsigned(1, 5);
         irq <= '0'; identMode <= '0'; secCmd <= '0';
      end procedure;

   begin
      if rising_edge(clk1x) then
         bus_done <= '0';
         irq_set  <= '0';
         irq_clr  <= '0';
         cpuWe    <= '0';

         -- requests are pulses: keep them until served
         if (bus_read = '1' or bus_write = '1') then
            reqRd   <= bus_read;
            reqWr   <= bus_write;
            reqAddr <= bus_addr(23 downto 0);
            reqData <= bus_dataWrite;
         end if;

         -- mounted image
         if (img_mounted = '1') then
            total <= img_size(40 downto 9);
            if (img_size = 0) then haveDisk <= '0'; else haveDisk <= '1'; end if;
            geoQ  <= (others => '0');
            geoR  <= (others => '0');
            geoN  <= 33;
         elsif (geoN = 1) then
            if (geoQ > 16383) then cyls <= to_unsigned(16383, 16); else cyls <= geoQ(15 downto 0); end if;
            geoN <= 0;
         elsif (geoN > 1) then
            lba := geoR(30 downto 0) & total(geoN - 2);
            if (lba >= 16 * 63) then
               geoR <= lba - 16 * 63;
               geoQ <= geoQ(30 downto 0) & '1';
            else
               geoR <= lba;
               geoQ <= geoQ(30 downto 0) & '0';
            end if;
            geoN <= geoN - 1;
         end if;

         -- HPS transfer
         sdAck1 <= sd_ack;
         if (sd_ack = '1') then sd_rd <= '0'; sd_wr <= '0'; end if;
         if (sdAck1 = '1' and sd_ack = '0') then
            sdWriting <= '0';
            dataIn    <= '1';
         end if;

         -- busy time: clk1x cycles, or (lock-step, JS: 2000 instructions) retired instructions
         if (LOCKSTEP = '1') then
            if (busyCnt /= 0 and retired_cnt - busyStart >= busyCnt) then busyCnt <= (others => '0'); end if;
         elsif (busyCnt /= 0) then
            busyCnt <= busyCnt - 1;
         end if;

         case state is

            when IDLE =>
               if (xferPending = '1' and dataIn = '1' and busyCnt = 0) then
                  -- the JS event: finish() of a read, or the end of a write
                  xferPending <= '0';
                  if (afterRead = '1') then
                     bufValid   <= '1';
                     bufPos     <= (others => '0');
                     bufLen     <= resize(xferN & "000000000", 14);
                     xferRemain <= xferRemain - xferN;
                     lbaArg     <= xferLba + resize(xferN, 32) - 1;
                  elsif (xferRemain > 0) then
                     lbaArg     <= xferLba + resize(xferN, 32);
                  else
                     lbaArg     <= xferLba + resize(xferN, 32) - 1;
                  end if;
                  ret   <= FINISH;
                  state <= SETLBA;
               elsif (reqRd = '1') then
                  reqRd <= '0';
                  state <= RD1;
               elsif (reqWr = '1') then
                  reqWr <= '0';
                  state <= WR;
               end if;

            ------------------------------------------------ register reads
            when RD1 =>
               state <= RD2;                -- data register: bufQ (bufRA = bufPos) valid next cycle

            when RD2 =>
               v := (others => '0');
               state    <= IDLE;
               bus_done <= '1';
               reg := regIndex(reqAddr);
               case reg is
                  when 0 =>
                     -- readData()
                     if (bufValid = '0' or rStatus(ST_DRQ) = '0') then
                        v := x"0000FFFF";
                     else
                        if (identMode = '1') then
                           w := ident(to_integer(bufPos(8 downto 1)), cyls, total, rMultiple);
                        else
                           w := bufQ;
                        end if;
                        v := x"0000" & w;
                        bufPos <= bufPos + 2;
                        if (resize(bufPos, 14) + 2 >= bufLen) then
                           bufValid <= '0';
                           if (identMode = '1') then
                              rStatus <= S_IDLE;
                           elsif (xferRemain > 0) then
                              lbaArg <= getLba + 1;          -- setLba(getLba() + 1); startRead()
                              ret    <= START_READ;
                              state  <= SETLBA;
                           else
                              rStatus <= S_IDLE;
                           end if;
                        end if;
                     end if;
                  when 1 => if present(haveDisk, rDrvHead) then v(7 downto 0) := rError; end if;
                  when 2 => if present(haveDisk, rDrvHead) then v(7 downto 0) := std_logic_vector(rCount); end if;
                  when 3 => if present(haveDisk, rDrvHead) then v(7 downto 0) := std_logic_vector(rSector); end if;
                  when 4 => if present(haveDisk, rDrvHead) then v(7 downto 0) := std_logic_vector(rCylLo); end if;
                  when 5 => if present(haveDisk, rDrvHead) then v(7 downto 0) := std_logic_vector(rCylHi); end if;
                  when 6 => v(7 downto 0) := rDrvHead or x"A0";
                  when 7 =>
                     if present(haveDisk, rDrvHead) then
                        v(7 downto 0) := rStatus;
                        setIrq('0');
                     end if;
                  when 8 => if present(haveDisk, rDrvHead) then v(7 downto 0) := rStatus; end if;
                  when 9 => v(7 downto 0) := x"FF";
                  when others => null;
               end case;
               bus_dataRead <= v;

            ------------------------------------------------ register writes
            when WR =>
               state    <= IDLE;
               bus_done <= '1';
               c := unsigned(reqData(7 downto 0));
               reg := regIndex(reqAddr);
               case reg is
                  when 0 =>
                     -- writeData()
                     if (wbufValid = '1' and rStatus(ST_DRQ) = '1') then
                        cpuWe  <= '1';
                        cpuWA  <= bufPos(12 downto 1);
                        cpuWD  <= reqData(15 downto 0);
                        bufPos <= bufPos + 2;
                        if (resize(bufPos, 14) + 2 >= bufLen) then
                           wbufValid <= '0';
                           if (secCmd = '1') then
                              secCmd <= '0';
                              doneCmd;
                           else
                              state <= WRITE_START;
                           end if;
                        end if;
                     end if;
                  when 1 => rFeature <= reqData(7 downto 0);
                  when 2 => rCount   <= c;
                  when 3 => rSector  <= c;
                  when 4 => rCylLo   <= c;
                  when 5 => rCylHi   <= c;
                  when 6 => rDrvHead <= reqData(7 downto 0);
                  when 7 =>
                     if present(haveDisk, rDrvHead) then
                        -- command(c): setIrq(false) first
                        rCmd      <= reqData(7 downto 0);
                        identMode <= '0';
                        setIrq('0');
                        if (rCount = 0) then n := to_unsigned(256, 9); else n := resize(rCount, 9); end if;
                        case reqData(7 downto 0) is
                           when x"20" | x"21" | x"C4" =>
                              xferRemain <= n;
                              state      <= START_READ;
                           when x"30" | x"31" | x"C5" =>
                              xferRemain <= n;
                              bs := blockSize(reqData(7 downto 0), n);
                              bufLen    <= resize(bs & "000000000", 14);
                              bufPos    <= (others => '0');
                              wbufValid <= '1';
                              rError    <= x"00";
                              rStatus   <= S_DRQ;
                           when x"40" | x"41" =>
                              lba := getLba + resize(n, 32) - 1;
                              if (lba >= total) then
                                 rError <= x"10"; rStatus <= S_IDNF; setIrq('1');
                              else
                                 lbaArg <= lba;
                                 ret    <= VERIFY_DONE;
                                 state  <= SETLBA;
                              end if;
                           when x"EC" =>
                              identMode <= '1';
                              bufValid  <= '1';
                              bufPos    <= (others => '0');
                              bufLen    <= to_unsigned(512, 14);
                              rError    <= x"00";
                              rStatus   <= S_DRQ;
                              setIrq('1');
                           when x"C6" =>
                              if (rCount = 0 or rCount > 16 or (rCount and (rCount - 1)) /= 0) then
                                 abortCmd;
                              else
                                 rMultiple <= rCount(4 downto 0);
                                 doneCmd;
                              end if;
                           when x"90" =>
                              rError <= x"01"; rStatus <= S_IDLE; rCount <= x"01"; rSector <= x"01";
                              rCylLo <= x"00"; rCylHi <= x"00";
                              setIrq('1');
                           when x"F8" =>
                              lbaArg <= total - 1;
                              ret    <= VERIFY_DONE;
                              state  <= SETLBA;
                           when x"E5" | x"98" =>
                              rCount <= x"FF";
                              doneCmd;
                           when x"F1" | x"F2" | x"F4" =>
                              secCmd     <= '1';
                              wbufValid  <= '1';
                              bufPos     <= (others => '0');
                              bufLen     <= to_unsigned(512, 14);
                              xferRemain <= to_unsigned(1, 9);
                              rStatus    <= S_DRQ;
                           when x"91" | x"E0" | x"E1" | x"E2" | x"E3" | x"E6" | x"94" | x"95" | x"96" | x"97" | x"99" |
                                x"E7" | x"EA" | x"EF" | x"DE" | x"DF" | x"F3" | x"F5" | x"F6" =>
                              doneCmd;
                           when others =>
                              if (reqData(7 downto 4) = x"1" or reqData(7 downto 4) = x"7") then
                                 doneCmd;                    -- RECALIBRATE / SEEK
                              else
                                 abortCmd;
                              end if;
                        end case;
                     end if;
                  when 8 =>
                     if (reqData(2) = '1' and rDevCtl(2) = '0') then
                        resetRegs;                           -- SRST
                        xferPending <= '0';
                     end if;
                     rDevCtl <= reqData(7 downto 0);
                  when others => null;
               end case;

            ------------------------------------------------ setLba(lbaArg): CHS needs lba / 63
            when SETLBA =>
               if (rDrvHead(6) = '1') then
                  rSector  <= lbaArg(7 downto 0);
                  rCylLo   <= lbaArg(15 downto 8);
                  rCylHi   <= lbaArg(23 downto 16);
                  rDrvHead(3 downto 0) <= std_logic_vector(lbaArg(27 downto 24));
                  state    <= ret;
               else
                  divQ  <= (others => '0');
                  divR  <= (others => '0');
                  divN  <= 32;
                  state <= SETLBA_DIV;
               end if;

            when SETLBA_DIV =>
               if (divN = 0) then
                  -- s = lba % 63 + 1, t = lba / 63, h = t % 16, c = t / 16
                  rSector <= divR(7 downto 0) + 1;
                  rDrvHead(3 downto 0) <= std_logic_vector(divQ(3 downto 0));
                  rCylLo  <= divQ(11 downto 4);
                  rCylHi  <= divQ(19 downto 12);
                  state   <= ret;
               else
                  lba := divR(30 downto 0) & lbaArg(divN - 1);
                  if (lba >= 63) then
                     divR <= lba - 63;
                     divQ <= divQ(30 downto 0) & '1';
                  else
                     divR <= lba;
                     divQ <= divQ(30 downto 0) & '0';
                  end if;
                  divN <= divN - 1;
               end if;

            when VERIFY_DONE =>
               doneCmd;
               state <= IDLE;

            ------------------------------------------------ startRead()
            when START_READ =>
               lba := getLba;
               bs  := blockSize(rCmd, xferRemain);
               state <= IDLE;
               if (lba + resize(bs, 32) > total) then
                  rError  <= x"10";
                  rStatus <= S_IDNF;
                  setIrq('1');
               else
                  rStatus     <= S_BSY;
                  xferLba     <= lba;
                  xferN       <= bs;
                  sd_lba      <= lba;
                  sd_blk_cnt  <= resize(bs - 1, 6);
                  sd_rd       <= '1';
                  dataIn      <= '0';
                  afterRead   <= '1';
                  xferPending <= '1';
                  busyStart <= retired_cnt;
                  if (initBusy = '1') then
                     busyCnt <= initCnt;
                  elsif (LOCKSTEP = '1') then
                     busyCnt <= to_unsigned(BUSY_INSTR, 16);
                  else
                     busyCnt <= to_unsigned(BUSY_MIN, 16);
                  end if;
               end if;
               initBusy <= '0';

            ------------------------------------------------ the end of a busy period (after its setLba)
            when FINISH =>
               rError <= x"00";
               if (afterRead = '1') then
                  rStatus <= S_DRQ;
               elsif (xferRemain > 0) then
                  bs := blockSize(rCmd, xferRemain);
                  bufLen    <= resize(bs & "000000000", 14);
                  bufPos    <= (others => '0');
                  wbufValid <= '1';
                  rStatus   <= S_DRQ;
               else
                  rStatus <= S_IDLE;
               end if;
               setIrq('1');
               state <= IDLE;

            ------------------------------------------------ write the buffer to the disk (putSectors)
            when WRITE_START =>
               lba := getLba;
               bs  := resize(bufLen(13 downto 9), 5);
               xferLba     <= lba;
               xferN       <= bs;
               xferRemain  <= xferRemain - bs;
               sd_lba      <= lba;
               sd_blk_cnt  <= resize(bs - 1, 6);
               sd_wr       <= '1';
               sdWriting   <= '1';
               dataIn      <= '0';
               rStatus     <= S_BSY;
               afterRead   <= '0';
               xferPending <= '1';
               busyStart   <= retired_cnt;
               if (LOCKSTEP = '1') then busyCnt <= to_unsigned(BUSY_INSTR, 16); else busyCnt <= to_unsigned(BUSY_MIN, 16); end if;
               state       <= IDLE;

         end case;

         if (init_we = '1') then
            case to_integer(init_addr) is
               when 16#0000# => rError <= init_data(7 downto 0);
               when 16#0001# => rFeature <= init_data(7 downto 0);
               when 16#0002# => rCount <= unsigned(init_data(7 downto 0));
               when 16#0003# => rSector <= unsigned(init_data(7 downto 0));
               when 16#0004# => rCylLo <= unsigned(init_data(7 downto 0));
               when 16#0005# => rCylHi <= unsigned(init_data(7 downto 0));
               when 16#0006# => rDrvHead <= init_data(7 downto 0);
               when 16#0007# => rStatus <= init_data(7 downto 0);
               when 16#0008# => rDevCtl <= init_data(7 downto 0);
               when 16#0009# => rCmd <= init_data(7 downto 0);
               when 16#000A# => rMultiple <= unsigned(init_data(4 downto 0));
               when 16#000B# => irq <= init_data(0);
               when 16#000C# => bufValid <= init_data(0); identMode <= init_data(1); wbufValid <= init_data(2); secCmd <= init_data(3);
               when 16#000D# => bufPos <= unsigned(init_data(12 downto 0));
               when 16#000E# => bufLen <= unsigned(init_data(13 downto 0));
               when 16#000F# => xferRemain <= unsigned(init_data(8 downto 0));
               when 16#0010# => initBusy <= '1'; initCnt <= unsigned(init_data(15 downto 0)) + 1; state <= START_READ;
               when others =>
                  if (init_addr >= 16#1000#) then       -- buffer words
                     cpuWe <= '1';
                     cpuWA <= init_addr(11 downto 0);
                     cpuWD <= init_data(15 downto 0);
                  end if;
            end case;
         end if;

         -- reset on the rising edge only: a snapshot load (init_*) happens while the CPU is held
         reset_1 <= reset;
         if (reset = '1' and reset_1 = '0') then
            resetRegs;
            state       <= IDLE;
            reqRd       <= '0';
            reqWr       <= '0';
            xferPending <= '0';
            sd_rd       <= '0';
            sd_wr       <= '0';
            sdWriting   <= '0';
         end if;
      end if;
   end process;

end architecture;
