-----------------------------------------------------------------
-- WebTV Plus (LC2) core: MiSTer glue around webtv_core
--
--  * boot ROM download (hps_io ioctl, 16 bit WIDE) into DDR3 at ROM_BASE through the core's HPS client
--  * RAM clear (8 MB of zeros) before the first start and on every OSD reset
--  * CPU start sequence (as sim/n64cpu/tb_cpu.vhd): SS_reset, then the R4640 reset values of
--    CP0 Status / Config / Compare through the savestate port, then release the CPU
--  * SOLO software reset (BUS_RESETCAUSE write) -> CPU restart, no ROM reload / RAM clear
--  * debug serial <-> UART pins (8N1) with an optional auto-answer 'y' to "Disk Boot?"
--  * IDE disk: the image mounted in the OSD (hps_io block device 0)
--  * MMIO units not in RTL yet (IR, parallel port, audio, modem): reads 0, writes ignored
--  * video: the frame renderer's double buffer is shown by the MiSTer scaler (FB_* outputs)
--
-- Everything here is clk1x unless noted; the HPS side (hps_io) also runs on clk1x.
-----------------------------------------------------------------
library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

entity webtv_mister is
   generic
   (
      CLK1X_HZ  : natural := 62500000;
      CLK93_HZ  : natural := 93750000;
      BAUD      : natural := 115200;
      CLEAR_RAM : boolean := true;
      DISK_WAIT_MS : natural := 3000;      -- how long the CPU start waits for a disk image mount
      RAM_BYTES : natural := 8 * 1024 * 1024
   );
   port
   (
      clk1x            : in  std_logic;
      clk93            : in  std_logic;
      clk2x            : in  std_logic;
      pll_locked       : in  std_logic;
      reset            : in  std_logic;          -- OSD / button reset (clk1x)

      -- options
      autoboot_y       : in  std_logic := '1';   -- answer 'y' to the boot ROM's "Disk Boot?" prompt
      serial_id        : in  std_logic_vector(63 downto 0) := x"ca0000c0ffee0101";

      -- hps_io download
      ioctl_download   : in  std_logic;
      ioctl_index      : in  std_logic_vector(7 downto 0);
      ioctl_wr         : in  std_logic;
      ioctl_addr       : in  std_logic_vector(26 downto 0);
      ioctl_dout       : in  std_logic_vector(15 downto 0);
      ioctl_wait       : out std_logic := '0';

      -- IDE disk image (hps_io block device 0, WIDE)
      img_mounted      : in  std_logic := '0';
      img_size         : in  std_logic_vector(63 downto 0) := (others => '0');
      sd_lba           : out std_logic_vector(31 downto 0);
      sd_blk_cnt       : out std_logic_vector(5 downto 0);
      sd_rd            : out std_logic;
      sd_wr            : out std_logic;
      sd_ack           : in  std_logic := '0';
      sd_buff_addr     : in  std_logic_vector(12 downto 0) := (others => '0');
      sd_buff_dout     : in  std_logic_vector(15 downto 0) := (others => '0');
      sd_buff_din      : out std_logic_vector(15 downto 0);
      sd_buff_wr       : in  std_logic := '0';

      -- input: hps_io ps2_key (toggle, pressed, extended, set-2 code), joystick buttons
      -- (0 right, 1 left, 2 down, 3 up, 4 select, 5 back, 6 home, 7 options, 8 scroll up,
      --  9 scroll down, 10 power), all sent as IR keyboard keys
      ps2_key          : in  std_logic_vector(10 downto 0) := (others => '0');
      joy              : in  std_logic_vector(15 downto 0) := (others => '0');

      -- serial port: debug console (uart_modem = '0') or the hardware modem's line (MiSTer UART -> HPS)
      uart_modem       : in  std_logic := '0';
      uart_rxd         : in  std_logic := '1';
      uart_txd         : out std_logic := '1';
      uart_dsr         : in  std_logic := '1';     -- HPS DTR (active low): carrier detect for the modem
      uart_rts         : out std_logic := '0';
      uart_dtr         : out std_logic := '0';

      -- status
      running          : out std_logic;
      rom_loaded       : out std_logic;
      led              : out std_logic_vector(31 downto 0);
      errors           : out std_logic_vector(7 downto 0);

      -- video
      fb_en            : out std_logic := '0';   -- a frame has been rendered since the start
      fb_base          : out std_logic_vector(31 downto 0);
      vid_ce           : out std_logic;
      -- bring-up overlay on the core's own video (rows of bit boxes, see the overlay process)
      debug_overlay    : in  std_logic := '0';
      vga_r, vga_g, vga_b : out std_logic_vector(7 downto 0);
      vid_hblank, vid_vblank, vid_hsync, vid_vsync : out std_logic;

      -- MiSTer DDR3
      ddr3_BUSY        : in  std_logic;
      ddr3_DOUT        : in  std_logic_vector(63 downto 0);
      ddr3_DOUT_READY  : in  std_logic;
      ddr3_BURSTCNT    : out std_logic_vector(7 downto 0);
      ddr3_ADDR        : out std_logic_vector(28 downto 0);
      ddr3_DIN         : out std_logic_vector(63 downto 0);
      ddr3_BE          : out std_logic_vector(7 downto 0);
      ddr3_WE          : out std_logic;
      ddr3_RD          : out std_logic
   );
end entity;

architecture arch of webtv_mister is

   constant DDR3_WINDOW : unsigned(31 downto 0) := x"30000000";
   constant ROM_BASE    : unsigned(27 downto 0) := x"0800000";
   constant SR_RESET    : std_logic_vector(63 downto 0) := x"0000000000400004";  -- BEV | ERL
   -- R4640 Config: 8 KB I and D caches (IC = DC = 1), 32-byte lines, K0 = 3. The caches really are
   -- 8 KB, and the boot ROM sizes its cache flushes from this register. (The JS model reports 4 KB,
   -- 0x00026033, which only the lock-step testbench uses: with it the ROM flushes half the D-cache
   -- and the OS code it copied to RAM is fetched stale.)
   -- (the CPU takes the R4640 Config from the upper half of savestate slot 16)
   constant CONFIG_RESET: std_logic_vector(63 downto 0) := x"0002627300000003";
   constant COMPARE_RESET : std_logic_vector(63 downto 0) := x"00000000FFFFFFFF";

   -- reset / boot sequencing (clk1x)
   type tBoot is (WAIT_ROM, LOADING, CLEAR, WAIT_DISK, HOLD, RUN);
   signal boot        : tBoot := WAIT_ROM;
   -- synthesis translate_off
   signal bootLast    : tBoot := WAIT_ROM;
   -- synthesis translate_on
   signal memReset    : std_logic := '1';
   signal holdCnt     : unsigned(4 downto 0) := (others => '0');
   signal diskWait    : integer range 0 to DISK_WAIT_MS * (CLK1X_HZ / 1000) := 0;
   signal hold1x      : std_logic := '1';
   signal reset_1x    : std_logic := '1';
   signal coldReset   : std_logic := '0';   -- RAM clear = a power-on or OSD reset (not the OS's own reset)
   signal romLoaded   : std_logic := '0';
   signal dl_1        : std_logic := '0';

   -- HPS client
   signal hpsReq      : std_logic := '0';
   signal hpsAddr     : unsigned(27 downto 0) := (others => '0');
   signal hpsData     : std_logic_vector(63 downto 0) := (others => '0');
   signal hpsDone     : std_logic;
   signal hpsBusy     : std_logic := '0';
   signal wordBuf     : std_logic_vector(63 downto 0) := (others => '0');
   signal wordValid   : std_logic := '0';
   signal wordAddr    : unsigned(27 downto 0) := (others => '0');
   signal clearAddr   : unsigned(23 downto 0) := (others => '0');

   -- clk93 side of the CPU start
   signal hold93_s    : std_logic_vector(1 downto 0) := "11";
   signal reset_93    : std_logic := '1';
   signal SS_reset    : std_logic := '1';
   signal SS_wren     : std_logic := '0';
   signal SS_Adr      : unsigned(11 downto 0) := (others => '0');
   signal SS_Data     : std_logic_vector(63 downto 0) := (others => '0');
   signal seq93       : unsigned(6 downto 0) := (others => '0');

   -- core
   signal soft_reset  : std_logic;
   signal dbg_tx, dbg_rx : std_logic;
   signal dbg_tx_data, dbg_rx_data : std_logic_vector(7 downto 0);
   signal bus_read, bus_write, bus_done : std_logic;
   signal fb_display  : unsigned(27 downto 0);
   signal fb_frame    : std_logic;
   signal retiredCnt  : unsigned(31 downto 0);
   signal pcI         : unsigned(31 downto 0);
   signal scrI        : std_logic_vector(159 downto 0);
   signal ideI        : std_logic_vector(95 downto 0);
   -- branch-trace dump to DDR3 window offset 0xFA0000 (past framebuffer 1) (1024 x 64 bit: count & pc, oldest first),
   -- then a marker word C0DEDEAD_<wi> at 0xFA2000; read from Linux via /dev/mem 0x30FA0000
   signal trFrozen    : std_logic;
   signal trWi        : unsigned(9 downto 0);
   signal trRA        : unsigned(9 downto 0) := (others => '0');
   signal trWi1x      : unsigned(9 downto 0) := (others => '0');  -- trWi (CPU clock) registered in clk1x
   signal trFr1, trFr2 : std_logic := '0';                         -- trFrozen, two clk1x later
   signal trQ         : std_logic_vector(63 downto 0);
   signal dumpIdx     : integer range 0 to 1025 := 0;
   signal dumpPh      : integer range 0 to 3 := 0;
   signal dumped      : std_logic := '0';
   -- debug console log in DDR3 (window offset 0xFB0000, 64 KB ring of bytes; the running byte count
   -- is written to 0xFC0000 after each byte): read from Linux via /dev/mem 0x30FB0000 / 0x30FC0000
   type tLogQ is array(0 to 255) of std_logic_vector(7 downto 0);
   signal logQ        : tLogQ;
   signal logWr, logRd : unsigned(7 downto 0) := (others => '0');
   signal logCount    : unsigned(31 downto 0) := (others => '0');
   signal logPh       : std_logic := '0';
   signal logByte     : std_logic_vector(7 downto 0) := (others => '0');
   signal hpsMask     : std_logic_vector(7 downto 0) := x"FF";
   signal ledI        : std_logic_vector(31 downto 0);
   signal errI        : std_logic_vector(7 downto 0);
   signal vceI, hbI, vbI : std_logic;
   signal ovX, ovY    : integer range 0 to 1023 := 0;
   signal ovCY        : integer range 0 to 19 := 0;     -- line within the overlay row (no divider)
   signal ovR         : integer range 0 to 31 := 0;     -- overlay row
   signal hb1         : std_logic := '0';
   signal txCount, frCount, sdCount : unsigned(15 downto 0) := (others => '0');
   signal sdRdSeen, sdAckSeen, imgSeen, srstSeen : std_logic := '0';
   signal errSticky   : std_logic_vector(7 downto 0) := (others => '0');
   signal sdRdI, sdAck1 : std_logic := '0';
   type tOvRows is array(0 to 19) of std_logic_vector(15 downto 0);
   signal ovRows      : tOvRows;
   signal sdLba       : unsigned(31 downto 0);
   signal sdBlkCnt    : unsigned(5 downto 0);
   signal mTxd, mRtsN : std_logic;
   signal mMcr        : std_logic_vector(7 downto 0);
   signal dbgTxd, dbgRxd, mRxd : std_logic;

   -- IR keyboard events
   signal keyStrobe   : std_logic := '0';
   signal keyCode     : std_logic_vector(6 downto 0) := (others => '0');
   signal keyRelease  : std_logic := '0';
   signal ps2Tgl      : std_logic := '0';
   signal joySent     : std_logic_vector(10 downto 0) := (others => '0');
   type tJoyKeys is array(0 to 10) of std_logic_vector(6 downto 0);
   constant JOY_KEYS  : tJoyKeys := ("1011000", "1001000", "1010000", "1001011", "0111010", "1001110",
                                     "0111100", "1010100", "1010110", "1011011", "0011011");

   -- serial
   constant BAUD_DIV  : natural := (CLK1X_HZ + BAUD / 2) / BAUD;
   type tFifo is array(0 to 63) of std_logic_vector(7 downto 0);
   type tTxFifo is array(0 to 1023) of std_logic_vector(7 downto 0);
   signal txFifo      : tTxFifo;
   signal txWr, txRd  : unsigned(9 downto 0) := (others => '0');
   signal txQ         : std_logic_vector(7 downto 0) := (others => '0');
   signal txWait      : integer range 0 to 2 := 0;
   signal txShift     : std_logic_vector(9 downto 0) := (others => '1');
   signal txBits      : integer range 0 to 10 := 0;
   signal txCnt       : integer range 0 to BAUD_DIV := 0;
   signal rxSync      : std_logic_vector(2 downto 0) := "111";
   signal rxActive    : std_logic := '0';
   signal rxCnt       : integer range 0 to BAUD_DIV * 2 := 0;
   signal rxBits      : integer range 0 to 9 := 0;
   signal rxShift     : std_logic_vector(7 downto 0) := (others => '0');
   signal rxStrobe    : std_logic := '0';
   signal rxByte      : std_logic_vector(7 downto 0) := (others => '0');
   type tLast is array(0 to 9) of std_logic_vector(7 downto 0);
   signal lastTx      : tLast := (others => (others => '0'));
   signal autoY       : std_logic := '0';

   -- PS/2 set-2 scancode (extended, code) -> valid & Sejin scancode (irkeys.js KEY_MAP)
   function ps2Sejin(e : std_logic; c : std_logic_vector(7 downto 0)) return std_logic_vector is
   begin
      case std_logic_vector'(e & c) is
         when "0" & x"0E" => return '1' & "0000100";   -- Backquote
         when "0" & x"07" => return '1' & "0000101";   -- F12
         when "0" & x"58" => return '1' & "0001001";   -- CapsLock
         when "0" & x"22" => return '1' & "0001010";   -- KeyX
         when "0" & x"1E" => return '1' & "0001101";   -- Digit2
         when "0" & x"1B" => return '1' & "0001110";   -- KeyS
         when "0" & x"1D" => return '1' & "0001111";   -- KeyW
         when "0" & x"21" => return '1' & "0010010";   -- KeyC
         when "0" & x"26" => return '1' & "0010101";   -- Digit3
         when "0" & x"23" => return '1' & "0010110";   -- KeyD
         when "0" & x"24" => return '1' & "0010111";   -- KeyE
         when "1" & x"11" => return '1' & "0011000";   -- AltRight
         when "0" & x"0D" => return '1' & "0011001";   -- Tab
         when "0" & x"1A" => return '1' & "0011010";   -- KeyZ
         when "0" & x"05" => return '1' & "0011011";   -- F1
         when "0" & x"14" => return '1' & "0011100";   -- ControlLeft
         when "0" & x"16" => return '1' & "0011101";   -- Digit1
         when "0" & x"1C" => return '1' & "0011110";   -- KeyA
         when "0" & x"15" => return '1' & "0011111";   -- KeyQ
         when "0" & x"32" => return '1' & "0100000";   -- KeyB
         when "0" & x"2C" => return '1' & "0100001";   -- KeyT
         when "0" & x"2A" => return '1' & "0100010";   -- KeyV
         when "0" & x"34" => return '1' & "0100011";   -- KeyG
         when "0" & x"2E" => return '1' & "0100100";   -- Digit5
         when "0" & x"25" => return '1' & "0100101";   -- Digit4
         when "0" & x"2B" => return '1' & "0100110";   -- KeyF
         when "0" & x"2D" => return '1' & "0100111";   -- KeyR
         when "0" & x"11" => return '1' & "0101000";   -- AltLeft
         when "0" & x"76" => return '1' & "0101001";   -- Escape
         when "1" & x"14" => return '1' & "0101011";   -- ControlRight
         when "0" & x"83" => return '1' & "0101101";   -- F7
         when "0" & x"0A" => return '1' & "0101111";   -- F8
         when "0" & x"12" => return '1' & "0110001";   -- ShiftLeft
         when "0" & x"59" => return '1' & "0110010";   -- ShiftRight
         when "1" & x"7C" => return '1' & "0110110";   -- PrintScreen
         when "0" & x"29" => return '1' & "0111000";   -- Space
         when "0" & x"66" => return '1' & "0111001";   -- Backspace
         when "0" & x"5A" => return '1' & "0111010";   -- Enter
         when "1" & x"5A" => return '1' & "0111010";   -- NumpadEnter
         when "1" & x"6C" => return '1' & "0111100";   -- Home
         when "0" & x"6C" => return '1' & "0111100";   -- Numpad7
         when "0" & x"04" => return '1' & "0111101";   -- F3
         when "0" & x"5D" => return '1' & "0111110";   -- Backslash
         when "1" & x"6B" => return '1' & "1001000";   -- ArrowLeft
         when "0" & x"6B" => return '1' & "1001000";   -- Numpad4
         when "0" & x"01" => return '1' & "1001010";   -- F9
         when "1" & x"75" => return '1' & "1001011";   -- ArrowUp
         when "0" & x"75" => return '1' & "1001011";   -- Numpad8
         when "1" & x"70" => return '1' & "1001100";   -- Insert
         when "0" & x"70" => return '1' & "1001100";   -- Numpad0
         when "1" & x"69" => return '1' & "1001110";   -- End
         when "0" & x"69" => return '1' & "1001110";   -- Numpad1
         when "1" & x"72" => return '1' & "1010000";   -- ArrowDown
         when "0" & x"72" => return '1' & "1010000";   -- Numpad2
         when "0" & x"0B" => return '1' & "1010010";   -- F6
         when "0" & x"78" => return '1' & "1010100";   -- F11
         when "0" & x"0C" => return '1' & "1010101";   -- F4
         when "1" & x"7D" => return '1' & "1010110";   -- PageUp
         when "0" & x"7D" => return '1' & "1010110";   -- Numpad9
         when "1" & x"74" => return '1' & "1011000";   -- ArrowRight
         when "0" & x"74" => return '1' & "1011000";   -- Numpad6
         when "1" & x"7A" => return '1' & "1011011";   -- PageDown
         when "0" & x"7A" => return '1' & "1011011";   -- Numpad3
         when "0" & x"09" => return '1' & "1011100";   -- F10
         when "0" & x"03" => return '1' & "1011101";   -- F5
         when "0" & x"49" => return '1' & "1100010";   -- Period
         when "0" & x"06" => return '1' & "1100100";   -- F2
         when "0" & x"46" => return '1' & "1100101";   -- Digit9
         when "0" & x"4B" => return '1' & "1100110";   -- KeyL
         when "0" & x"44" => return '1' & "1100111";   -- KeyO
         when "0" & x"4A" => return '1' & "1101000";   -- Slash
         when "0" & x"54" => return '1' & "1101001";   -- BracketLeft
         when "0" & x"52" => return '1' & "1101011";   -- Quote
         when "0" & x"4E" => return '1' & "1101100";   -- Minus
         when "0" & x"45" => return '1' & "1101101";   -- Digit0
         when "0" & x"4C" => return '1' & "1101110";   -- Semicolon
         when "0" & x"4D" => return '1' & "1101111";   -- KeyP
         when "0" & x"5B" => return '1' & "1110001";   -- BracketRight
         when "0" & x"41" => return '1' & "1110010";   -- Comma
         when "0" & x"55" => return '1' & "1110100";   -- Equal
         when "0" & x"3E" => return '1' & "1110101";   -- Digit8
         when "0" & x"42" => return '1' & "1110110";   -- KeyK
         when "0" & x"43" => return '1' & "1110111";   -- KeyI
         when "0" & x"31" => return '1' & "1111000";   -- KeyN
         when "0" & x"35" => return '1' & "1111001";   -- KeyY
         when "0" & x"3A" => return '1' & "1111010";   -- KeyM
         when "0" & x"33" => return '1' & "1111011";   -- KeyH
         when "0" & x"36" => return '1' & "1111100";   -- Digit6
         when "0" & x"3D" => return '1' & "1111101";   -- Digit7
         when "0" & x"3B" => return '1' & "1111110";   -- KeyJ
         when "0" & x"3C" => return '1' & "1111111";   -- KeyU
         when others => return x"00";
      end case;
   end function;

   function str_match(l : tLast; s : string) return boolean is
   begin
      for i in 0 to 9 loop
         if (unsigned(l(i)) /= to_unsigned(character'pos(s(s'low + i)), 8)) then return false; end if;
      end loop;
      return true;
   end function;

begin

   rom_loaded <= romLoaded;
   led        <= ledI;
   errors     <= errI;
   sd_rd      <= sdRdI;
   vid_ce     <= vceI;
   vid_hblank <= hbI;
   vid_vblank <= vbI;

   ---------------------------------------------------------------- bring-up overlay
   -- 8 rows of 16 bit boxes (MSB left), white = 1:
   --  0: rom_loaded running fb_en ioctl_download sd_rd-seen sd_ack-seen img-mounted soft-reset | errors(7:0)
   --  1: instructions(31:16)   2: instructions(15:0)   3: debug serial bytes   4: frames rendered
   --  5: SOLO LED(15:0)        6: last two debug serial chars   7: disk transfers
   --  8, 9: PC of an instruction entering execute (31:16, 15:0)
   --  10..19: the last 5 words written to 0x1E00001C (hi, lo; oldest first): the boot ROM's exception
   --          handler stores Status, Cause, EPC, BadVAddr, Config there before it hangs
   process (clk1x)
      variable r, b, bit : integer;
   begin
      if rising_edge(clk1x) then
         if (dbg_tx = '1') then txCount <= txCount + 1; end if;
         if (fb_frame = '1') then frCount <= frCount + 1; end if;
         sdAck1 <= sd_ack;
         if (sd_ack = '1' and sdAck1 = '0') then sdCount <= sdCount + 1; end if;
         if (sdRdI = '1') then sdRdSeen <= '1'; end if;
         if (sd_ack = '1') then sdAckSeen <= '1'; end if;
         if (img_mounted = '1') then imgSeen <= '1'; end if;
         if (soft_reset = '1') then srstSeen <= '1'; end if;
         errSticky <= errSticky or errI;
         ovRows(0) <= romLoaded & (not hold1x) & fb_en & ioctl_download & sdRdSeen & sdAckSeen & imgSeen & srstSeen & errSticky;
         ovRows(1) <= std_logic_vector(retiredCnt(31 downto 16));
         ovRows(2) <= std_logic_vector(retiredCnt(15 downto 0));
         ovRows(3) <= std_logic_vector(txCount);
         ovRows(4) <= std_logic_vector(frCount);
         ovRows(5) <= ledI(15 downto 0);
         ovRows(6) <= lastTx(8) & lastTx(9);
         ovRows(7) <= std_logic_vector(sdCount);
         ovRows(8) <= std_logic_vector(pcI(31 downto 16));
         ovRows(9) <= std_logic_vector(pcI(15 downto 0));
         -- 10: IDE haveDisk, DRV, xferPending, status   11/12: sectors   13: last address bits 23:8
         -- 14: last address 7:0 & last read data 7:0   15: IDE accesses   16..19: exception dump Cause, EPC
         for i in 0 to 5 loop
            ovRows(10 + i) <= ideI(95 - 16 * i downto 80 - 16 * i);
         end loop;
         ovRows(16) <= scrI(127 downto 112); ovRows(17) <= scrI(111 downto 96);
         ovRows(18) <= scrI(95 downto 80);   ovRows(19) <= scrI(79 downto 64);
         if (vceI = '1') then
            hb1 <= hbI;
            if (hbI = '1') then ovX <= 0; elsif (ovX < 1023) then ovX <= ovX + 1; end if;
            if (hbI = '1' and hb1 = '0') then
               if (vbI = '1') then ovY <= 0; elsif (ovY < 1023) then ovY <= ovY + 1; end if;
               if (vbI = '1' or ovY < 39) then
                  ovCY <= 0; ovR <= 0;
               elsif (ovY >= 40) then
                  if (ovCY = 19) then
                     ovCY <= 0;
                     if (ovR < 31) then ovR <= ovR + 1; end if;
                  else
                     ovCY <= ovCY + 1;
                  end if;
               end if;
            end if;
            vga_r <= x"00"; vga_g <= x"00"; vga_b <= x"00";
            if (debug_overlay = '1' and ovY >= 40 and ovY < 40 + 20 * 20 and ovX >= 64 and ovX < 64 + 16 * 32) then
               r := ovR; b := to_integer(to_unsigned(ovX, 10)(9 downto 5)) - 2; bit := 15 - b;
               if (ovCY >= 3 and to_unsigned(ovX, 10)(4 downto 0) >= 3) then
                  if (ovRows(r)(bit) = '1') then
                     vga_r <= x"F0"; vga_g <= x"F0"; vga_b <= x"F0";
                  elsif (r = 0) then
                     vga_r <= x"60"; vga_g <= x"10"; vga_b <= x"10";
                  else
                     vga_r <= x"30"; vga_g <= x"30"; vga_b <= x"50";
                  end if;
               end if;
            end if;
         end if;
      end if;
   end process;
   -- serial port routing
   uart_txd <= mTxd when uart_modem = '1' else dbgTxd;
   mRxd     <= uart_rxd when uart_modem = '1' else '1';
   dbgRxd   <= uart_rxd when uart_modem = '0' else '1';
   uart_rts <= mRtsN when uart_modem = '1' else '0';
   uart_dtr <= not mMcr(0) when uart_modem = '1' else '0';
   sd_lba     <= std_logic_vector(sdLba);
   sd_blk_cnt <= std_logic_vector(sdBlkCnt);
   running    <= '1' when boot = RUN else '0';

   ---------------------------------------------------------------- boot sequencer + loader (clk1x)
   process (clk1x)
      variable k : integer range 0 to 3;
   begin
      if rising_edge(clk1x) then
         memReset <= not pll_locked;
         hpsReq   <= '0';
         dl_1     <= ioctl_download;

         if (hpsDone = '1') then hpsBusy <= '0'; end if;

         -- boot ROM download (index 0 = boot.rom / any ROM file chosen in the OSD)
         if (ioctl_download = '1' and ioctl_index(5 downto 0) = "000000") then
            if (boot /= LOADING) then
               boot      <= LOADING;
               wordValid <= '0';
               romLoaded <= '0';
            end if;
            if (ioctl_wr = '1') then
               k := to_integer(unsigned(ioctl_addr(2 downto 1)));
               wordBuf(16 * k + 15 downto 16 * k) <= ioctl_dout;   -- bytes in address order: dout(7:0) first
               wordAddr  <= ROM_BASE + resize(unsigned(ioctl_addr(20 downto 3)) & "000", 28);
               wordValid <= '1';
               if (k = 3) then
                  ioctl_wait <= '1';
               end if;
            end if;
         end if;

         -- write a full (or the final partial) word
         if (wordValid = '1' and hpsBusy = '0' and hpsReq = '0' and
             (ioctl_wait = '1' or (boot = LOADING and ioctl_download = '0'))) then
            hpsAddr   <= wordAddr;
            hpsData   <= wordBuf;
            hpsMask   <= x"FF";
            hpsReq    <= '1';
            hpsBusy   <= '1';
            wordValid <= '0';
            wordBuf   <= (others => '0');
         end if;
         if (ioctl_wait = '1' and wordValid = '0' and hpsBusy = '0' and hpsReq = '0') then
            ioctl_wait <= '0';
         end if;

         if (boot = LOADING and ioctl_download = '0' and dl_1 = '0' and wordValid = '0' and hpsBusy = '0' and hpsReq = '0') then
            romLoaded <= '1';
            boot      <= CLEAR;
            clearAddr <= (others => '0');
         end if;

         -- RAM clear
         if (boot = CLEAR) then
            diskWait <= 0;
            if (not CLEAR_RAM) then
               boot <= WAIT_DISK;
            elsif (hpsBusy = '0' and hpsReq = '0') then
               if (clearAddr = to_unsigned(RAM_BYTES, 24)) then
                  boot <= WAIT_DISK;
               else
                  hpsAddr   <= resize(clearAddr, 28);
                  hpsData   <= (others => '0');
                  hpsMask   <= x"FF";
                  hpsReq    <= '1';
                  hpsBusy   <= '1';
                  clearAddr <= clearAddr + 8;
               end if;
            end if;
         end if;

         -- give the HPS up to 3 s to mount the disk image (the OS probes the IDE drive early)
         if (boot = WAIT_DISK) then
            if (imgSeen = '1' or diskWait = DISK_WAIT_MS * (CLK1X_HZ / 1000)) then
               boot <= HOLD; holdCnt <= (others => '1');
            else
               diskWait <= diskWait + 1;
            end if;
         end if;

         -- hold the CPU long enough for the clk93 side to see it
         if (boot = HOLD) then
            if (holdCnt = 0) then boot <= RUN; else holdCnt <= holdCnt - 1; end if;
         end if;

         -- debug console log ring (the HPS client is idle while running)
         if (dbg_tx = '1' and logWr + 1 /= logRd) then
            logQ(to_integer(logWr)) <= dbg_tx_data;
            logWr <= logWr + 1;
         end if;
         logByte <= logQ(to_integer(logRd));
         if (boot = RUN and hpsBusy = '0' and hpsReq = '0' and not (trFr2 = '1' and dumped = '0')) then
            if (logPh = '0' and logRd /= logWr) then
               -- the byte (logByte = logQ(logRd), read last cycle) into its lane
               hpsAddr  <= x"0FB0000" + resize(logCount(15 downto 3) & "000", 28);
               hpsData  <= logByte & logByte & logByte & logByte & logByte & logByte & logByte & logByte;
               hpsMask  <= (others => '0');
               hpsMask(to_integer(logCount(2 downto 0))) <= '1';
               hpsReq   <= '1';
               hpsBusy  <= '1';
               logPh    <= '1';
               logRd    <= logRd + 1;
               logCount <= logCount + 1;
            elsif (logPh = '1') then
               hpsAddr  <= x"0FC0000";
               hpsData  <= x"00000000" & std_logic_vector(logCount);
               hpsMask  <= x"FF";
               hpsReq   <= '1';
               hpsBusy  <= '1';
               logPh    <= '0';
            end if;
         end if;
         if (boot /= RUN and boot /= HOLD) then
            if (boot = CLEAR) then logCount <= (others => '0'); logPh <= '0'; end if;
         end if;

         -- branch trace dump (the HPS client is idle while running). trWi is the CPU clock's: it is
         -- static once the trace is frozen, so read it through a clk1x register (the adder on the
         -- crossing was the 62.5 MHz critical path)
         trWi1x <= trWi; trFr1 <= trFrozen; trFr2 <= trFr1;
         if (boot = RUN and trFr2 = '1' and dumped = '0' and hpsBusy = '0' and hpsReq = '0') then
            if (dumpPh = 0) then
               trRA   <= trWi1x + to_unsigned(dumpIdx mod 1024, 10);
               dumpPh <= 1;
            elsif (dumpPh < 3) then
               dumpPh <= dumpPh + 1;                  -- trQ valid after the registered read
            else
               dumpPh  <= 0;
               hpsReq  <= '1';
               hpsBusy <= '1';
               hpsMask <= x"FF";
               if (dumpIdx = 1024) then
                  hpsAddr <= x"0FA2000";
                  hpsData <= x"C0DEDEAD" & x"00000" & "00" & std_logic_vector(trWi1x);
                  dumped  <= '1';
               else
                  hpsAddr <= x"0FA0000" + to_unsigned(dumpIdx * 8, 28);
                  hpsData <= trQ;
                  dumpIdx <= dumpIdx + 1;
               end if;
            end if;
         end if;
         if (boot /= RUN) then dumped <= '0'; dumpIdx <= 0; dumpPh <= 0; end if;

         if (boot = RUN and soft_reset = '1') then
            boot <= HOLD; holdCnt <= (others => '1');
         end if;

         if (reset = '1' and romLoaded = '1' and boot /= LOADING) then
            boot <= CLEAR; clearAddr <= (others => '0');
         end if;

         if (pll_locked = '0') then
            boot <= WAIT_ROM; romLoaded <= '0';
         end if;

         if (boot = RUN) then hold1x <= '0'; else hold1x <= '1'; end if;
         if (boot = CLEAR) then coldReset <= '1'; else coldReset <= '0'; end if;
         -- synthesis translate_off
         bootLast <= boot;
         if (boot /= bootLast) then report "boot state " & tBoot'image(boot); end if;
         -- synthesis translate_on
         reset_1x <= hold1x;
      end if;
   end process;

   ---------------------------------------------------------------- CPU start (clk93)
   process (clk93)
   begin
      if rising_edge(clk93) then
         hold93_s <= hold93_s(0) & hold1x;
         SS_wren  <= '0';
         if (hold93_s(1) = '1') then
            reset_93 <= '1';
            SS_reset <= '1';
            seq93    <= (others => '0');
         elsif (reset_93 = '1') then
            SS_reset <= '0';
            seq93    <= seq93 + 1;
            case to_integer(seq93) is
               when 1 => SS_Adr <= to_unsigned(64 + 12, 12); SS_Data <= SR_RESET;      SS_wren <= '1';
               when 2 => SS_Adr <= to_unsigned(64 + 16, 12); SS_Data <= CONFIG_RESET;  SS_wren <= '1';
               when 3 => SS_Adr <= to_unsigned(64 + 11, 12); SS_Data <= COMPARE_RESET; SS_wren <= '1';
               when 100 => reset_93 <= '0';
               when others => null;
            end case;
         end if;
      end if;
   end process;

   ---------------------------------------------------------------- core
   icore : entity work.webtv_core
   generic map (CLK93_HZ => CLK93_HZ, CLK1X_HZ => CLK1X_HZ)
   port map (
      clk1x => clk1x, clk93 => clk93, clk2x => clk2x,
      reset_1x => reset_1x, reset_93 => reset_93, reset_mem => memReset, cold_reset => coldReset,
      irqRequest => '0', IRQ_EXTERNAL => '0', solo_irq => open,
      serial_id => serial_id, soft_reset => soft_reset, led => ledI,
      dbg_tx => dbg_tx, dbg_tx_data => dbg_tx_data, dbg_rx => dbg_rx, dbg_rx_data => dbg_rx_data,
      bus_addr => open, bus_read => bus_read, bus_write => bus_write, bus_be => open,
      bus_dataWrite => open, bus_dataRead => (others => '0'), bus_done => bus_done, bus_tick => open,
      img_mounted => img_mounted, img_size => unsigned(img_size),
      sd_lba => sdLba, sd_blk_cnt => sdBlkCnt, sd_rd => sdRdI, sd_wr => sd_wr, sd_ack => sd_ack,
      sd_buff_addr => unsigned(sd_buff_addr), sd_buff_dout => sd_buff_dout, sd_buff_din => sd_buff_din, sd_buff_wr => sd_buff_wr,
      modem_txd => mTxd, modem_rxd => mRxd, modem_dcd => uart_modem and not uart_dsr, modem_rts_n => mRtsN, modem_mcr => mMcr,
      ir_key_strobe => keyStrobe, ir_key_code => keyCode, ir_key_release => keyRelease,
      fb_display => fb_display, fb_frame => fb_frame,
      vid_hblank => hbI, vid_vblank => vbI, vid_hsync => vid_hsync, vid_vsync => vid_vsync,
      vid_ce => vceI,
      hps_request => hpsReq, hps_rnw => '0', hps_address => hpsAddr, hps_burstcount => 10x"001",
      hps_writeMask => hpsMask, hps_dataWrite => hpsData, hps_done => hpsDone, hps_dataRead => open,
      ddr3_BUSY => ddr3_BUSY, ddr3_DOUT => ddr3_DOUT, ddr3_DOUT_READY => ddr3_DOUT_READY,
      ddr3_BURSTCNT => ddr3_BURSTCNT, ddr3_ADDR => ddr3_ADDR, ddr3_DIN => ddr3_DIN, ddr3_BE => ddr3_BE,
      ddr3_WE => ddr3_WE, ddr3_RD => ddr3_RD,
      errors => errI, dbg_retired_cnt => retiredCnt, dbg_pc => pcI, dbg_scr => scrI,
      dbg_ide => ideI,
      trace_frozen => trFrozen, trace_wi => trWi, trace_ra => trRA, trace_q => trQ,
      SS_reset => SS_reset, SS_wren => SS_wren, SS_Adr => SS_Adr, SS_Data => SS_Data,
-- synthesis translate_off
      cpu_done => open, cpu_export => open,
-- synthesis translate_on
      dbg_issued => open, dbg_solo_rd => open, dbg_solo_addr => open, dbg_solo_data => open
   );

   -- keyboard / joystick -> IR keyboard key events (one per cycle; the keyboard first)
   process (clk1x)
      variable m : std_logic_vector(7 downto 0);
   begin
      if rising_edge(clk1x) then
         keyStrobe <= '0';
         if (ps2_key(10) /= ps2Tgl) then
            ps2Tgl <= ps2_key(10);
            m := ps2Sejin(ps2_key(8), ps2_key(7 downto 0));
            if (m(7) = '1') then
               keyStrobe  <= '1';
               keyCode    <= m(6 downto 0);
               keyRelease <= not ps2_key(9);
            end if;
         else
            for i in 0 to 10 loop
               if (joy(i) /= joySent(i)) then
                  keyStrobe  <= '1';
                  keyCode    <= JOY_KEYS(i);
                  keyRelease <= not joy(i);
                  joySent(i) <= joy(i);
                  exit;
               end if;
            end loop;
         end if;
      end if;
   end process;

   -- MMIO units not in RTL yet: answer at once, reads return 0
   process (clk1x)
   begin
      if rising_edge(clk1x) then
         bus_done <= (bus_read or bus_write) and not reset_1x;
      end if;
   end process;

   -- video: show the last completed frame
   fb_base <= std_logic_vector(DDR3_WINDOW + resize(fb_display, 32));
   process (clk1x)
   begin
      if rising_edge(clk1x) then
         if (reset_1x = '1' and romLoaded = '0') then
            fb_en <= '0';
         elsif (fb_frame = '1') then
            fb_en <= '1';
         end if;
      end if;
   end process;

   ---------------------------------------------------------------- debug serial
   process (clk1x)
      variable l : tLast;
   begin
      if rising_edge(clk1x) then
         -- TX: FIFO (drops when full), 8N1
         if (dbg_tx = '1' and txWr + 1 /= txRd) then
            txFifo(to_integer(txWr)) <= dbg_tx_data;
            txWr <= txWr + 1;
         end if;
         txQ <= txFifo(to_integer(txRd));          -- block RAM read (one cycle)
         if (txBits = 0) then
            if (txWr /= txRd) then
               if (txWait = 2) then
                  txShift <= '1' & txQ & '0';
                  txRd    <= txRd + 1;
                  txBits  <= 10;
                  txCnt   <= BAUD_DIV - 1;
                  txWait  <= 0;
               else
                  txWait <= txWait + 1;
               end if;
            end if;
         elsif (txCnt = 0) then
            txShift <= '1' & txShift(9 downto 1);
            txBits  <= txBits - 1;
            txCnt   <= BAUD_DIV - 1;
         else
            txCnt <= txCnt - 1;
         end if;
         if (txBits = 0) then dbgTxd <= '1'; else dbgTxd <= txShift(0); end if;

         -- RX: 8N1, sample mid-bit
         rxSync   <= rxSync(1 downto 0) & dbgRxd;
         rxStrobe <= '0';
         if (rxActive = '0') then
            if (rxSync(2) = '0') then
               rxActive <= '1';
               rxCnt    <= BAUD_DIV + BAUD_DIV / 2 - 1;
               rxBits   <= 0;
            end if;
         elsif (rxCnt = 0) then
            if (rxBits = 8) then
               rxActive <= '0';
               if (rxSync(2) = '1') then rxStrobe <= '1'; rxByte <= rxShift; end if;
            else
               rxShift <= rxSync(2) & rxShift(7 downto 1);
               rxBits  <= rxBits + 1;
               rxCnt   <= BAUD_DIV - 1;
            end if;
         else
            rxCnt <= rxCnt - 1;
         end if;

         -- auto-answer the boot ROM's "Disk Boot?" (as the JS harness does)
         autoY <= '0';
         if (dbg_tx = '1' and dbg_tx_data /= x"0D" and dbg_tx_data /= x"0A") then
            l := lastTx(1 to 9) & dbg_tx_data;
            lastTx <= l;
            if (autoboot_y = '1' and str_match(l, "Disk Boot?")) then autoY <= '1'; end if;
         end if;
      end if;
   end process;

   dbg_rx      <= rxStrobe or autoY;
   dbg_rx_data <= x"79" when autoY = '1' else rxByte;

end architecture;
