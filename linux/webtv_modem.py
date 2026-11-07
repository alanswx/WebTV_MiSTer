#!/usr/bin/env python3
"""WebTV MiSTer core: the modem's line side, run on the MiSTer's Linux (HPS).

The core's 16550 (the LC2 hardware modem UART) is wired to the HPS UART (/dev/ttyS1) when the OSD
"Serial port" option is set to "Modem". This program plays the Rockwell modem behind it, as the
webtv-bridge JS model does (src/machine/modem.js):

  * command mode: AT commands, echo, verbose / numeric result codes, S-registers
  * AT** firmware download (TellyScript's Rockwell modem downloader): the S-record loader and the
    firmware are accepted and discarded, with the same answers and quiet-time rules as the JS model
  * dialing: without a network line, ATD answers NO DIALTONE (as the JS model without a line);
    with --connect, ATD "connects" and bytes are relayed to a TCP endpoint (e.g. a PPP server)
  * DTR: the box dropping DTR (power off, hangup, reboot) hangs up and returns to command mode (&D2)
  * carrier detect: the core takes DCD from the HPS DTR line (asserted while connected)

The core's debug console is logged into DDR3; --log prints it (from /dev/mem 0x30FB0000).

usage: webtv_modem.py [--tty /dev/ttyS1] [--connect host:port] [--log] [--trace]
                      [--config FILE] [--core WebTV] [--logfile FILE]

--core WebTV only opens the UART while that core is loaded (/tmp/CORENAME), so the daemon can run
all the time without taking the serial port from other cores.
"""
import argparse, mmap, os, select, socket, struct, sys, termios, time, fcntl

CR, LF = 13, 10
DL_QUIET_S = 0.05
RATE = 11520          # bytes/s towards the box


class Output:
    """stdout, or a log file kept under a size limit (one old copy, FILE.1)."""
    def __init__(self, path=None, limit=4 << 20):
        self.path, self.limit, self.f = path, limit, None
        if path:
            self.f = open(path, 'a', encoding='latin-1')

    def write(self, text):
        if not self.f:
            sys.stdout.write(text)
            sys.stdout.flush()
            return
        try:
            # the file may have been moved, deleted or truncated under us: follow the path
            st_fd = os.fstat(self.f.fileno())
            try:
                st_path = os.stat(self.path)
                moved = (st_path.st_ino, st_path.st_dev) != (st_fd.st_ino, st_fd.st_dev)
            except FileNotFoundError:
                moved = True
            if moved:
                self.f.close()
                self.f = open(self.path, 'a', encoding='latin-1')
            self.f.write(text)
            self.f.flush()
            if os.fstat(self.f.fileno()).st_size > self.limit:
                self.f.close()
                os.replace(self.path, self.path + '.1')
                self.f = open(self.path, 'a', encoding='latin-1')
        except OSError:
            pass


OUT = Output()


class Modem:
    def __init__(self, fd, connect=None, trace=False):
        self.fd = fd
        self.connect_to = connect
        self.trace = trace
        self.sock = None
        self.out = bytearray()
        self.reset()
        self.dtr = self.box_dtr()

    # ---------------------------------------------------------------- state
    def reset(self):
        self.cmd = ''
        self.echo = True
        self.verbose = True
        self.quiet = False
        self.online = False
        self.connected = False
        self.download = 0
        self.download_count = 0
        self.dl_line = ''
        self.dl_data = False
        self.dl_end_at = None
        self.dl_idle_at = None
        self.plus_count = 0
        self.last_tx = 0.0
        self.esc_at = None
        self.dial_at = None
        self.dial_result = None
        self.dialed = None
        self.sregs = bytearray(256)
        self.sregs[2] = 43; self.sregs[3] = 13; self.sregs[4] = 10; self.sregs[5] = 8; self.sregs[12] = 50
        self.set_dcd(False)

    def set_dcd(self, on):
        # the core's DCD = HPS DTR asserted
        try:
            fcntl.ioctl(self.fd, termios.TIOCMBIS if on else termios.TIOCMBIC, struct.pack('I', termios.TIOCM_DTR))
        except OSError:
            pass

    def log(self, s):
        OUT.write(f'[modem] {s}\n')

    def box_dtr(self):
        # the box's DTR (UART MCR bit 0) reaches the HPS UART as DSR/DCD
        try:
            v = struct.unpack('I', fcntl.ioctl(self.fd, termios.TIOCMGET, struct.pack('I', 0)))[0]
            return bool(v & termios.TIOCM_DSR)
        except OSError:
            return None

    def check_dtr(self):
        # &D2: the box dropping DTR hangs up and returns to command mode. The box drops it on every
        # hangup and power-off, and on its own reboots; without this the modem stays online to the
        # old call and the box's next AT** (firmware download) goes down the line instead.
        d = self.box_dtr()
        if d is None or d == self.dtr:
            return
        self.dtr = d
        self.log(f'DTR {"up" if d else "down"}')
        if not d:
            if self.online or self.connected or self.sock or self.dial_at:
                self.hangup('DTR down')
            self.cmd = ''
            self.download = 0
            self.dl_end_at = self.dl_idle_at = None
            self.out.clear()

    # ---------------------------------------------------------------- host -> modem
    def from_host(self, b):
        if self.trace:
            OUT.write(f'> {b:02x} {chr(b) if 32 <= b < 127 else ""}\n')
        if self.online:
            self.last_tx = time.monotonic()
            if b == self.sregs[2]:
                self.plus_count += 1
                if self.plus_count == 3:
                    self.esc_at = time.monotonic() + 1.0
            else:
                self.plus_count = 0
            if self.sock:
                try:
                    self.sock.sendall(bytes([b]))
                except OSError:
                    self.hangup('send failed')
            return
        if self.download:
            self.download_byte(b)
            return
        if self.echo:
            self.queue(bytes([b]))
        if b == self.sregs[5]:
            self.cmd = self.cmd[:-1]
            return
        if b == CR:
            line = self.cmd.strip()
            self.cmd = ''
            u = line.upper()
            at = u.rfind('AT')
            if at >= 0:
                self.command(u[at + 2:])
            return
        if b == LF:
            return
        self.cmd = (self.cmd + chr(b))[-256:]

    # ---------------------------------------------------------------- firmware download
    def download_byte(self, b):
        now = time.monotonic()
        self.download_count += 1
        if self.dl_end_at is not None:
            self.dl_end_at = now + DL_QUIET_S
        if self.download == 2:
            if not self.dl_data and b in (CR, LF):
                self.download_count -= 1
                return
            self.dl_data = True
            self.dl_idle_at = now + 0.2
        if b in (CR, LF):
            rec = self.dl_line
            self.dl_line = ''
            if rec[:2] in ('S7', 'S8', 'S9'):
                self.dl_end_at = now + DL_QUIET_S
            return
        self.dl_line += chr(b)
        if len(self.dl_line) > 600:
            self.dl_line = ''

    def download_done(self):
        if not self.download:
            return
        self.dl_end_at = self.dl_idle_at = None
        self.log(f'download phase {self.download}: {self.download_count} bytes')
        small = self.download_count < 512
        self.download_count = 0
        if self.download == 1 and small:          # NULL loader: back to command mode
            self.download = 0
            return
        if self.download == 1:
            self.download = 2
            self.dl_data = False
            self.queue(b'\r\nBinary Ram Loader - V0.08\r\nDownload Modem Firmware ..\r\n')
            return
        self.download = 0
        self.queue(b'Modem Firmware Successfully Loaded\r\n')

    # ---------------------------------------------------------------- AT commands
    def command(self, s):
        self.log(f'AT{s}')
        if s.startswith('**'):
            self.download = 1
            self.download_count = 0
            self.dl_line = ''
            self.queue(b'\r\nOK\r\n')
            return
        i = 0

        def num():
            nonlocal i
            n = ''
            while i < len(s) and s[i].isdigit():
                n += s[i]; i += 1
            return int(n) if n else 0

        while i < len(s):
            c = s[i]; i += 1
            if c == ' ':
                continue
            if c == 'D':
                rest = s[i:]
                self.dial(''.join(ch for ch in rest if ch in '0123456789*#,WP'), ';' in rest)
                return
            if c == 'A':
                self.result('NO CARRIER'); return
            if c == 'H':
                num()
                if self.online:
                    self.hangup()
                continue
            if c == 'O':
                num()
                if self.connected:
                    self.online = True; self.result('CONNECT'); return
                self.result('NO CARRIER'); return
            if c == 'Z':
                num(); self.echo = True; self.verbose = True; self.quiet = False; continue
            if c == 'E':
                self.echo = num() != 0; continue
            if c == 'V':
                self.verbose = num() != 0; continue
            if c == 'Q':
                self.quiet = num() != 0; continue
            if c == 'S':
                r = num()
                if i < len(s) and s[i] == '=':
                    i += 1; self.sregs[r & 255] = num() & 255
                elif i < len(s) and s[i] == '?':
                    i += 1; self.queue(f'\r\n{self.sregs[r & 255]:03d}\r\n'.encode())
                continue
            if c == 'I':
                n = num(); self.queue(('\r\n56000\r\n' if n == 0 else '\r\nWebTV emulated modem\r\n').encode()); continue
            if c in '&%\\+-#*$':
                i += 1; num()
                if i < len(s) and s[i] == '=':
                    i += 1
                    while i < len(s) and (s[i].isdigit() or s[i] == ','):
                        i += 1
                continue
            num()
        self.result('OK')

    def dial(self, number, stay):
        self.log(f'dialing {number or "(none)"}{" (stay in command mode)" if stay else ""}')
        now = time.monotonic()
        if not self.connect_to:
            self.dial_at, self.dial_result = now + 2.0, 'NO DIALTONE'
            return
        if stay:
            self.dialed = number
            self.dial_at, self.dial_result = now + 1.0, 'OK'
            return
        if self.sock:                              # a call still up: drop it first
            self.hangup()
        self.set_dcd(False)
        host, port = self.connect_to.rsplit(':', 1)
        try:
            self.sock = socket.create_connection((host, int(port)), timeout=10)
            self.sock.setblocking(False)
            self.dial_at, self.dial_result = now + 1.5, 'CONNECT 57600'
        except OSError as e:
            self.log(f'connect {self.connect_to} failed: {e}')
            self.sock = None
            self.dial_at, self.dial_result = now + 1.5, 'NO CARRIER'

    def hangup(self, why=None):
        if why:
            self.log(f'hangup ({why})')
        was = self.online or self.connected
        self.online = self.connected = False
        self.dial_at = None
        self.out.clear()
        if self.sock:
            try:
                self.sock.close()
            except OSError:
                pass
            self.sock = None
        self.set_dcd(False)
        if was and why and why != 'DTR down':
            self.result('NO CARRIER')

    # ---------------------------------------------------------------- modem -> host
    def result(self, text):
        if self.quiet:
            return
        if self.verbose:
            self.queue(f'\r\n{text}\r\n'.encode())
            return
        codes = {'OK': 0, 'CONNECT': 1, 'RING': 2, 'NO CARRIER': 3, 'ERROR': 4, 'NO DIALTONE': 6, 'BUSY': 7,
                 'NO ANSWER': 8, 'CONNECT 57600': 18}
        self.queue(f'{codes.get(text, codes.get(text.split(" ")[0], 1))}\r'.encode())

    def queue(self, data):
        self.out += data

    # ---------------------------------------------------------------- timers
    def poll(self):
        now = time.monotonic()
        if self.download and ((self.dl_end_at and now >= self.dl_end_at) or (self.dl_idle_at and now >= self.dl_idle_at)):
            self.download_done()
        if self.esc_at and now >= self.esc_at:
            self.esc_at = None
            if self.online and self.plus_count == 3 and now - self.last_tx >= 0.9:
                self.online = False
                self.result('OK')
            self.plus_count = 0
        if self.dial_at and now >= self.dial_at:
            self.dial_at = None
            r = self.dial_result
            if r.startswith('CONNECT'):
                self.connected = True
                self.set_dcd(True)
                self.result(r)
                self.online = True
            else:
                self.result(r)


def open_tty(path):
    fd = os.open(path, os.O_RDWR | os.O_NOCTTY | os.O_NONBLOCK)
    a = termios.tcgetattr(fd)
    a[0] = 0                                   # iflag
    a[1] = 0                                   # oflag
    a[2] = termios.CS8 | termios.CREAD | termios.CLOCAL
    a[3] = 0                                   # lflag
    a[4] = a[5] = termios.B115200
    a[6][termios.VMIN] = 0
    a[6][termios.VTIME] = 0
    termios.tcsetattr(fd, termios.TCSANOW, a)
    termios.tcflush(fd, termios.TCIOFLUSH)
    return fd


class DebugLog:
    """The core's debug console, logged into DDR3."""
    def __init__(self):
        fd = os.open('/dev/mem', os.O_RDONLY | os.O_SYNC)
        self.ring = mmap.mmap(fd, 0x10000, mmap.MAP_SHARED, mmap.PROT_READ, offset=0x30FB0000)
        self.cnt = mmap.mmap(fd, 0x1000, mmap.MAP_SHARED, mmap.PROT_READ, offset=0x30FC0000)
        os.close(fd)                       # the mappings stay valid
        self.seen = self.count()

    def count(self):
        return struct.unpack('<I', self.cnt[0:4])[0]

    def poll(self):
        n = self.count()
        if n < self.seen or n - self.seen > 0x10000:
            self.seen = max(0, n - 0x10000)
        if n != self.seen:
            out = bytearray()
            for k in range(self.seen, n):
                out.append(self.ring[k & 0xFFFF])
            self.seen = n
            OUT.write(out.replace(b'\r', b'').decode('latin-1'))


def read_config(path):
    """KEY=VALUE lines (# comments): connect, tty, log, trace."""
    cfg = {}
    try:
        with open(path) as f:
            for line in f:
                line = line.split('#', 1)[0].strip()
                if '=' in line:
                    k, v = line.split('=', 1)
                    cfg[k.strip().lower()] = v.strip()
    except OSError:
        pass
    return cfg


def core_name():
    try:
        with open('/tmp/CORENAME') as f:
            return f.read().strip()
    except OSError:
        return ''


def run(args, active):
    """One session on the UART, until active() turns false."""
    fd = open_tty(args.tty)
    m = Modem(fd, args.connect, args.trace)
    dbg = DebugLog() if args.log else None
    m.log(f'on {args.tty}' + (f', line {args.connect}' if args.connect else ', no line (NO DIALTONE)'))
    next_out = time.monotonic()
    next_check = 0.0
    try:
        while True:
            now = time.monotonic()
            if now >= next_check:
                next_check = now + 0.5
                if not active():
                    m.log('core unloaded: releasing the UART')
                    return
            rl = [fd] + ([m.sock] if m.sock else [])
            r, _, _ = select.select(rl, [], [], 0.005)
            if fd in r:
                try:
                    data = os.read(fd, 4096)
                except BlockingIOError:
                    data = b''
                for b in data:
                    m.from_host(b)
            if m.sock and m.sock in r:
                try:
                    data = m.sock.recv(4096)
                    if not data:
                        m.hangup('remote')
                    elif m.online:
                        m.out += data
                except BlockingIOError:
                    pass
                except OSError:
                    m.hangup('remote error')
            m.check_dtr()
            m.poll()
            # pace towards the box at ~line speed
            now = time.monotonic()
            if m.out and now >= next_out:
                n = max(1, min(len(m.out), int((now - next_out) * RATE) + 1, 64))
                try:
                    w = os.write(fd, bytes(m.out[:n]))
                    del m.out[:w]
                except BlockingIOError:
                    pass
                next_out = now + n / RATE
            if dbg:
                dbg.poll()
    finally:
        m.hangup()
        os.close(fd)


def main():
    global OUT
    ap = argparse.ArgumentParser()
    ap.add_argument('--config', help='KEY=VALUE file (connect=HOST:PORT, log=1, ...); arguments override it')
    ap.add_argument('--tty')
    ap.add_argument('--connect', help='host:port to relay the online data to (e.g. a PPP server)')
    ap.add_argument('--log', action='store_true', default=None, help='print the core debug console')
    ap.add_argument('--trace', action='store_true', default=None, help='print every byte from the box')
    ap.add_argument('--core', help='run only while this core is loaded (/tmp/CORENAME), e.g. WebTV')
    ap.add_argument('--logfile', help='write to this file (kept under 4 MB, one old copy) instead of stdout')
    args = ap.parse_args()
    cfg = read_config(args.config) if args.config else {}
    yes = lambda v: str(v).lower() in ('1', 'yes', 'true', 'on')
    args.tty = args.tty or cfg.get('tty', '/dev/ttyS1')
    args.connect = args.connect or cfg.get('connect') or None
    args.log = args.log if args.log is not None else yes(cfg.get('log', '0'))
    args.trace = args.trace if args.trace is not None else yes(cfg.get('trace', '0'))
    if args.logfile:
        OUT = Output(args.logfile)
    if not args.core:
        run(args, lambda: True)
        return
    active = lambda: core_name() == args.core
    while True:
        while not active():
            time.sleep(1)
        time.sleep(1)                      # let the core come up
        try:
            run(args, active)
        except OSError as e:
            OUT.write(f'[modem] {e}; retrying\n')
            time.sleep(2)


if __name__ == '__main__':
    main()
