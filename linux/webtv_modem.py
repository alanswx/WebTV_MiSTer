#!/usr/bin/env python3
"""WebTV MiSTer core: the modem, the phone line and the WebTV service, run on the MiSTer's Linux.

One file, Python 3 standard library only (the MiSTer has Python 3.9 and no pip).

  box (FPGA) -- 16550 UART -- /dev/ttyS1 -- Modem -- Line: PPP server -- IP/TCP gateway -- WebTV service
                                                                                         \\- web pages (fetched here)

The core's 16550 (the LC2 hardware modem UART) is wired to the HPS UART (/dev/ttyS1) when the OSD
"Serial port" option is set to "Modem". This program:

  * plays the Rockwell modem: AT commands, the AT** firmware download TellyScript sends (accepted and
    discarded), dialing, DTR (the box dropping DTR hangs up, &D2), carrier detect (the core takes DCD
    from the HPS DTR line)
  * answers the call itself (connect=local, the default): a PPP server, a user-space IP/TCP gateway
    (every connection to a WTVP port goes to the service, whatever address the box dials), DNS, and
    a WebTV service: registration, login (challenge/response, tickets, RC4), home page, and web pages
    fetched for the box (UTF-8 text made Latin-1, images the box can't show converted or shrunk)
  * or relays the call to a line server elsewhere (connect=HOST:PORT)

Ported from webtv-bridge (src/net, src/wtvsrv), whose service follows zefie's minisrv.

usage: webtv_modem.py [--config FILE] [--tty /dev/ttyS1] [--connect local|HOST:PORT] [--log] [--trace]
                      [--core WebTV] [--logfile FILE] [--store FILE] [--verbose]
       webtv_modem.py --listen PORT [...]     answer calls from modems over TCP (a LAN line server)

--core WebTV only opens the UART while that core is loaded (/tmp/CORENAME), so the daemon can run
all the time without taking the serial port from other cores.
"""
import argparse, base64, collections, ctypes, ctypes.util, email.utils, fcntl, hashlib, heapq, json, mmap
import os, random, re, select, socket, ssl, struct, sys, tempfile, termios, threading, time, traceback
import urllib.error, urllib.parse, urllib.request, zlib

HERE = os.path.dirname(os.path.abspath(__file__))
CR, LF = 13, 10
DL_QUIET_S = 0.05
RATE = 11520          # bytes/s towards the box
VERBOSE = False


# ==================================================================================== output

class Output:
    """stdout, or a log file kept under a size limit (one old copy, FILE.1)."""
    def __init__(self, path=None, limit=4 << 20):
        self.path, self.limit, self.f = path, limit, None
        self.lock = threading.Lock()
        self.bol = True                       # the last write ended a line
        if path:
            self.f = open(path, 'a', encoding='latin-1')

    def line(self, text):
        """A whole line, on a line of its own (the box's console output may have left one open)."""
        self.write(('' if self.bol else '\n') + text + '\n')

    def write(self, text):
        if not text:
            return
        with self.lock:
            self.bol = text.endswith('\n')
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


def log(s):
    OUT.line(time.strftime('%H:%M:%S ') + s)


def vlog(s):
    if VERBOSE:
        log(s)


# ==================================================================================== event loop
# One thread runs everything (the modem, PPP, TCP, the service); blocking work (DNS, fetching web
# pages, outside TCP connections) runs in worker threads that hand their results back with call_soon.

class Timer:
    __slots__ = ('when', 'fn', 'alive')

    def __init__(self, when, fn):
        self.when, self.fn, self.alive = when, fn, True

    def cancel(self):
        self.alive = False

    def __lt__(self, o):
        return self.when < o.when


class Loop:
    def __init__(self):
        self.timers = []
        self.q = collections.deque()
        self.r, self.w = os.pipe()
        for fd in (self.r, self.w):
            fcntl.fcntl(fd, fcntl.F_SETFL, fcntl.fcntl(fd, fcntl.F_GETFL) | os.O_NONBLOCK)

    def call_later(self, delay, fn):
        t = Timer(time.monotonic() + delay, fn)
        heapq.heappush(self.timers, t)
        return t

    def call_soon(self, fn):
        """Thread-safe."""
        self.q.append(fn)
        try:
            os.write(self.w, b'.')
        except OSError:
            pass

    def thread(self, work, done):
        """work() in a worker thread; done(result, error) back on the loop."""
        def run():
            try:
                r, e = work(), None
            except Exception as ex:          # noqa: BLE001 -- handed to done()
                r, e = None, ex
            self.call_soon(lambda: done(r, e))
        threading.Thread(target=run, daemon=True).start()

    def timeout(self, cap):
        while self.timers and not self.timers[0].alive:
            heapq.heappop(self.timers)
        if self.q:
            return 0
        if not self.timers:
            return cap
        return max(0, min(cap, self.timers[0].when - time.monotonic()))

    def run_due(self):
        try:
            while os.read(self.r, 4096):
                pass
        except OSError:
            pass
        while self.q:
            self._call(self.q.popleft())
        now = time.monotonic()
        while self.timers and self.timers[0].when <= now:
            t = heapq.heappop(self.timers)
            if t.alive:
                t.alive = False
                self._call(t.fn)

    @staticmethod
    def _call(fn):
        try:
            fn()
        except Exception:                    # noqa: BLE001 -- one bad packet must not stop the box
            log('[error] ' + traceback.format_exc().rstrip().replace('\n', '\n    '))


LOOP = Loop()


# ==================================================================================== crypto
# MD5 (hashlib), single DES (ECB) and RC4: what the WTVP security protocol uses.

def md5(b):
    return hashlib.md5(bytes(b)).digest()


_PC1 = [57, 49, 41, 33, 25, 17, 9, 1, 58, 50, 42, 34, 26, 18, 10, 2, 59, 51, 43, 35, 27, 19, 11, 3, 60, 52, 44, 36,
        63, 55, 47, 39, 31, 23, 15, 7, 62, 54, 46, 38, 30, 22, 14, 6, 61, 53, 45, 37, 29, 21, 13, 5, 28, 20, 12, 4]
_PC2 = [14, 17, 11, 24, 1, 5, 3, 28, 15, 6, 21, 10, 23, 19, 12, 4, 26, 8, 16, 7, 27, 20, 13, 2,
        41, 52, 31, 37, 47, 55, 30, 40, 51, 45, 33, 48, 44, 49, 39, 56, 34, 53, 46, 42, 50, 36, 29, 32]
_SHIFTS = [1, 1, 2, 2, 2, 2, 2, 2, 1, 2, 2, 2, 2, 2, 2, 1]
_IP = [58, 50, 42, 34, 26, 18, 10, 2, 60, 52, 44, 36, 28, 20, 12, 4, 62, 54, 46, 38, 30, 22, 14, 6, 64, 56, 48, 40, 32, 24, 16, 8,
       57, 49, 41, 33, 25, 17, 9, 1, 59, 51, 43, 35, 27, 19, 11, 3, 61, 53, 45, 37, 29, 21, 13, 5, 63, 55, 47, 39, 31, 23, 15, 7]
_FP = [40, 8, 48, 16, 56, 24, 64, 32, 39, 7, 47, 15, 55, 23, 63, 31, 38, 6, 46, 14, 54, 22, 62, 30, 37, 5, 45, 13, 53, 21, 61, 29,
       36, 4, 44, 12, 52, 20, 60, 28, 35, 3, 43, 11, 51, 19, 59, 27, 34, 2, 42, 10, 50, 18, 58, 26, 33, 1, 41, 9, 49, 17, 57, 25]
_E = [32, 1, 2, 3, 4, 5, 4, 5, 6, 7, 8, 9, 8, 9, 10, 11, 12, 13, 12, 13, 14, 15, 16, 17,
      16, 17, 18, 19, 20, 21, 20, 21, 22, 23, 24, 25, 24, 25, 26, 27, 28, 29, 28, 29, 30, 31, 32, 1]
_P = [16, 7, 20, 21, 29, 12, 28, 17, 1, 15, 23, 26, 5, 18, 31, 10, 2, 8, 24, 14, 32, 27, 3, 9, 19, 13, 30, 6, 22, 11, 4, 25]
_SBOX = [
    [14, 4, 13, 1, 2, 15, 11, 8, 3, 10, 6, 12, 5, 9, 0, 7, 0, 15, 7, 4, 14, 2, 13, 1, 10, 6, 12, 11, 9, 5, 3, 8, 4, 1, 14, 8, 13, 6, 2, 11, 15, 12, 9, 7, 3, 10, 5, 0, 15, 12, 8, 2, 4, 9, 1, 7, 5, 11, 3, 14, 10, 0, 6, 13],
    [15, 1, 8, 14, 6, 11, 3, 4, 9, 7, 2, 13, 12, 0, 5, 10, 3, 13, 4, 7, 15, 2, 8, 14, 12, 0, 1, 10, 6, 9, 11, 5, 0, 14, 7, 11, 10, 4, 13, 1, 5, 8, 12, 6, 9, 3, 2, 15, 13, 8, 10, 1, 3, 15, 4, 2, 11, 6, 7, 12, 0, 5, 14, 9],
    [10, 0, 9, 14, 6, 3, 15, 5, 1, 13, 12, 7, 11, 4, 2, 8, 13, 7, 0, 9, 3, 4, 6, 10, 2, 8, 5, 14, 12, 11, 15, 1, 13, 6, 4, 9, 8, 15, 3, 0, 11, 1, 2, 12, 5, 10, 14, 7, 1, 10, 13, 0, 6, 9, 8, 7, 4, 15, 14, 3, 11, 5, 2, 12],
    [7, 13, 14, 3, 0, 6, 9, 10, 1, 2, 8, 5, 11, 12, 4, 15, 13, 8, 11, 5, 6, 15, 0, 3, 4, 7, 2, 12, 1, 10, 14, 9, 10, 6, 9, 0, 12, 11, 7, 13, 15, 1, 3, 14, 5, 2, 8, 4, 3, 15, 0, 6, 10, 1, 13, 8, 9, 4, 5, 11, 12, 7, 2, 14],
    [2, 12, 4, 1, 7, 10, 11, 6, 8, 5, 3, 15, 13, 0, 14, 9, 14, 11, 2, 12, 4, 7, 13, 1, 5, 0, 15, 10, 3, 9, 8, 6, 4, 2, 1, 11, 10, 13, 7, 8, 15, 9, 12, 5, 6, 3, 0, 14, 11, 8, 12, 7, 1, 14, 2, 13, 6, 15, 0, 9, 10, 4, 5, 3],
    [12, 1, 10, 15, 9, 2, 6, 8, 0, 13, 3, 4, 14, 7, 5, 11, 10, 15, 4, 2, 7, 12, 9, 5, 6, 1, 13, 14, 0, 11, 3, 8, 9, 14, 15, 5, 2, 8, 12, 3, 7, 0, 4, 10, 1, 13, 11, 6, 4, 3, 2, 12, 9, 5, 15, 10, 11, 14, 1, 7, 6, 0, 8, 13],
    [4, 11, 2, 14, 15, 0, 8, 13, 3, 12, 9, 7, 5, 10, 6, 1, 13, 0, 11, 7, 4, 9, 1, 10, 14, 3, 5, 12, 2, 15, 8, 6, 1, 4, 11, 13, 12, 3, 7, 14, 10, 15, 6, 8, 0, 5, 9, 2, 6, 11, 13, 8, 1, 4, 10, 7, 9, 5, 0, 15, 14, 2, 3, 12],
    [13, 2, 8, 4, 6, 15, 11, 1, 10, 9, 3, 14, 5, 0, 12, 7, 1, 15, 13, 8, 10, 3, 7, 4, 12, 5, 6, 11, 0, 14, 9, 2, 7, 11, 4, 1, 9, 12, 14, 2, 0, 6, 10, 13, 15, 3, 5, 8, 2, 1, 14, 7, 4, 10, 8, 13, 15, 12, 9, 0, 3, 5, 6, 11],
]


def _bits(b):
    return [(x >> i) & 1 for x in b for i in range(7, -1, -1)]


def _unbits(bits):
    return bytes(sum(bits[i + j] << (7 - j) for j in range(8)) for i in range(0, len(bits), 8))


def _subkeys(key):
    k = [_bits(key)[i - 1] for i in _PC1]
    c, d, out = k[:28], k[28:], []
    for s in _SHIFTS:
        c, d = c[s:] + c[:s], d[s:] + d[:s]
        cd = c + d
        out.append([cd[i - 1] for i in _PC2])
    return out


def _des_block(block, sk):
    b = _bits(block)
    b = [b[i - 1] for i in _IP]
    l, r = b[:32], b[32:]
    for k in sk:
        x = [r[i - 1] ^ k[n] for n, i in enumerate(_E)]
        s = []
        for j in range(8):
            v = _SBOX[j][(x[6 * j] << 5) | (x[6 * j + 5] << 4) | (x[6 * j + 1] << 3) | (x[6 * j + 2] << 2) | (x[6 * j + 3] << 1) | x[6 * j + 4]]
            s += ((v >> 3) & 1, (v >> 2) & 1, (v >> 1) & 1, v & 1)
        l, r = r, [a ^ s[i - 1] for a, i in zip(l, _P)]
    rl = r + l
    return _unbits([rl[i - 1] for i in _FP])


def des_ecb(data, key, decrypt=False):
    if len(data) % 8:
        raise ValueError('DES: data must be a multiple of 8 bytes')
    sk = _subkeys(key)
    if decrypt:
        sk.reverse()
    return b''.join(_des_block(data[i:i + 8], sk) for i in range(0, len(data), 8))


def pkcs7_pad(b):
    n = 8 - len(b) % 8
    return bytes(b) + bytes([n]) * n


def pkcs7_unpad(b):
    n = b[-1] if b else 0
    return b[:-n] if 1 <= n <= 8 else b


class RC4:
    def __init__(self, key):
        s = list(range(256))
        j = 0
        for i in range(256):
            j = (j + s[i] + key[i % len(key)]) & 255
            s[i], s[j] = s[j], s[i]
        self.s, self.i, self.j = s, 0, 0

    def update(self, data):
        s, i, j = self.s, self.i, self.j
        out = bytearray(len(data))
        for n, c in enumerate(data):
            i = (i + 1) & 255
            j = (j + s[i]) & 255
            s[i], s[j] = s[j], s[i]
            out[n] = c ^ s[(s[i] + s[j]) & 255]
        self.i, self.j = i, j
        return bytes(out)


def b64e(b):
    return base64.b64encode(bytes(b)).decode('ascii')


def b64d(s):
    return base64.b64decode(s.strip())


def num(v, default=0):
    try:
        return int(float(v))
    except (TypeError, ValueError):
        return default


# ==================================================================================== WTVP security
# Challenge (base64): id[8] + DES-ECB(currentKey, secret), where secret is
#   echo[40] + sessionKey1[16] + sessionKey2[16] + newKey[8] + MD5(those 80 bytes)[16] + pad.
# minisrv's pad works out as 4 zero bytes and only 100 of the 104 encrypted bytes are sent; the box
# accepts exactly that. Response: id[8] + DES-ECB(newKey, MD5(echo) + echo + 0x08 x 8).
# Ticket (base64): signingKey[8] + DES-ECB-PKCS7(initialKey, challenge[108] + JSON(store)).
# SECURE ON: RC4 key n = MD5(sessionKeyN + incarnation (u32 BE) + sessionKeyN); the box encrypts
# requests with key 1, the service encrypts response bodies with key 2.

DEFAULT_INITIAL_KEY = 'bWluaXNydiE='   # minisrv's default, so tickets interoperate


class WTVSec:
    def __init__(self, initial_key_b64=DEFAULT_INITIAL_KEY, incarnation=1):
        self.initial_key = b64d(initial_key_b64)
        if len(self.initial_key) != 8:
            raise ValueError('WTVSec: initial key must be 8 bytes')
        self.current_key = self.initial_key
        self.incarnation = num(incarnation) or 1
        self.challenge_key = None
        self.challenge_signed_key = None
        self.challenge_raw = None
        self.challenge_response = None
        self.session_key1 = self.session_key2 = None
        self.ticket_b64 = None
        self.ticket_store = {}
        self.update_ticket = False
        self.rc4 = []

    def set_incarnation(self, n):
        n = num(n)
        if n and n != self.incarnation:
            self.incarnation = n
            self.secure_on()

    def issue_challenge(self):
        rnd = os.urandom
        cid = rnd(8)
        puzzle = rnd(40) + rnd(16) + rnd(16) + rnd(8)
        secret = puzzle + md5(puzzle) + bytes(8)
        enc = des_ecb(secret, self.current_key)[:100]
        challenge = cid + enc
        self.challenge_signed_key = self.current_key
        self.challenge_response = self.process_challenge(challenge)
        return b64e(challenge)

    def process_challenge(self, challenge, key=None):
        if isinstance(challenge, str):
            challenge = b64d(challenge)
        key = key if key is not None else self.current_key
        if len(challenge) <= 8:
            raise ValueError('WTVSec: challenge too short')
        cid = challenge[:8]
        dec = des_ecb(challenge[8:8 + 96], key, True)
        if dec[80:96] != md5(dec[:80]):
            return None
        self.current_key = dec[72:80]
        self.session_key1 = dec[40:56]
        self.session_key2 = dec[56:72]
        echo = dec[:40]
        resp = des_ecb(md5(echo) + echo + b'\x08' * 8, self.current_key)
        self.challenge_raw = bytes(challenge)
        self.challenge_key = self.current_key
        return cid + resp

    def check_response(self, b64):
        return bool(self.challenge_response and b64 and b64e(self.challenge_response) == b64.strip())

    def prepare_ticket(self):
        js = json.dumps(self.ticket_store, separators=(',', ':')).encode()
        enc = des_ecb(pkcs7_pad(self.challenge_raw + js), self.initial_key)
        self.ticket_b64 = b64e(self.challenge_signed_key + enc)
        self.update_ticket = True
        return self.ticket_b64

    def decode_ticket(self, b64):
        t = b64d(b64)
        key = t[:8]
        dec = pkcs7_unpad(des_ecb(t[8:8 + ((len(t) - 8) & ~7)], self.initial_key, True))
        challenge = dec[:108]
        try:
            self.ticket_store = json.loads(dec[108:].decode('utf-8')) or {}
        except ValueError:
            self.ticket_store = {}
        self.ticket_b64 = b64
        if not self.process_challenge(challenge, key):
            raise ValueError('WTVSec: ticket does not decode with this service key')

    def secure_on(self):
        inc = struct.pack('>I', self.incarnation & 0xFFFFFFFF)
        k1 = md5(self.session_key1 + inc + self.session_key1)
        k2 = md5(self.session_key2 + inc + self.session_key2)
        self.rc4 = [RC4(k1), RC4(k1), RC4(k2), RC4(k2)]

    def encrypt(self, data):
        if not self.rc4:
            self.secure_on()
        return self.rc4[2].update(data)

    def decrypt(self, data):
        if not self.rc4:
            self.secure_on()
        return self.rc4[1].update(data)


# ==================================================================================== PPP server
# The "ISP" end of the dial-up link: async-HDLC framing (RFC 1662), LCP (RFC 1661), optional
# PAP/CHAP (RFC 1334/1994) and IPCP (RFC 1332/1877).

PROTO_IP, PROTO_LCP, PROTO_PAP, PROTO_CHAP, PROTO_IPCP = 0x0021, 0xc021, 0xc023, 0xc223, 0x8021
FLAG, ESC = 0x7e, 0x7d
CONF_REQ, CONF_ACK, CONF_NAK, CONF_REJ, TERM_REQ, TERM_ACK, CODE_REJ, PROTO_REJ, ECHO_REQ, ECHO_REP, DISCARD_REQ = range(1, 12)
PROTO_NAMES = {PROTO_IP: 'IP', PROTO_LCP: 'LCP', PROTO_PAP: 'PAP', PROTO_CHAP: 'CHAP', PROTO_IPCP: 'IPCP',
               0x80fd: 'CCP', 0x8057: 'IPV6CP', 0x002d: 'VJC', 0x002f: 'VJU', 0x8029: 'ATCP'}


def _fcs_table():
    t = []
    for b in range(256):
        v = b
        for _ in range(8):
            v = (v >> 1) ^ 0x8408 if v & 1 else v >> 1
        t.append(v)
    return t


FCS_TAB = _fcs_table()


def fcs16(data, fcs=0xffff):
    for b in data:
        fcs = (fcs >> 8) ^ FCS_TAB[(fcs ^ b) & 0xff]
    return fcs


def ip_str(a):
    return '.'.join(str(x) for x in a[:4])


def parse_opts(data):
    opts, i = [], 0
    while i + 2 <= len(data):
        t, ln = data[i], data[i + 1]
        if ln < 2 or i + ln > len(data):
            return None
        opts.append((t, bytes(data[i + 2:i + ln]), bytes(data[i:i + ln])))
        i += ln
    return opts


def opt(t, b):
    return bytes([t, len(b) + 2]) + bytes(b)


class Obj:
    """Attribute bag (the JS model's object literals)."""
    def __init__(self, **kw):
        self.__dict__.update(kw)


class PppServer:
    def __init__(self, write, on_ip, on_down, local_ip=(10, 0, 0, 1), peer_ip=(10, 0, 0, 2), auth=None):
        self.write, self.on_ip, self.on_down = write, on_ip, on_down
        self.local_ip, self.peer_ip = bytes(local_ip), bytes(peer_ip)
        self.dns = [self.local_ip, self.local_ip]
        self.auth = auth
        self.magic = random.getrandbits(32) or 1
        self.rx = bytearray()
        self.rx_esc = self.rx_drop = False
        self.id = 1
        self.timers = set()
        self.stats = Obj(rx_frames=0, tx_frames=0, bad_fcs=0)
        self.reset()

    def reset(self):
        self.stop()
        self.lcp = Obj(state='starting', our_acked=False, their_acked=False, retries=0, req_id=0, timer=None)
        self.ipcp = Obj(our_acked=False, their_acked=False, retries=0, req_id=0, timer=None, started=False,
                        deferred=None, no_addr=False)
        self.auth_done = not self.auth
        self.ip_up = False
        self.peer_mru = 1500
        self.pending_accm = 0xffffffff
        self.tx_accm = 0xffffffff

    def next_id(self):
        i = self.id & 255
        self.id += 1
        return i

    # ------------------------------------------------------------ framing
    def rx_bytes(self, data):
        for b in data:
            if b == FLAG:
                if self.rx and not self.rx_drop:
                    self.frame(bytes(self.rx))
                self.rx.clear()
                self.rx_esc = self.rx_drop = False
                continue
            if self.rx_drop:
                continue
            if b == ESC:
                self.rx_esc = True
                continue
            if self.rx_esc:
                b ^= 0x20
                self.rx_esc = False
            elif b < 0x20:
                continue                      # flow-control characters the link inserted (RFC 1662 4.2)
            if len(self.rx) >= 4096:
                self.rx_drop = True
                continue
            self.rx.append(b)

    def frame(self, f):
        if len(f) < 4:
            return
        if fcs16(f) != 0xf0b8:
            self.stats.bad_fcs += 1
            vlog(f'[ppp] bad FCS (len {len(f)})')
            return
        self.stats.rx_frames += 1
        p = 2 if f[0] == 0xff and f[1] == 0x03 else 0
        proto = f[p]
        p += 1
        if not proto & 1:
            proto = (proto << 8) | f[p]
            p += 1
        try:
            self.packet(proto, f[p:-2])
        except Exception:                     # noqa: BLE001 -- one bad packet must not drop the call
            log('[error] ' + traceback.format_exc().rstrip().replace('\n', '\n    '))

    def send(self, proto, data):
        hdr = bytes([0xff, 0x03, proto >> 8, proto & 0xff])
        accm = 0xffffffff if proto == PROTO_LCP else self.tx_accm   # LCP always with the default ACCM
        out = bytearray([FLAG])
        fcs = 0xffff
        for b in hdr + bytes(data):
            fcs = (fcs >> 8) ^ FCS_TAB[(fcs ^ b) & 0xff]
            if b == FLAG or b == ESC or (b < 0x20 and (accm >> b) & 1):
                out += bytes([ESC, b ^ 0x20])
            else:
                out.append(b)
        fcs ^= 0xffff
        for b in (fcs & 0xff, fcs >> 8):
            if b == FLAG or b == ESC or (b < 0x20 and (accm >> b) & 1):
                out += bytes([ESC, b ^ 0x20])
            else:
                out.append(b)
        out.append(FLAG)
        self.stats.tx_frames += 1
        self.write(bytes(out))

    def send_ctl(self, proto, code, cid, body=b''):
        self.send(proto, struct.pack('>BBH', code, cid, len(body) + 4) + bytes(body))

    def send_ip(self, pkt):
        if self.ip_up:
            self.send(PROTO_IP, pkt)

    def timer(self, sec, fn):
        def fire():
            self.timers.discard(t)
            fn()
        t = LOOP.call_later(sec, fire)
        self.timers.add(t)
        return t

    def stop(self):
        for t in self.timers:
            t.cancel()
        self.timers.clear()

    # ------------------------------------------------------------ dispatch
    def packet(self, proto, data):
        if proto == PROTO_IP:
            if self.ip_up:
                self.on_ip(data)
            return
        if len(data) < 4:
            return
        code, cid = data[0], data[1]
        ln = min((data[2] << 8) | data[3], len(data))
        body = data[4:ln]
        if proto == PROTO_LCP:
            return self.lcp_packet(code, cid, body, data)
        if proto == PROTO_PAP:
            return self.pap_packet(code, cid, body)
        if proto == PROTO_CHAP:
            return self.chap_packet(code, cid, body)
        if proto == PROTO_IPCP:
            if self.lcp.state == 'opened':
                self.ipcp_packet(code, cid, body)
            return
        vlog(f'[ppp] rejecting protocol {PROTO_NAMES.get(proto, f"0x{proto:04x}")}')
        if self.lcp.state == 'opened':
            self.send_ctl(PROTO_LCP, PROTO_REJ, self.next_id(), struct.pack('>H', proto) + data)

    # ------------------------------------------------------------ LCP
    def lcp_request(self):
        L = self.lcp
        if L.our_acked or L.state == 'closed':
            return
        L.retries += 1
        if L.retries > 10:
            return self.down('LCP negotiation timed out')
        L.req_id = self.next_id()
        opts = opt(5, struct.pack('>I', self.magic))
        if self.auth == 'pap':
            opts += opt(3, [0xc0, 0x23])
        if self.auth == 'chap':
            opts += opt(3, [0xc2, 0x23, 5])
        self.send_ctl(PROTO_LCP, CONF_REQ, L.req_id, opts)
        if L.timer:
            L.timer.cancel()
        L.timer = self.timer(3.0, self.lcp_request)

    def start(self):
        vlog('[ppp] link up, starting LCP')
        self.lcp.state = 'reqsent'
        self.lcp_request()

    def lcp_packet(self, code, cid, body, raw):
        L = self.lcp
        if code == CONF_REQ:
            if L.state == 'opened':
                vlog('[ppp] LCP renegotiation')
                self.reset()
                L = self.lcp
                L.state = 'reqsent'
                self.lcp_request()
            opts = parse_opts(body)
            if opts is None:
                return
            rej, desc = [], []
            accm, mru = 0xffffffff, 1500
            for t, d, rw in opts:
                if t == 1:
                    mru = (d[0] << 8) | d[1]
                    desc.append(f'mru={mru}')
                elif t == 2:
                    accm = struct.unpack('>I', d)[0]
                    desc.append(f'accm={accm:08x}')
                elif t == 3:                  # the box wants us to authenticate: we can't, so reject
                    desc.append(f'auth={(d[0] << 8) | d[1]:04x}')
                    rej.append(rw)
                elif t == 5:
                    desc.append(f'magic={struct.unpack(">I", d)[0]:08x}')
                elif t == 7:
                    desc.append('pfc')
                elif t == 8:
                    desc.append('acfc')
                else:
                    desc.append(f'?{t}')
                    rej.append(rw)
            vlog(f'[ppp] LCP ConfReq from box: {" ".join(desc)}{" (rejecting some)" if rej else ""}')
            if rej:
                return self.send_ctl(PROTO_LCP, CONF_REJ, cid, b''.join(rej))
            self.send_ctl(PROTO_LCP, CONF_ACK, cid, body)
            L.their_acked = True
            self.peer_mru = mru
            self.pending_accm = accm
            if L.state == 'starting':
                L.state = 'reqsent'
                self.lcp_request()
            self.lcp_check_open()
        elif code == CONF_ACK:
            if cid != L.req_id:
                return
            L.our_acked = True
            self.lcp_check_open()
        elif code in (CONF_NAK, CONF_REJ):
            if cid != L.req_id:
                return
            opts = parse_opts(body) or []
            vlog(f'[ppp] LCP {"Nak" if code == CONF_NAK else "Rej"} of our options {",".join(str(o[0]) for o in opts)}')
            a = [o for o in opts if o[0] == 3]
            if a:
                if code == CONF_NAK and a[0][1][:1] == b'\xc0':
                    self.auth = 'pap'
                else:
                    vlog('[ppp] box refused authentication, continuing without')
                    self.auth, self.auth_done = None, True
            if code == CONF_REJ and any(o[0] == 5 for o in opts):
                self.magic = 0
            L.retries = 0
            self.lcp_request()
        elif code == TERM_REQ:
            vlog('[ppp] LCP Terminate-Request from box')
            self.send_ctl(PROTO_LCP, TERM_ACK, cid)
            self.down('terminated by box')
        elif code == ECHO_REQ:
            if L.state == 'opened':
                self.send_ctl(PROTO_LCP, ECHO_REP, cid, struct.pack('>I', self.magic) + body[4:])
        elif code in (TERM_ACK, ECHO_REP, DISCARD_REQ):
            pass
        elif code == CODE_REJ:
            vlog('[ppp] LCP Code-Reject from box')
        elif code == PROTO_REJ:
            vlog(f'[ppp] box rejected protocol 0x{(body[0] << 8) | body[1]:04x}')
        else:
            self.send_ctl(PROTO_LCP, CODE_REJ, self.next_id(), raw)

    def lcp_check_open(self):
        L = self.lcp
        if L.state == 'opened' or not L.our_acked or not L.their_acked:
            return
        L.state = 'opened'
        self.tx_accm = self.pending_accm
        vlog(f'[ppp] LCP opened (box mru={self.peer_mru} accm={self.tx_accm:08x})')
        if self.auth == 'chap':
            self.chap_challenge()
        if self.auth_done:
            self.ipcp_start()

    # ------------------------------------------------------------ PAP / CHAP
    def pap_packet(self, code, cid, body):
        if code != 1:
            return
        ul = body[0]
        user = body[1:1 + ul].decode('latin-1')
        vlog(f'[ppp] PAP login: user "{user}"')
        self.send_ctl(PROTO_PAP, 2, cid, bytes([7]) + b'Welcome')
        if not self.auth_done:
            self.auth_done = True
            self.ipcp_start()

    def chap_challenge(self):
        self.chap_id = self.next_id()
        self.send_ctl(PROTO_CHAP, 1, self.chap_id, bytes([16]) + os.urandom(16) + b'webtv-emu')

    def chap_packet(self, code, cid, body):
        if code != 2:
            return
        vl = body[0]
        vlog(f'[ppp] CHAP response: user "{body[1 + vl:].decode("latin-1")}" (accepted)')
        self.send_ctl(PROTO_CHAP, 3, cid, b'Welcome')
        if not self.auth_done:
            self.auth_done = True
            self.ipcp_start()

    # ------------------------------------------------------------ IPCP
    def ipcp_start(self):
        I = self.ipcp
        if I.started:
            return
        I.started = True
        self.ipcp_request()
        if I.deferred:
            d, I.deferred = I.deferred, None
            self.ipcp_packet(*d)

    def ipcp_request(self):
        I = self.ipcp
        if I.our_acked or self.lcp.state != 'opened':
            return
        I.retries += 1
        if I.retries > 10:
            return self.down('IPCP negotiation timed out')
        I.req_id = self.next_id()
        self.send_ctl(PROTO_IPCP, CONF_REQ, I.req_id, b'' if I.no_addr else opt(3, self.local_ip))
        if I.timer:
            I.timer.cancel()
        I.timer = self.timer(3.0, self.ipcp_request)

    def ipcp_packet(self, code, cid, body):
        I = self.ipcp
        if not self.auth_done:
            if code == CONF_REQ:
                I.deferred = (code, cid, body)
            return
        if code == CONF_REQ:
            opts = parse_opts(body)
            if opts is None:
                return
            rej, nak, desc = [], [], []
            for t, d, rw in opts:
                want = {3: self.peer_ip, 129: self.dns[0], 131: self.dns[1]}.get(t)
                if want and len(d) == 4:
                    desc.append(f'{t}={ip_str(d)}')
                    if d != want:
                        nak.append(opt(t, want))
                else:
                    desc.append(f'?{t}')
                    rej.append(rw)
            vlog(f'[ppp] IPCP ConfReq from box: {" ".join(desc)}')
            if rej:
                return self.send_ctl(PROTO_IPCP, CONF_REJ, cid, b''.join(rej))
            if nak:
                return self.send_ctl(PROTO_IPCP, CONF_NAK, cid, b''.join(nak))
            self.send_ctl(PROTO_IPCP, CONF_ACK, cid, body)
            I.their_acked = True
            self.ipcp_check_open()
        elif code == CONF_ACK:
            if cid == I.req_id:
                I.our_acked = True
                self.ipcp_check_open()
        elif code in (CONF_NAK, CONF_REJ):
            if cid == I.req_id:
                opts = parse_opts(body) or []
                if code == CONF_REJ and any(o[0] == 3 for o in opts):
                    I.no_addr = True
                I.retries = 0
                self.ipcp_request()
        elif code == TERM_REQ:
            self.send_ctl(PROTO_IPCP, TERM_ACK, cid)
            self.ip_up = False
            I.our_acked = I.their_acked = False
        elif code == TERM_ACK:
            pass
        else:
            self.send_ctl(PROTO_IPCP, CODE_REJ, self.next_id(), struct.pack('>BBH', code, cid, len(body) + 4) + body)

    def ipcp_check_open(self):
        I = self.ipcp
        if self.ip_up or not I.our_acked or not I.their_acked:
            return
        self.ip_up = True
        log(f'[ppp] up: box {ip_str(self.peer_ip)}, gateway {ip_str(self.local_ip)}')

    # ------------------------------------------------------------ teardown
    def down(self, why):
        if self.lcp.state == 'closed':
            return
        log(f'[ppp] down: {why}')
        self.stop()
        self.reset()
        self.lcp.state = 'closed'
        if self.on_down:
            self.on_down(why)


# ==================================================================================== IPv4 gateway
# Answers ICMP echo and DNS (UDP/53) itself and terminates every TCP connection the box opens,
# splicing its byte stream onto a transport stream: the service, or a real socket.

P_ICMP, P_TCP, P_UDP = 1, 6, 17
FIN, SYN, RST, PSH, ACK = 1, 2, 4, 8, 16
MAX_RTX = 6            # retransmits in a row with no progress before a connection is reset


def checksum(buf, init=0):
    if len(buf) & 1:
        buf = bytes(buf) + b'\0'
    s = init + sum(struct.unpack('!%dH' % (len(buf) // 2), buf))
    while s > 0xffff:
        s = (s & 0xffff) + (s >> 16)
    return s


def pseudo_sum(src, dst, proto, ln):
    return checksum(bytes(src) + bytes(dst) + bytes([0, proto, ln >> 8, ln & 255]))


def seq_lt(a, b):
    return ((a - b) & 0xffffffff) > 0x7fffffff


def seq_le(a, b):
    return a == b or seq_lt(a, b)


class IpGateway:
    def __init__(self, send, transport, backlog, gateway=(10, 0, 0, 1)):
        self.send = send
        self.transport = transport
        self.backlog = backlog
        self.gw = bytes(gateway)
        self.ip_id = 1
        self.tcp = {}

    def input(self, p):
        if len(p) < 20 or (p[0] >> 4) != 4:
            return
        ihl, total = (p[0] & 15) * 4, (p[2] << 8) | p[3]
        if total > len(p) or total < ihl or checksum(p[:ihl]) != 0xffff:
            vlog('[ip] bad header')
            return
        if ((p[6] << 8) | p[7]) & 0x3fff:
            vlog('[ip] fragment dropped')
            return
        src, dst, proto, data = p[12:16], p[16:20], p[9], p[ihl:total]
        if proto == P_ICMP:
            self.icmp(src, dst, data)
        elif proto == P_UDP:
            self.udp(src, dst, data)
        elif proto == P_TCP:
            self.tcp_input(src, dst, data)
        else:
            vlog(f'[ip] {ip_str(src)} -> {ip_str(dst)} proto {proto} ignored')

    def output(self, src, dst, proto, payload):
        h = bytearray(struct.pack('>BBHHHBBH4s4s', 0x45, 0, 20 + len(payload), self.ip_id & 0xffff, 0x4000, 64, proto, 0,
                                  bytes(src), bytes(dst)))
        self.ip_id += 1
        struct.pack_into('>H', h, 10, ~checksum(h) & 0xffff)
        self.send(bytes(h) + bytes(payload))

    def icmp(self, src, dst, d):
        if len(d) < 8 or checksum(d) != 0xffff or d[0] != 8:
            return
        r = bytearray(d)
        r[0] = 0
        r[2] = r[3] = 0
        struct.pack_into('>H', r, 2, ~checksum(r) & 0xffff)
        self.output(dst, src, P_ICMP, r)

    def udp(self, src, dst, d):
        if len(d) < 8:
            return
        sport, dport, ln = struct.unpack('>HHH', d[:6])
        if dport == 53:
            return self.dns(src, dst, sport, d[8:ln])
        vlog(f'[udp] {ip_str(src)}:{sport} -> {ip_str(dst)}:{dport} dropped')

    def udp_output(self, src, dst, sport, dport, payload):
        u = bytearray(struct.pack('>HHHH', sport, dport, 8 + len(payload), 0) + bytes(payload))
        c = ~checksum(u, pseudo_sum(src, dst, P_UDP, len(u))) & 0xffff
        struct.pack_into('>H', u, 6, c or 0xffff)
        self.output(src, dst, P_UDP, u)

    def dns(self, src, dst, sport, q):
        if len(q) < 12:
            return
        qd = (q[4] << 8) | q[5]
        i, labels = 12, []
        while i < len(q) and q[i]:
            labels.append(q[i + 1:i + 1 + q[i]].decode('latin-1'))
            i += q[i] + 1
        name = '.'.join(labels)
        qtype = (q[i + 1] << 8) | q[i + 2] if i + 2 < len(q) else 0
        qend = i + 5

        def answer(ip, rcode):
            vlog(f'[dns] {name} type {qtype} -> {ip or ("NXDOMAIN" if rcode == 3 else "NOTIMP" if rcode else "no data")}')
            ans = bytes([0xc0, 12, 0, 1, 0, 1, 0, 0, 0, 60, 0, 4]) + bytes(int(x) for x in ip.split('.')) if ip else b''
            r = bytearray(q[:qend])
            r += bytes(max(0, qend - len(r)))
            r[2] = 0x80 | (q[2] & 0x79)
            r[3] = 0x80 | rcode
            struct.pack_into('>HHHH', r, 4, 0 if rcode == 4 else 1, 1 if ip else 0, 0, 0)
            r += ans
            self.udp_output(dst, src, 53, sport, r[:12] if rcode == 4 else r)

        if qd != 1 or (q[2] & 0x78):
            return answer(None, 4)
        if qtype not in (1, 255):
            return answer(None, 0)
        if re.fullmatch(r'\d+\.\d+\.\d+\.\d+', name):
            return answer(name, 0)
        if not self.transport.resolve:
            return answer(None, 3)
        self.transport.resolve(name, lambda ip: answer(ip, 0 if ip else 3))

    # ------------------------------------------------------------ TCP
    def tcp_input(self, src, dst, d):
        if len(d) < 20:
            return
        if ~checksum(d, pseudo_sum(src, dst, P_TCP, len(d))) & 0xffff:
            vlog('[tcp] bad checksum')
            return
        off = (d[12] >> 4) * 4
        sport, dport, sq, ak = struct.unpack('>HHII', d[:12])
        seg = Obj(sport=sport, dport=dport, seq=sq, ack=ak, flags=d[13] & 0x3f, win=(d[14] << 8) | d[15],
                  data=bytes(d[off:]), opts=bytes(d[20:off]))
        key = f'{ip_str(src)}:{sport}>{ip_str(dst)}:{dport}'
        c = self.tcp.get(key)
        if c and (seg.flags & (SYN | ACK)) == SYN and ((seg.seq + 1) & 0xffffffff) != c.rcv_nxt:
            c.finish()                        # the box reused the port (it dropped the old connection silently)
            c = None
        if not c:
            if seg.flags & RST:
                return
            if (seg.flags & (SYN | ACK)) != SYN:
                return self.rst_for(src, dst, seg)
            c = TcpConn(self, key, bytes(src), bytes(dst), seg)
            if c.state != 'closed':
                self.tcp[key] = c
            c.start()
            return
        c.input(seg)

    def rst_for(self, src, dst, seg):
        ln = len(seg.data) + (1 if seg.flags & SYN else 0) + (1 if seg.flags & FIN else 0)
        if seg.flags & ACK:
            self.tcp_output(dst, src, seg.dport, seg.sport, seg.ack, 0, RST, 0)
        else:
            self.tcp_output(dst, src, seg.dport, seg.sport, 0, (seg.seq + ln) & 0xffffffff, RST | ACK, 0)

    def tcp_output(self, src, dst, sport, dport, sq, ak, flags, win, data=b'', mss=0):
        o = struct.pack('>BBH', 2, 4, mss) if mss else b''
        t = bytearray(struct.pack('>HHIIBBHHH', sport, dport, sq, ak, ((20 + len(o)) // 4) << 4, flags, win, 0, 0) + o + bytes(data))
        struct.pack_into('>H', t, 16, ~checksum(t, pseudo_sum(src, dst, P_TCP, len(t))) & 0xffff)
        self.output(src, dst, P_TCP, t)


class TcpConn:
    """One TCP connection from the box, terminated here and spliced to a transport stream."""
    def __init__(self, gw, key, src, dst, syn):
        self.gw, self.key, self.src, self.dst = gw, key, src, dst
        self.sport, self.dport = syn.sport, syn.dport
        self.rcv_nxt = (syn.seq + 1) & 0xffffffff
        self.iss = random.getrandbits(32)
        self.snd_una = self.snd_nxt = self.iss
        self.snd_wnd = syn.win
        self.mss = 536
        o, i = syn.opts, 0
        while i < len(o):
            k = o[i]
            if k == 0:
                break
            if k == 1:
                i += 1
                continue
            if k == 2 and i + 3 < len(o):
                self.mss = (o[i + 2] << 8) | o[i + 3]
            i += (o[i + 1] if i + 1 < len(o) else 0) or 1
        self.mss = max(64, min(self.mss, 1460))
        self.send_buf = bytearray()           # unacked + unsent bytes, starting at snd_una (after SYN)
        self.state = 'syn-rcvd-pending'
        self.remote_eof = self.fin_sent = self.fin_acked = self.box_fin = False
        self.rto_timer = None
        self.rto_s = 3.0
        self.dup_acks = 0
        self.rtx = 0
        self.box_bytes = self.tx_bytes = 0
        self.conn = None
        self.name = f'{ip_str(dst)}:{syn.dport}'

    def start(self):
        vlog(f'[tcp] box :{self.sport} connecting to {self.name} (mss {self.mss}, win {self.snd_wnd})')
        self.conn = self.gw.transport.open_tcp(ip_str(self.dst), self.dport, self)

    def out(self, flags, data=b'', sq=None, mss=0):
        self.gw.tcp_output(self.dst, self.src, self.dport, self.sport, self.snd_nxt if sq is None else sq,
                           self.rcv_nxt, flags, 16384, data, mss)

    # ---- transport handlers
    def on_open(self):
        if self.state != 'syn-rcvd-pending':
            return
        self.state = 'syn-rcvd'
        self.send_syn()

    def on_data(self, d):
        if self.state == 'closed':
            return
        self.send_buf += d
        self.pump()

    def on_end(self):
        self.remote_eof = True
        self.pump()

    def on_close(self, err=None):
        if self.state == 'closed':
            return
        if self.state == 'syn-rcvd-pending':
            log(f'[tcp] {self.name} connect failed: {err or "closed"}')
            return self.reset()
        if err:
            log(f'[tcp] {self.name} remote error: {err}')
            return self.reset()
        self.remote_eof = True
        self.pump()

    # ---- sending
    def send_syn(self):
        self.out(SYN | ACK, b'', self.iss, 1460)
        self.snd_nxt = (self.iss + 1) & 0xffffffff
        self.arm_rto()

    @property
    def in_flight(self):
        return (self.snd_nxt - self.snd_una) & 0xffffffff

    def pump(self):
        if self.state not in ('established', 'close-wait'):
            return
        while True:
            off = self.in_flight
            avail = len(self.send_buf) - off
            wnd = self.snd_wnd - off
            if avail <= 0 or wnd <= 0:
                break
            n = min(avail, wnd, self.mss)
            self.out(ACK | PSH, self.send_buf[off:off + n])
            self.snd_nxt = (self.snd_nxt + n) & 0xffffffff
            self.tx_bytes += n
        if self.remote_eof and not self.fin_sent and self.in_flight == len(self.send_buf):
            self.out(FIN | ACK)
            self.snd_nxt = (self.snd_nxt + 1) & 0xffffffff
            self.fin_sent = True
        if self.in_flight or (self.send_buf and self.snd_wnd == 0):
            self.arm_rto()

    def arm_rto(self):
        if not self.rto_timer:
            self.rto_timer = LOOP.call_later(self.rto_s, self.rto)

    def clear_rto(self):
        if self.rto_timer:
            self.rto_timer.cancel()
            self.rto_timer = None

    def rto(self):
        self.rto_timer = None
        if self.state == 'closed':
            return
        if self.gw.backlog() > 0:             # don't count time the data spends queued on the slow serial link
            return self.arm_rto()
        if self.state == 'syn-rcvd':
            vlog(f'[tcp] {self.name} resending SYN-ACK')
            return self.send_syn()
        if self.in_flight == 0 and self.snd_wnd == 0 and self.send_buf:
            self.out(ACK, self.send_buf[:1], self.snd_una)       # zero-window probe
            return self.arm_rto()
        if self.in_flight == 0:
            return
        # The box drops a connection it no longer wants without a reset ("tcpHandler : Discarding
        # packet, no matching port"); retransmitting to it forever starves the live connections.
        self.rtx += 1
        if self.rtx > MAX_RTX:
            log(f'[tcp] {self.name}: no answer after {MAX_RTX} retransmits, resetting')
            return self.reset()
        vlog(f'[tcp] {self.name} retransmit from {self.in_flight} bytes in flight')
        if self.fin_sent and not self.fin_acked:
            self.fin_sent = False
        self.snd_nxt = self.snd_una                               # go-back-N
        self.rto_s = min(self.rto_s * 2, 30.0)
        self.pump()

    # ---- receiving
    def input(self, seg):
        if seg.flags & RST:
            vlog(f'[tcp] {self.name} reset by box')
            return self.finish()
        if seg.flags & SYN:
            if self.state == 'syn-rcvd':
                self.send_syn()
            return
        if self.state == 'syn-rcvd-pending':
            return
        if seg.flags & ACK:
            if seq_lt(self.snd_una, seg.ack) and seq_le(seg.ack, self.snd_nxt):
                acked = (seg.ack - self.snd_una) & 0xffffffff
                if self.state == 'syn-rcvd':
                    acked -= 1
                    self.state = 'established'
                if self.fin_sent and seg.ack == self.snd_nxt:
                    self.fin_acked = True
                    acked = max(0, acked - 1)
                del self.send_buf[:acked]
                self.snd_una = seg.ack
                self.clear_rto()
                self.rto_s = 3.0
                self.dup_acks = 0
                self.rtx = 0
            elif seg.ack == self.snd_una and not seg.data and self.in_flight and seg.win == self.snd_wnd:
                self.dup_acks += 1
                if self.dup_acks == 3:          # fast retransmit: the box is missing the segment at snd_una
                    if self.fin_sent and not self.fin_acked:
                        self.fin_sent = False
                    self.snd_nxt = self.snd_una
            self.snd_wnd = seg.win
        need_ack = False
        if seg.data:
            end = (seg.seq + len(seg.data)) & 0xffffffff
            if seg.seq == self.rcv_nxt:
                if not self.box_fin:
                    self.rcv_nxt = end
                    self.to_remote(seg.data)
            elif seq_lt(seg.seq, self.rcv_nxt) and seq_lt(self.rcv_nxt, end):
                rest = seg.data[(self.rcv_nxt - seg.seq) & 0xffffffff:]
                self.rcv_nxt = (self.rcv_nxt + len(rest)) & 0xffffffff
                self.to_remote(rest)
            need_ack = True
        if seg.flags & FIN and ((seg.seq + len(seg.data)) & 0xffffffff) == self.rcv_nxt and not self.box_fin:
            self.box_fin = True
            self.rcv_nxt = (self.rcv_nxt + 1) & 0xffffffff
            if self.state == 'established':
                self.state = 'close-wait'
            if self.conn:
                self.conn.end()
            need_ack = True
        elif seg.flags & FIN:
            need_ack = True
        if need_ack:
            self.out(ACK)
        if self.box_fin and self.fin_acked:
            return self.finish()
        self.pump()

    def to_remote(self, d):
        self.box_bytes += len(d)
        if self.conn:
            self.conn.send(bytes(d))

    def reset(self):
        if self.state == 'closed':
            return
        self.out(RST | ACK)
        self.finish()

    def finish(self):
        if self.state == 'closed':
            return
        self.state = 'closed'
        self.clear_rto()
        if self.conn:
            self.conn.close()
        self.gw.tcp.pop(self.key, None)
        vlog(f'[tcp] {self.name} closed (box sent {self.box_bytes}, received {self.tx_bytes} bytes)')


# ==================================================================================== transports
# open_tcp(host, port, h) -> conn with send(bytes), end(), close(); h gets on_open, on_data, on_end,
# on_close(err). Boxes start out talking to WebTV's own addresses (NVRAM and ROM defaults such as
# 207.79.34.4:1601 and 10.0.128.1:1615), so every connection to a WTVP port goes to the service.

class ServiceConn:
    def __init__(self, service, port, h):
        self.h, self.closed = h, False
        self.wtvp = WtvpConnection(service, self, port)
        LOOP.call_soon(lambda: None if self.closed else h.on_open())

    # the service side
    def deliver(self, data):
        if not self.closed:
            self.h.on_data(data)

    def hang_up(self):
        if not self.closed:
            self.closed = True
            self.wtvp.closed = True
            self.h.on_end()
            LOOP.call_soon(lambda: self.h.on_close(None))

    # the TCP side
    def send(self, d):
        if not self.closed:
            self.wtvp.receive(d)

    def end(self):
        if not self.closed:
            self.closed = self.wtvp.closed = True
            LOOP.call_soon(lambda: self.h.on_close(None))

    def close(self):
        self.closed = self.wtvp.closed = True


class InternetConn:
    """A real TCP connection for the box (anything that isn't the service)."""
    def __init__(self, host, port, h):
        self.h, self.sock, self.closed = h, None, False
        threading.Thread(target=self.run, args=(host, port), daemon=True).start()

    def run(self, host, port):
        try:
            s = socket.create_connection((host, port), timeout=15)
            s.settimeout(None)
        except OSError as e:
            LOOP.call_soon(lambda: self.h.on_close(str(e)))
            return
        if self.closed:
            s.close()
            return
        self.sock = s
        LOOP.call_soon(self.h.on_open)
        try:
            while True:
                d = s.recv(8192)
                if not d:
                    break
                LOOP.call_soon(lambda d=d: self.h.on_data(d))
            LOOP.call_soon(self.h.on_end)
            LOOP.call_soon(lambda: self.h.on_close(None))
        except OSError as e:
            if not self.closed:
                LOOP.call_soon(lambda: self.h.on_close(str(e)))

    def send(self, d):
        try:
            if self.sock:
                self.sock.sendall(d)
        except OSError:
            pass

    def end(self):
        try:
            if self.sock:
                self.sock.shutdown(socket.SHUT_WR)
        except OSError:
            pass

    def close(self):
        self.closed = True
        try:
            if self.sock:
                self.sock.close()
        except OSError:
            pass


class Transport:
    SERVICE_IP = '10.0.0.1'

    def __init__(self, service, internet=True):
        self.service, self.internet = service, internet
        self.resolve = self._resolve if internet else None

    def open_tcp(self, host, port, h):
        if host == self.SERVICE_IP or 1600 <= port <= 1699:
            return ServiceConn(self.service, port, h)
        if not self.internet:
            LOOP.call_soon(lambda: h.on_close('no route (offline)'))
            return Obj(send=lambda d: None, end=lambda: None, close=lambda: None)
        log(f'[tcp] box connecting to {host}:{port} directly')
        return InternetConn(host, port, h)

    @staticmethod
    def _resolve(name, cb):
        def work():
            return socket.gethostbyname(name)
        LOOP.thread(work, lambda ip, err: cb(None if err else ip))


# ==================================================================================== the line

class Line:
    """One call: PPP server + IP gateway + transports. write(bytes) goes towards the box."""
    def __init__(self, write, on_close, backlog, ready):
        self.write, self.on_close, self.ready = write, on_close, ready
        self.transport = Transport(SERVICE, internet=WEB.enabled)
        self.gw = IpGateway(lambda p: self.ppp.send_ip(p), self.transport, backlog)
        self.ppp = PppServer(write, self.gw.input, self._down)
        self.closed = False
        for s in SERVICE.sessions.values():
            # a new call is a new login: forget the last call's key exchange, so a box that comes back
            # straight to wtv-head-waiter:/login (without preregister, e.g. after losing its secret) is
            # sent through preregister instead of a challenge it can't answer (Network::ProcessChallenge)
            s.login = None
        LOOP.call_later(0.5, self._kick)

    def _kick(self):
        # like a real ISP, start LCP shortly after CONNECT
        if self.closed or self.ppp.lcp.state != 'starting':
            return
        if self.ready():
            self.ppp.start()
        else:
            LOOP.call_later(0.25, self._kick)

    def _down(self, why):
        for c in list(self.gw.tcp.values()):
            c.finish()
        if not self.closed:
            self.closed = True
            self.on_close(why)

    def sendall(self, data):                  # from the box
        if not self.closed:
            self.ppp.rx_bytes(data)

    def close(self):
        if self.closed:
            return
        self.closed = True
        self.ppp.on_down = None
        self.ppp.stop()
        if self.ppp.lcp.state != 'closed':
            self.ppp.down('hangup')
        for c in list(self.gw.tcp.values()):
            c.finish()


# ==================================================================================== WTVP
# One WTVP connection between the box and the service: request parsing (including "SECURE ON" and
# RC4-encrypted requests) and response framing, as zefie's minisrv does it.
#   - A request is an HTTP-like header block ("GET url" / "POST url" + "Name: value" lines, ended by
#     a blank line; \r\n, \n\r\n and \n\n all occur), then Content-length bytes of body.
#   - A "SECURE ON" block (in clear, carrying wtv-ticket and wtv-incarnation) switches the connection
#     to RC4: everything the box sends after it is encrypted with session key 1, and response bodies
#     are encrypted with session key 2 ("wtv-encrypted: true").
#   - Responses: status line, then headers with Connection second and Content-type last, "\n" line
#     endings, a blank line, the body.

def parse_header_block(text):
    h = Obj(headers={}, secure=False, method=None, url=None)
    for raw in text.split('\n'):
        line = raw[:-1] if raw.endswith('\r') else raw
        if not line:
            continue
        if line.startswith('SECURE ON'):
            h.secure = True
            continue
        m = re.match(r'^(GET|PUT|POST) (.*?)(?: HTTP/[\d.]+)?$', line)
        if m and not h.method:
            h.method, h.url = m.group(1), m.group(2)
            continue
        i = line.find(':')
        if i > 0:
            k, v = line[:i].lower(), line[i + 1:]
            v = v[1:] if v.startswith(' ') else v
            if k in h.headers:
                old = h.headers[k]
                h.headers[k] = (old if isinstance(old, list) else [old]) + [v]
            else:
                h.headers[k] = v
    return h


def header_end(buf):
    a, b = buf.find(b'\n\n'), buf.find(b'\n\r\n')
    if a < 0 and b < 0:
        return None
    if b < 0 or (0 <= a < b):
        return a, a + 2
    return b, b + 3


def hval(h, k):
    v = h.get(k)
    return v[-1] if isinstance(v, list) else v


class WtvpConnection:
    def __init__(self, service, io, port):
        self.service, self.io, self.port = service, io, port
        self.sec = None
        self.plain = b''
        self.outer = None
        self.pending = collections.deque()
        self.busy = False
        self.closed = False
        self.ssid = None
        self.session = None

    def receive(self, data):
        if self.sec:
            if not self.plain and data[:9] == b'SECURE ON':
                self.sec = None               # a fresh SECURE ON block at a request boundary arrives in clear
            else:
                data = self.sec.decrypt(data)
        self.plain += data
        self.pump()

    def pump(self):
        while True:
            end = header_end(self.plain)
            if not end:
                return
            block = parse_header_block(self.plain[:end[0]].decode('latin-1'))
            if block.secure and not block.method:
                rest = self.plain[end[1]:]        # switch to RC4; what follows the block is already encrypted
                self.outer = block.headers
                self.sec = self.service.connection_security(block.headers)
                self.plain = self.sec.decrypt(rest) if rest else b''
                continue
            ln = num(hval(block.headers, 'content-length'))
            if len(self.plain) < end[1] + ln:
                return
            body = self.plain[end[1]:end[1] + ln]
            self.plain = self.plain[end[1] + ln:]
            headers = dict(self.outer or {})
            headers.update(block.headers)
            self.outer = None
            req = Obj(method=block.method or 'GET', url=block.url or '', headers=headers, body=body,
                      secure=bool(self.sec), port=self.port)
            if headers.get('wtv-incarnation') and self.sec:
                self.sec.set_incarnation(hval(headers, 'wtv-incarnation'))
            self.pending.append(req)
            self.next()

    def next(self):
        if self.busy or not self.pending:
            return
        self.busy = True
        req = self.pending.popleft()

        def done(res):
            self.busy = False
            if not self.closed:
                self.send(res)
            self.next()
        try:
            self.service.handle(req, self, done)
        except Exception:                     # noqa: BLE001
            log(f'[wtvsrv] {req.url}: ' + traceback.format_exc().rstrip())
            done(('500 The service had a problem with this page\nContent-Type: text/html', b''))

    def send(self, res):
        head, body = res
        data = body.encode('latin-1', 'replace') if isinstance(body, str) else bytes(body)
        lines = [ln.rstrip('\r') for ln in head.split('\n')]
        lines = [ln for ln in lines if ln]
        status = lines.pop(0)
        fields = []
        for ln in lines:
            i = ln.find(':')
            v = ln[i + 1:]
            fields.append([ln[:i], v[1:] if v.startswith(' ') else v])

        def get(k):
            return next((f for f in fields if f[0].lower() == k.lower()), None)

        def drop(k):
            fields[:] = [f for f in fields if f[0].lower() != k.lower()]
        close = False
        if get('wtv-connection-close'):
            close = True
            drop('wtv-connection-close')
        if not get('Connection'):
            fields.insert(0, ['Connection', 'Keep-Alive'])
        elif get('Connection')[1].lower() == 'close':
            close = True
        ctype = get('Content-Type')
        drop('Content-Type')
        drop('Content-length')
        extra = self.service.extra_headers(self)
        if self.sec:
            drop('wtv-encrypted')
            extra.insert(0, ['wtv-encrypted', 'true'])
            if data:
                data = self.sec.encrypt(data)
        conn = get('Connection')
        drop('Connection')
        fields = [conn] + extra + fields + [['Content-length', str(len(data))]]
        if ctype:
            fields.append(['Content-type', ctype[1].split(';')[0]])
        text = status + '\n' + '\n'.join(f'{k}: {v}' for k, v in fields) + '\n\n'
        self.io.deliver(text.encode('latin-1', 'replace') + data)
        if close:
            self.closed = True
            self.io.hang_up()


# ==================================================================================== pages
# In the WebTV client's HTML dialect. Images and sounds come from the box's own ROM (file://ROM/...).

def esc(s):
    return str('' if s is None else s).replace('&', '&amp;').replace('<', '&lt;').replace('>', '&gt;').replace('"', '&quot;')


def page_frame(title, body, display='', refresh=None):
    r = f'\n<meta http-equiv=Refresh content="1; url={esc(refresh)}">' if refresh else ''
    return f'''<html>
<head>
<title>{esc(title)}</title>{r}
<display {display}>
</head>
<body bgcolor="#191919" text="#cbcbcb" link="#ffcf69" vlink="#ffcf69" fontsize="medium" hspace=0 vspace=0>
<table cellspacing=0 cellpadding=0 width=560>
<tr><td height=16>
<tr><td width=24><td>
<font size=+2 color="#ffcf69"><shadow><b>{esc(title)}</b></shadow></font>
<tr><td height=12>
<tr><td><td>
{body}
</table>
</body>
</html>'''


def button(label, attrs=''):
    return f'<input type=submit value="{esc(label)}" borderimage="file://ROM/Borders/ButtonBorder2.bif" usestyle width=150 {attrs}>'


def page_splash(service, nxt):
    return f'''<html>
<head>
<display hideoptions nostatus showwhencomplete skipback clearback fontsize=medium>
<title>{esc(service)}</title>
<meta http-equiv=Refresh content="2; url={nxt}">
</head>
<body bgcolor="#000000" text="#449944">
<center>
<spacer type=block height=150 width=1><br>
<font size=+3 color="#ffcf69"><shadow><b>{esc(service)}</b></shadow></font>
<p>
<font color="#7f9f7f">Connected at &rate;</font>
</center>
</body>
</html>'''


def page_message(title, text):
    return page_frame(title, f'<p>{esc(text)}</p>')


def page_register(service, q, error=None):
    intro = (f'<p><font color="#ff7766">{esc(error)}</font></p>' if error else
             "<p>This box isn't set up yet. Choose a name and a username to finish setting it up.</p>")
    return page_frame(f'Welcome to {service}', f'''
{intro}
<form action="wtv-register:/ValidateAccountInfo" method="POST">
<table cellspacing=0 cellpadding=4>
<tr><td><font color="#ffcf69">Your name</font>
<td><input name="subscriber_name" value="{esc(q.get('subscriber_name', ''))}" size=20 maxlength=32 bgcolor=#444444 text=#ffdd33 cursor=#cc9933 autocaps selected>
<tr><td><font color="#ffcf69">Username</font>
<td><input name="subscriber_username" value="{esc(q.get('subscriber_username', ''))}" size=20 maxlength=16 bgcolor=#444444 text=#ffdd33 cursor=#cc9933>
</table>
<p>
{button('Continue', 'name=Continue')}
</form>''', display='nooptions noscroll')


def page_registered(service, name, user):
    return page_frame('All set', f'''
<p>Thanks, {esc(name)}. This box is now registered with {esc(service)} as <b>{esc(user)}</b>.</p>
<p>Choose Continue to log in.</p>
<form action="wtv-register:/FinishRegistration">
{button('Continue', 'selected')}
</form>''', display='nooptions noscroll')


HOME_LINKS = [
    ('http://frogfind.com/', 'FrogFind', 'search the web, made for old browsers'),
    ('http://68k.news/', '68k.news', 'headlines, simply formatted'),
    ('http://theoldnet.com/', 'TheOldNet', 'the web as it was, from the Wayback Machine'),
    ('file://ROM/tvhtmls/setup.html', 'Settings', "the box's own setup pages"),
    ('client:showdir?theDir=/', 'Disk', "browse the box's disk (debug builds)"),
]


def page_home(service, d):
    name = d.get('subscriber_name') or d.get('subscriber_username') or 'there'
    rows = '\n'.join(f'<tr><td><a href="{u}">{esc(n)}</a><td><font size=-1 color="#8f8f8f">{esc(w)}</font>'
                     for u, n, w in HOME_LINKS)
    # the form goes to wtv-home:/go: this OS build ignores client:goto
    return page_frame(f'{service} Home', f'''
<p>Hello, {esc(name)}.</p>
<form action="wtv-home:/go">
<table cellspacing=0 cellpadding=0><tr><td>
<input name="url" value="http://" size=34 bgcolor=#444444 text=#ffdd33 cursor=#cc9933 selected>
<td width=8><td>{button('Go to page', 'width=130')}
</table>
</form>
<p>
<table cellspacing=0 cellpadding=6>
{rows}
</table>
<p><font size=-1 color="#8f8f8f">Served by the MiSTer's built-in WebTV service.</font></p>''')


# ==================================================================================== the service
# Enough of a WebTV service to boot the box through registration and login to a home page.
# Protocol and header sets follow zefie's minisrv (wtv-1800, wtv-head-waiter, wtv-register,
# wtv-setup and wtv-home service scripts); the pages are our own.

SVC_HOST = '10.0.0.1'
SERVICES = {               # name -> (port, flags, connections), as minisrv announces them
    'wtv-1800': (1615, '0x00000001', 1), 'wtv-head-waiter': (1601, None, 1), 'wtv-star': (1603, '0x00000007', None),
    'wtv-register': (1607, None, None), 'wtv-flashrom': (1618, '0x00000040', None), 'wtv-log': (1609, None, 1),
    'wtv-home': (1612, None, None), 'wtv-setup': (1613, '0x00000010', 3), 'wtv-mail': (1608, None, 3),
    'wtv-favorite': (1611, None, 3), 'wtv-cookie': (1619, None, 1), 'wtv-tricks': (1602, '0x00000004', None),
    'http': (1650, '0x00000001', 3), 'https': (1650, '0x00000001', 3),
}
# a bare path ("GET /relogin?" after a reconnect) names the service on the port it came in on
PORT_SERVICE = {p: n for n, (p, _, _) in SERVICES.items() if n not in ('http', 'https')}


def service_string(name):
    port, flags, conns = SERVICES[name]

    def one(n):
        return f'wtv-service: name={n} host={SVC_HOST} port={port}' + (f' flags={flags}' if flags else '') + \
            (f' connections={conns}' if conns else '')
    return f'{one(name)}\n{one("wtv-*")}' if name == 'wtv-star' else one(name)


def all_services(except_=()):
    return '\n'.join(service_string(n) for n in sorted(SERVICES) if n not in except_)


def http_date():
    return email.utils.formatdate(usegmt=True)


def parse_query(s):
    q = {}
    for part in (s or '').split('&'):
        if not part:
            continue
        k, _, v = part.partition('=')
        q[urllib.parse.unquote_plus(k, 'latin-1')] = urllib.parse.unquote_plus(v, 'latin-1')
    return q


class FileStore:
    """Accounts (registrations) in a JSON file, so a restart doesn't make the box register again.
    Same format as linux/lineserver.mjs's ~/.webtv-lineserver.json."""
    def __init__(self, path):
        self.path = path
        try:
            with open(path) as f:
                self.m = json.load(f)
        except (OSError, ValueError):
            self.m = {}

    def get(self, k):
        return self.m.get(k)

    def set(self, k, v):
        self.m[k] = v
        try:
            with open(self.path + '.tmp', 'w') as f:
                json.dump(self.m, f, indent=1)
            os.replace(self.path + '.tmp', self.path)
        except OSError as e:
            log(f'[store] {e}')


class Session:
    def __init__(self, ssid, data):
        self.ssid = ssid
        self.data = data or {'registered': False}
        self.login = None                     # WTVSec for the login handshake / ticket


class WebTVService:
    def __init__(self, store, name='WebTV on MiSTer', initial_key=DEFAULT_INITIAL_KEY):
        self.store, self.name, self.initial_key = store, name, initial_key
        self.sessions = {}
        # requests without the box's serial (a relogin after a reconnect) are taken as the last box seen
        self.last_ssid = store.get('lastSsid')

    def session(self, ssid):
        s = self.sessions.get(ssid)
        if not s:
            s = self.sessions[ssid] = Session(ssid, self.store.get(f'account:{ssid}'))
        return s

    def save(self, s):
        self.store.set(f'account:{s.ssid}', s.data)

    def connection_security(self, h):
        sec = WTVSec(self.initial_key, num(hval(h, 'wtv-incarnation')) or 1)
        if h.get('wtv-ticket'):
            sec.decode_ticket(hval(h, 'wtv-ticket'))
        sec.secure_on()
        return sec

    def extra_headers(self, conn):
        s = conn.session
        if s and s.login and s.login.update_ticket and s.login.ticket_b64:
            s.login.update_ticket = False
            return [['wtv-ticket', s.login.ticket_b64]]
        return []

    def handle(self, req, conn, done):
        if req.url.startswith('/') and req.port in PORT_SERVICE:
            req.url = f'{PORT_SERVICE[req.port]}:{req.url}'

        def finish(r):
            log(f'[wtvp] {req.method} {req.url} -> {r[0].split(chr(10))[0]}')
            if self.last_ssid and self.last_ssid != self.store.get('lastSsid'):
                self.store.set('lastSsid', self.last_ssid)
            done(r)

        h = req.headers
        m = re.match(r'^([\w*.+-]+):/?/?([^?]*)(?:\?(.*))?$', req.url)
        if not m:
            return finish(self.not_found(req))
        service, path, qs = m.groups()
        query = parse_query(qs)
        if req.method == 'POST' and req.body:
            query.update(parse_query(req.body.decode('latin-1')))
        ssid = hval(h, 'wtv-client-serial-number') or conn.ssid or self.last_ssid
        if ssid:
            conn.ssid = self.last_ssid = ssid
        s = self.session(ssid) if ssid else None
        conn.session = s
        if service in ('http', 'https'):
            return self.proxy(req, finish)
        if not s and f'{service}:/{path}' == 'wtv-head-waiter:/relogin':
            # relogin needs no session (it sends the box to preregister, where it identifies itself)
            return finish(self.r_relogin(Obj(query=query)))
        if not s:
            return finish(('400 Please reconnect\nContent-Type: text/html', ''))
        ctx = Obj(req=req, h=h, query=query, s=s, conn=conn, service=service, path=path)
        vlog(f'[wtvsrv] {req.method} {req.url}{" (secure)" if req.secure else ""}')
        fn = self.ROUTES.get(f'{service}:/{path}')
        finish(fn(self, ctx) if fn else self.not_found(req))

    def not_found(self, req):
        return ('404 The page you requested is not available on this service\nContent-Type: text/html',
                page_message('Not available', f"{req.url} isn't on this service."))

    def proxy(self, req, finish):
        if not WEB.enabled:
            return finish(("400 Web browsing isn't available here\nContent-Type: text/html", ''))

        def got(r, err):
            if err:
                msg = str(getattr(err, 'reason', None) or err)[:80].replace('\n', ' ')
                return finish((f"400 Couldn't reach that page ({msg})\nContent-Type: text/html", ''))
            status, ctype, body = r
            finish((f'{status}\nwtv-http-proxy: true\nContent-Type: {ctype}', body))
        LOOP.thread(lambda: WEB.fetch(req.url, req.method, hval(req.headers, 'content-type'),
                                      req.body if req.method == 'POST' else None), got)

    # ------------------------------------------------------------ routes
    def r_preregister(self, c):
        h, query, s = c.h, c.query, c.s
        s.login = WTVSec(self.initial_key)
        s.login.issue_challenge()
        if h.get('wtv-incarnation'):
            s.login.set_incarnation(hval(h, 'wtv-incarnation'))
        reg = s.data.get('registered')
        gourl = 'wtv-head-waiter:/login?'
        if query.get('relogin') and reg:
            gourl += 'relogin=true'
        if query.get('reconnect') and reg:
            gourl += 'reconnect=true'
        if h.get('wtv-ticket') and not query.get('reconnect'):
            gourl = 'wtv-head-waiter:/login-stage-two?relogin=true'
        if query.get('reconnect'):
            gourl = None
        open_access = hval(h, 'wtv-open-access') == 'true'
        head = f'200 OK\nConnection: Keep-Alive\nwtv-initial-key: {b64e(s.login.challenge_key)}\nContent-Type: text/html\n'
        if not query.get('reconnect'):
            head += 'wtv-service: reset\n'
        head += '\n'.join(service_string(n) for n in ('wtv-1800', 'wtv-head-waiter', 'wtv-star')) + '\n'
        if query.get('reconnect') and not reg:
            head += service_string('wtv-register') + '\n'
        head += service_string('wtv-flashrom') + '\n'
        head += 'wtv-boot-url: wtv-head-waiter:/login?relogin=true\n'
        if gourl:
            head += f'wtv-visit: {gourl}\n'
        if open_access:
            head += 'wtv-open-isp-disabled: false\n'
        head += f'wtv-client-time-zone: GMT -0000\nwtv-client-time-dst-rule: GMT\nwtv-client-date: {http_date()}'
        return head, ''

    def r_login(self, c):
        h, query, s = c.h, c.query, c.s
        if not s.login:
            # no preregister yet this session, so the box doesn't have our key: start over there
            return ('200 OK\nConnection: Keep-Alive\nExpires: Wed, 09 Oct 1991 22:00:00 GMT\nwtv-expire-all: wtv-head-waiter:\n'
                    'wtv-expire-all: wtv-1800:\nwtv-visit: wtv-head-waiter:/relogin?relogin=true\nContent-type: text/html', '')
        challenge = ''
        ticket = hval(h, 'wtv-ticket')
        if ticket:
            if not s.login.ticket_b64 and len(ticket) > 8:
                try:
                    s.login.decode_ticket(ticket)
                except (ValueError, IndexError) as e:
                    vlog(f'[wtvsrv] {e}')
                    challenge = s.login.issue_challenge()
        else:
            challenge = s.login.issue_challenge()
        gourl = 'wtv-head-waiter:/ValidateLogin?' + ('relogin=true' if query.get('relogin') else
                                                     'reconnect=true' if query.get('reconnect') else 'initial_login=true')
        return (f'200 OK\nConnection: Keep-Alive\nExpires: Wed, 09 Oct 1991 22:00:00 GMT\nwtv-expire-all: wtv-head-waiter:\n'
                f'{service_string("wtv-log")}\nwtv-log-url: wtv-log:/log' + (f'\nwtv-challenge: {challenge}' if challenge else '') +
                f'\nwtv-country: US\nwtv-language-header: en-US,en\nwtv-relogin-url: wtv-head-waiter:/relogin?relogin=true\n'
                f'wtv-reconnect-url: wtv-head-waiter:/relogin?reconnect=true\nwtv-visit: {gourl}\nContent-type: text/html', '')

    def r_validate_login(self, c):
        s = c.s
        if not s.login:
            return '500 Please reconnect\nwtv-visit: wtv-head-waiter:/relogin?relogin=true\nContent-Type: text/html', ''
        resp = hval(c.h, 'wtv-challenge-response')
        if not s.login.ticket_b64:
            if not s.login.check_response(resp):
                log('[wtvsrv] wtv-challenge-response did not match')
                return '500 Invalid challenge response received\nContent-Type: text/html', ''
            s.login.ticket_store = {'user_id': 0}
            s.login.prepare_ticket()
        head = '200 OK\nContent-Type: text/html\nwtv-connection-close: true\nConnection: close'
        if resp:
            head += '\nwtv-encrypted: true'
        return head + '\nwtv-visit: wtv-head-waiter:/login-stage-two?', ''

    def r_relogin(self, c):
        q = c.query
        gourl = 'wtv-1800:/preregister?' + ('relogin=true' if q.get('relogin') else 'reconnect=true' if q.get('reconnect') else '')
        return ('200 OK\nConnection: Keep-Alive\nExpires: Wed, 09 Oct 1991 22:00:00 GMT\nwtv-expire-all: wtv-head-waiter:\n'
                f'wtv-expire-all: wtv-1800:\nwtv-service: reset\n{service_string("wtv-1800")}\nwtv-visit: {gourl}\n'
                'Content-type: text/html', '')

    def r_login_stage_two(self, c):
        s, query = c.s, c.query
        if not s.data.get('registered'):
            return ('200 OK\nwtv-open-isp-disabled: false\nwtv-encrypted: true\n' + service_string('wtv-register') + '\n' +
                    service_string('wtv-head-waiter') + '\n' + service_string('wtv-star') +
                    '\nwtv-boot-url: wtv-head-waiter:/relogin?\nwtv-visit: wtv-register:/splash?\nContent-type: text/html', '')
        d = s.data
        if not d.get('userid'):
            d['userid'] = '1' + str(random.randrange(10 ** 15)).zfill(15)
            self.save(s)
        head = f'''200 OK
Connection: Keep-Alive
wtv-expire-all: wtv-head-waiter:
wtv-country: US
wtv-client-time-zone: GMT -0000
wtv-client-time-dst-rule: GMT
wtv-client-date: {http_date()}
wtv-language-header: en-US,en
wtv-noback-all: wtv-
wtv-transition-override: off
wtv-smartcard-inserted-message: Contacting service
wtv-ssl-timeout: 240
wtv-login-timeout: 7200
wtv-service: reset
{all_services(['wtv-register'])}
wtv-log-url: wtv-log:/log
wtv-ssl-log-url: wtv-log:/log
wtv-bypass-proxy: false
user-id: {d['userid']}
wtv-human-name: {d.get('subscriber_name') or d.get('subscriber_username')}
wtv-input-timeout: 14400
wtv-connection-timeout: 1440
wtv-fader-timeout: 1440
wtv-inactive-timeout: 1440
wtv-relogin-url: wtv-head-waiter:/relogin?relogin=true
wtv-reconnect-url: wtv-head-waiter:/login-stage-two?reconnect=true
wtv-boot-url: wtv-head-waiter:/relogin?relogin=true
wtv-home-url: wtv-home:/home?'''
        if not query.get('reconnect'):
            head += '\nwtv-settings-url: wtv-setup:/get'
        head += ('\nwtv-show-time-enabled: true\nwtv-allow-dsc: true\nwtv-tourist-enabled: false\nwtv-offline-mail-enable: false\n'
                 'wtv-demo-mode: 0\nwtv-name-server: 10.0.0.1\nwtv-open-isp-disabled: false')
        if not query.get('reconnect'):
            head += '\nwtv-visit: wtv-home:/splash?'
        return head + '\nContent-Type: text/html', ''

    def r_reg_splash(self, c):
        return ('200 OK\nConnection: Keep-Alive\nwtv-expire-all: wtv-\nwtv-expire-all: http\nContent-Type: text/html',
                page_splash(self.name, 'wtv-register:/register?'))

    def r_register(self, c):
        return '200 OK\nContent-Type: text/html', page_register(self.name, c.query)

    def r_validate_account(self, c):
        q, s = c.query, c.s
        name, user = q.get('subscriber_name', '').strip(), q.get('subscriber_username', '').strip()
        err = None
        if not name:
            err = 'Please enter your name.'
        elif not re.fullmatch(r'[A-Za-z][A-Za-z0-9_-]{1,15}', user):
            err = 'Please choose a username of 2 to 16 letters, numbers, _ or -, starting with a letter.'
        if err:
            return '200 OK\nContent-Type: text/html', page_register(self.name, q, err)
        s.data.update(subscriber_name=name, subscriber_username=user, registered=True, registered_at=int(time.time() * 1000))
        self.save(s)
        return '200 OK\nwtv-noback-all: wtv-register:\nContent-Type: text/html', page_registered(self.name, name, user)

    def r_finish_registration(self, c):
        s = c.s
        if not s.login:
            s.login = WTVSec(self.initial_key)
        if not s.login.challenge_raw:
            s.login.issue_challenge()
        s.login.ticket_store = {'user_id': 0}
        s.login.prepare_ticket()
        s.login.update_ticket = False             # sent explicitly below
        return (f'''300 Moved
Connection: Close
wtv-noback-all: wtv-register:
wtv-expire-all: wtv-
wtv-ticket: {s.login.ticket_b64}
wtv-service: reset
{service_string('wtv-1800')}
{service_string('wtv-head-waiter')}
{service_string('wtv-star')}
wtv-relogin-url: wtv-1800:/preregister?relogin=true
wtv-reconnect-url: wtv-1800:/preregister?reconnect=true
wtv-boot-url: wtv-1800:/preregister?relogin=true
Location: client:relogin''', '')

    def r_setup_get(self, c):
        settings = {
            'from-server': 1, 'setup-advanced-options': 0, 'setup-play-bgm': 0, 'setup-bgm-tempo': -1, 'setup-bgm-volume': 100,
            'setup-background-color': 'c6c6c6', 'setup-font-sizes': 'medium', 'setup-in-stereo': 1, 'setup-keyboard': 'alphabetical',
            'setup-link-color': '2222bb', 'setup-play-songs': 1, 'setup-play-sounds': 1, 'setup-text-color': 0, 'setup-visited-color': '8822bb',
        }
        settings.update(c.s.data.get('settings') or {})
        return ('200 OK\nwtv-printer-model: -1,-1\nwtv-printer-pen: 0,0,1,0\nwtv-printer-setup: 0,0,1,0\nwtv-language-header: en-US,en\n'
                'Content-Type: text/html', '&'.join(f"{k}={urllib.parse.quote(str(v), safe=chr(39) + '-_.!~*()')}" for k, v in settings.items()))

    def r_home_splash(self, c):
        return ('200 OK\nConnection: Keep-Alive\nwtv-expire-all: wtv-\nwtv-expire-all: http\nContent-Type: text/html',
                page_splash(self.name, 'wtv-home:/home?'))

    def r_home(self, c):
        return '200 OK\nContent-Type: text/html', page_home(self.name, c.s.data)

    def r_go(self, c):
        url = c.query.get('url', '').strip()
        if not url or url == 'http://':
            return '200 OK\nwtv-visit: wtv-home:/home\nContent-Type: text/html', ''
        if not re.match(r'^[\w-]+:', url):
            url = 'http://' + url
        if re.fullmatch(r'https?://[^/?#]+', url, re.I):
            url += '/'                            # the box fetches "host/"; visit the same URL
        # wtv-visit to an http URL fails with error -37: a redirect works
        url = url.replace('\r', '').replace('\n', '')
        return f'302 Moved\nLocation: {url}\nContent-Type: text/html', ''

    ROUTES = {
        'wtv-1800:/preregister': r_preregister,
        'wtv-head-waiter:/login': r_login,
        'wtv-head-waiter:/ValidateLogin': r_validate_login,
        'wtv-head-waiter:/relogin': r_relogin,
        'wtv-head-waiter:/login-stage-two': r_login_stage_two,
        'wtv-register:/splash': r_reg_splash,
        'wtv-register:/register': r_register,
        'wtv-register:/ValidateAccountInfo': r_validate_account,
        'wtv-register:/FinishRegistration': r_finish_registration,
        'wtv-setup:/get': r_setup_get,
        'wtv-home:/splash': r_home_splash,
        'wtv-home:/home': r_home,
        'wtv-home:/go': r_go,
        'wtv-log:/log': lambda self, c: ('200 OK\nContent-Type: text/html', ''),
        'wtv-mail:/addresslist': lambda self, c: ('200 OK\nContent-Type: x-wtv-addresses', ''),
        'wtv-favorite:/list-folders': lambda self, c: ('200 OK\nContent-Type: text/plain', ''),
        'wtv-cookie:/list': lambda self, c: ('200 OK\nContent-Type: text/plain', ''),
    }


# ==================================================================================== web pages

UA = 'Mozilla/4.0 WebTV/2.8 (compatible; MSIE 4.0)'
ASCII = str.maketrans({'‘': "'", '’': "'", '‚': "'", '“': '"', '”': '"', '„': '"',
                       '–': '-', '—': '--', '…': '...', '•': '*', '™': '(TM)'})


SLIM = [re.compile(p, re.I | re.S) for p in (
    rb'<script\b.*?</script\s*>', rb'<style\b.*?</style\s*>', rb'<!--.*?-->', rb'<svg\b.*?</svg\s*>',
    rb'<template\b.*?</template\s*>', rb'<link\b[^>]*>', rb'</?noscript\b[^>]*>')]
DATA_URI = re.compile(rb'''(["'])data:[^"']{200,}\1''', re.I)
# attributes a 1997 browser ignores (no CSS, no modern script): often most of what's left
DEAD_ATTR = re.compile(rb'''\s(?:class|style|id|data-[\w.:-]+|aria-[\w-]+|role|srcset|sizes|loading|decoding|fetchpriority|'''
                       rb'''crossorigin|integrity|nonce|item(?:prop|scope|type|id)|tabindex|js\w+|on\w+|slot|part|is)'''
                       rb'''(?:\s*=\s*(?:"[^"]*"|'[^']*'|[^\s>]+))?(?=[\s/>])''', re.I)


def slim_html(data):
    """Drop what a 1997 browser can't use: scripts, style sheets, comments, SVG, templates and inline
    data: images. Modern pages are mostly these (YouTube: 2.2 MB, nearly all script)."""
    for r in SLIM:
        data = r.sub(b'', data)
    data = DATA_URI.sub(b'""', data)
    return re.sub(rb'<[A-Za-z][^<>]*>', lambda m: DEAD_ATTR.sub(b'', m.group(0)), data)


def to_latin1(data, ctype):
    """The box's browser is Latin-1: a UTF-8 page shows "Â " for every no-break space. Decode text as
    UTF-8 when it says so (or is valid UTF-8), map common punctuation to ASCII, and send Latin-1."""
    m = re.search(r'charset=([\w-]+)', ctype, re.I)
    if m and not re.fullmatch(r'utf-?8', m.group(1), re.I):
        return data
    try:
        text = data.decode('utf-8', 'replace' if m else 'strict')
    except UnicodeDecodeError:
        return data
    text = re.sub(r'<meta[^>]+charset=[^>]*>', '', text, flags=re.I)
    return text.translate(ASCII).encode('latin-1', 'replace')


class Web:
    def __init__(self, enabled=True, max_page=384 * 1024, images=True, quality=60, verify=True, cafile=None):
        self.enabled, self.max_page, self.images, self.quality = enabled, max_page, images, quality
        ctx = ssl.create_default_context()
        if verify:
            try:
                ctx.load_verify_locations(cadata=ca_roots())        # current roots: the MiSTer's date from 2020
            except (ssl.SSLError, ValueError, zlib.error) as e:
                log(f'[web] built-in CA roots: {e}')
            if cafile:
                ctx.load_verify_locations(cafile=cafile)
        else:
            ctx.check_hostname = False
            ctx.verify_mode = ssl.CERT_NONE
        self.opener = urllib.request.build_opener(urllib.request.HTTPSHandler(context=ctx))

    def fetch(self, url, method='GET', ctype=None, body=None):
        """(status line, content type, body) for the box. Runs in a worker thread."""
        url = urllib.parse.quote(url, safe=":/?#[]@!$&'()*+,;=%~", encoding='latin-1')
        hdrs = {'User-Agent': UA}
        if ctype:
            hdrs['Content-Type'] = ctype
        req = urllib.request.Request(url, data=body, method=method, headers=hdrs)
        t0 = time.monotonic()
        try:
            r = self.opener.open(req, timeout=20)
        except urllib.error.HTTPError as e:
            r = e                             # 404 etc.: the page still goes to the box
        try:
            code = r.getcode()
            status = f'{code} {r.reason or "OK"}'
            rtype = (r.headers.get('Content-Type') if r.headers else None) or 'text/html'
            try:
                data = r.read(8 << 20)
            except (OSError, AttributeError, ValueError):
                data = b''
        finally:
            r.close()
        note = ''
        if re.match(r'text/', rtype, re.I):
            data = to_latin1(data, rtype)
            if re.match(r'text/html', rtype, re.I):
                n0 = len(data)
                data = slim_html(data)
                if len(data) < n0:
                    note = f', slimmed from {n0}'
        elif self.images and (re.match(r'image/', rtype, re.I) or sniff_image(data)):
            n0 = len(data)
            data, rtype, note = shrink_image(data, rtype, self.quality)
            if note:
                note = f', {note}: {n0} -> {len(data)} bytes'
        log(f'[web] {method} {url} -> {code} ({len(data)} bytes, {time.monotonic() - t0:.1f}s{note})')
        if len(data) > self.max_page:
            # an 8 MB box can't take a modern multi-megabyte page (it fails with an out-of-memory alert)
            msg = (f'<html><head><title>Page too large</title></head><body><h2>Page too large</h2><p>{esc(url)} is '
                   f'{len(data) // 1024} KB; this box can show pages up to {self.max_page // 1024} KB. Try FrogFind or '
                   f'68k.news for lighter versions of sites.</p></body></html>')
            return '200 OK', 'text/html', msg.encode('latin-1', 'replace')
        return status, rtype.split(';')[0].strip(), data


# ==================================================================================== images
# The box decodes GIF, baseline JPEG and XBM (its OS has no PNG decoder), and it has 8 MB of RAM
# and a 57.6 kbit/s line. As WebTV's own service did, images are converted for it: PNG, BMP,
# progressive JPEG etc. become JPEG (or GIF when they have transparency), and anything wider than
# the screen is scaled down. Decoding and scaling are done by Imlib2 (the MiSTer's own image
# library, which its menu uses for wallpapers), through ctypes; GIF encoding is ours.

MAX_W, MAX_H = 560, 1200
_IMLIB_LOCK = threading.Lock()


class Imlib:
    lib = None
    tried = False

    @classmethod
    def get(cls):
        if not cls.tried:
            cls.tried = True
            path = ctypes.util.find_library('Imlib2') or 'libImlib2.so.1'
            try:
                L = ctypes.CDLL(path)
            except OSError:
                log('[img] Imlib2 not found: images are passed through unchanged')
                return None
            vp, i, ch, cp = ctypes.c_void_p, ctypes.c_int, ctypes.c_char, ctypes.c_char_p
            sig = {
                'imlib_load_image_immediately_without_cache': ([cp], vp), 'imlib_context_set_image': ([vp], None),
                'imlib_image_get_width': ([], i), 'imlib_image_get_height': ([], i), 'imlib_image_has_alpha': ([], ch),
                'imlib_context_set_anti_alias': ([ch], None), 'imlib_context_set_blend': ([ch], None),
                'imlib_create_cropped_scaled_image': ([i] * 6, vp), 'imlib_create_image': ([i, i], vp),
                'imlib_image_set_has_alpha': ([ch], None), 'imlib_context_set_color': ([i] * 4, None),
                'imlib_image_fill_rectangle': ([i] * 4, None),
                'imlib_blend_image_onto_image': ([vp, ch] + [i] * 8, None),
                'imlib_image_set_format': ([cp], None), 'imlib_image_attach_data_value': ([cp, vp, i, vp], None),
                'imlib_save_image': ([cp], None), 'imlib_free_image_and_decache': ([], None),
                'imlib_image_get_data_for_reading_only': ([], vp),
            }
            for name, (args, res) in sig.items():
                f = getattr(L, name)
                f.argtypes, f.restype = args, res
            cls.lib = L
        return cls.lib


def sniff_image(d):
    if d[:6] in (b'GIF87a', b'GIF89a'):
        return 'gif'
    if d[:3] == b'\xff\xd8\xff':
        return 'jpeg'
    if d[:8] == b'\x89PNG\r\n\x1a\n':
        return 'png'
    if d[:2] == b'BM':
        return 'bmp'
    if d[:4] in (b'II*\0', b'MM\0*'):
        return 'tiff'
    if d[:4] == b'\0\0\1\0':
        return 'ico'
    return None


def jpeg_info(d):
    """(width, height, progressive) from the SOF marker."""
    i = 2
    while i + 9 < len(d):
        if d[i] != 0xff:
            i += 1
            continue
        mk = d[i + 1]
        if mk in (0xd8, 0x01) or 0xd0 <= mk <= 0xd7 or mk == 0xff:
            i += 2 if mk != 0xff else 1
            continue
        ln = (d[i + 2] << 8) | d[i + 3]
        if mk in (0xc0, 0xc1, 0xc2, 0xc3, 0xc5, 0xc6, 0xc7, 0xc9, 0xca, 0xcb, 0xcd, 0xce, 0xcf):
            h, w = struct.unpack('>HH', d[i + 5:i + 9])
            return w, h, mk not in (0xc0, 0xc1)
        i += 2 + ln
    return None


def fit(w, h):
    s = min(1.0, MAX_W / w, MAX_H / h) if w and h else 1.0
    return max(1, round(w * s)), max(1, round(h * s))


def shrink_image(data, rtype, quality):
    """(data, content type, note) for the box. Runs in a worker thread."""
    kind = sniff_image(data)
    if kind == 'gif':
        # GIFs are what the box was made for: leave them (and their animation and palette) alone
        # unless they are huge
        w, h = struct.unpack('<HH', data[6:10])
        if w <= 2 * MAX_W and h <= 2 * MAX_H and len(data) <= 160 * 1024:
            return data, 'image/gif', ''
    elif kind == 'jpeg':
        info = jpeg_info(data)
        if info and info[0] <= MAX_W and info[1] <= MAX_H and not info[2] and len(data) <= 48 * 1024:
            return data, 'image/jpeg', ''
    elif kind is None:
        return data, rtype, ''                # SVG, WebP...: nothing the box (or Imlib2) can read
    L = Imlib.get()
    if not L:
        return data, rtype, ''
    with _IMLIB_LOCK:
        return _convert(L, data, kind, rtype, quality)


def _convert(L, data, kind, rtype, quality):
    fd, src = tempfile.mkstemp(prefix='webtv-img-', suffix='.' + kind)
    dst = src + '.out'
    try:
        with os.fdopen(fd, 'wb') as f:
            f.write(data)
        img = L.imlib_load_image_immediately_without_cache(src.encode())
        if not img:
            return data, rtype, ''
        L.imlib_context_set_image(img)
        w, h = L.imlib_image_get_width(), L.imlib_image_get_height()
        alpha = L.imlib_image_has_alpha() != b'\0'
        nw, nh = fit(w, h)
        L.imlib_context_set_anti_alias(b'\1')
        L.imlib_context_set_blend(b'\1')
        out = img
        if (nw, nh) != (w, h):
            out = L.imlib_create_cropped_scaled_image(0, 0, w, h, nw, nh)
            L.imlib_free_image_and_decache()
            L.imlib_context_set_image(out)
        note = f'{kind} {w}x{h}' + (f' -> {nw}x{nh}' if (nw, nh) != (w, h) else '')
        if alpha and nw * nh <= 300000:
            argb = ctypes.string_at(L.imlib_image_get_data_for_reading_only(), nw * nh * 4)
            L.imlib_free_image_and_decache()
            return gif_encode(nw, nh, argb), 'image/gif', note + ' gif'
        if alpha:                             # too big for our GIF encoder: flatten onto white
            flat = L.imlib_create_image(nw, nh)
            L.imlib_context_set_image(flat)
            L.imlib_image_set_has_alpha(b'\0')
            L.imlib_context_set_color(255, 255, 255, 255)
            L.imlib_image_fill_rectangle(0, 0, nw, nh)
            L.imlib_blend_image_onto_image(out, b'\0', 0, 0, nw, nh, 0, 0, nw, nh)
            L.imlib_context_set_image(out)
            L.imlib_free_image_and_decache()
            L.imlib_context_set_image(flat)
        L.imlib_image_set_format(b'jpg')
        L.imlib_image_attach_data_value(b'quality', None, quality, None)
        L.imlib_save_image(dst.encode())
        L.imlib_free_image_and_decache()
        with open(dst, 'rb') as f:
            jpg = f.read()
        info = jpeg_info(data) if kind == 'jpeg' else None
        if info and len(jpg) >= len(data) and (nw, nh) == (w, h) and not info[2]:
            return data, 'image/jpeg', ''
        return jpg, 'image/jpeg', note + ' jpeg'
    finally:
        for p in (src, dst):
            try:
                os.unlink(p)
            except OSError:
                pass


def gif_encode(w, h, argb):
    """GIF89a from Imlib2's ARGB (little-endian B,G,R,A): a 6x6x6 colour cube + one transparent index."""
    q = bytes((v * 5 + 127) // 255 for v in range(256))
    b, g, r, a = argb[0::4].translate(q), argb[1::4].translate(q), argb[2::4].translate(q), argb[3::4]
    n = w * h
    # r*36 + g*6 + b for every pixel at once: no byte exceeds 215, so the big-integer sum never carries
    idx = (int.from_bytes(r, 'big') * 36 + int.from_bytes(g, 'big') * 6 + int.from_bytes(b, 'big')).to_bytes(n, 'big')
    idx = bytes(216 if t < 128 else i for i, t in zip(idx, a))
    pal = bytearray()
    for i in range(256):
        if i < 216:
            pal += bytes((i // 36 * 51, i // 6 % 6 * 51, i % 6 * 51))
        else:
            pal += b'\xff\xff\xff'
    out = bytearray(b'GIF89a' + struct.pack('<HHBBB', w, h, 0xf7, 216, 0) + pal)
    out += b'\x21\xf9\x04\x01\x00\x00' + bytes([216]) + b'\x00'
    out += b'\x2c' + struct.pack('<HHHHB', 0, 0, w, h, 0) + b'\x08'
    lz = lzw(idx, 8)
    for i in range(0, len(lz), 255):
        out += bytes([len(lz[i:i + 255])]) + lz[i:i + 255]
    out += b'\x00\x3b'
    return bytes(out)


def lzw(data, min_size):
    clear, eoi = 1 << min_size, (1 << min_size) + 1
    out = bytearray()
    acc = nbits = 0
    size = min_size + 1
    table = {}
    nxt = eoi + 1
    acc |= clear << nbits
    nbits += size
    prefix = data[0]
    for c in data[1:]:
        key = (prefix << 8) | c
        code = table.get(key)
        if code is not None:
            prefix = code
            continue
        acc |= prefix << nbits
        nbits += size
        while nbits >= 8:
            out.append(acc & 255)
            acc >>= 8
            nbits -= 8
        if nxt < 4096:
            table[key] = nxt
            nxt += 1
            if nxt > (1 << size) and size < 12:
                size += 1
        else:
            acc |= clear << nbits
            nbits += size
            table.clear()
            nxt = eoi + 1
            size = min_size + 1
        prefix = c
    acc |= prefix << nbits
    nbits += size
    # the decoder adds an entry on reading the last code, as if the encoder had: EOI may need one more bit
    if nxt < 4096 and nxt + 1 > (1 << size) and size < 12:
        size += 1
    acc |= eoi << nbits
    nbits += size
    while nbits >= 8:
        out.append(acc & 255)
        acc >>= 8
        nbits -= 8
    if nbits:
        out.append(acc & 255)
    return bytes(out)


# ==================================================================================== the modem

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
        log(f'[modem] {s}')

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
    def from_host(self, data):
        if self.trace:
            for b in data:
                OUT.write(f'> {b:02x} {chr(b) if 32 <= b < 127 else ""}\n')
        i = 0
        while i < len(data):
            if self.online:
                # online: pass the run through, watching for the +++ escape
                j = i
                while j < len(data) and data[j] != self.sregs[2]:
                    j += 1
                if j > i:
                    self.plus_count = 0
                    self.last_tx = time.monotonic()
                    self.to_line(data[i:j])
                    i = j
                    continue
                self.last_tx = time.monotonic()
                self.plus_count += 1
                if self.plus_count == 3:
                    self.esc_at = time.monotonic() + 1.0
                self.to_line(data[i:i + 1])
                i += 1
                continue
            self.from_host_byte(data[i])
            i += 1

    def to_line(self, d):
        if self.sock:
            try:
                self.sock.sendall(bytes(d))
            except OSError:
                self.hangup('send failed')

    def from_host_byte(self, b):
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
        if self.connect_to == 'local':
            self.sock = Line(self.line_data, lambda why: self.hangup('remote: ' + why),
                             lambda: len(self.out), lambda: self.online)
            self.dial_at, self.dial_result = now + 1.5, 'CONNECT 57600'
            return
        host, port = self.connect_to.rsplit(':', 1)
        try:
            self.sock = socket.create_connection((host, int(port)), timeout=10)
            self.sock.setblocking(False)
            self.dial_at, self.dial_result = now + 1.5, 'CONNECT 57600'
        except OSError as e:
            self.log(f'connect {self.connect_to} failed: {e}')
            self.sock = None
            self.dial_at, self.dial_result = now + 1.5, 'NO CARRIER'

    def line_data(self, data):
        if self.online:
            self.out += data

    def hangup(self, why=None):
        if why:
            self.log(f'hangup ({why})')
        was = self.online or self.connected
        self.online = self.connected = False
        self.dial_at = None
        self.out.clear()
        if self.sock:
            s, self.sock = self.sock, None
            try:
                s.close()
            except OSError:
                pass
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
    """KEY=VALUE lines (# comments)."""
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
    m.log(f'on {args.tty}, ' + ('built-in WebTV service' if args.connect == 'local' else
                                f'line {args.connect}' if args.connect else 'no line (NO DIALTONE)'))
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
            sock = m.sock if isinstance(m.sock, socket.socket) else None
            rl = [fd, LOOP.r] + ([sock] if sock else [])
            r, _, _ = select.select(rl, [], [], LOOP.timeout(0.005))
            if fd in r:
                try:
                    data = os.read(fd, 4096)
                except BlockingIOError:
                    data = b''
                if data:
                    m.from_host(data)
            if sock and sock in r:
                try:
                    data = sock.recv(4096)
                    if not data:
                        m.hangup('remote')
                    elif m.online:
                        m.out += data
                except BlockingIOError:
                    pass
                except OSError:
                    m.hangup('remote error')
            LOOP.run_due()
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


def serve(port):
    """A LAN line server: each TCP connection from a modem (webtv_modem.py connect=HOST:PORT) is a call."""
    ls = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    ls.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    ls.bind(('', port))
    ls.listen(4)
    ls.setblocking(False)
    log(f'[line] WebTV line server on port {port}')
    calls = {}                                 # socket -> [Line, out buffer]

    def hang(s, why):
        c = calls.pop(s, None)
        if c:
            log(f'[line] hangup {why}')
            c[0].close()
            s.close()
    while True:
        rl = [ls, LOOP.r] + list(calls)
        wl = [s for s, c in calls.items() if c[1]]
        r, w, _ = select.select(rl, wl, [], LOOP.timeout(1.0))
        if ls in r:
            s, addr = ls.accept()
            s.setblocking(False)
            s.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
            log(f'[line] call from {addr[0]}:{addr[1]}')
            c = [None, bytearray()]
            calls[s] = c
            c[0] = Line(lambda d, c=c: c[1].extend(d), lambda why, s=s: LOOP.call_soon(lambda: hang(s, 'PPP ' + why)),
                        lambda c=c: len(c[1]), lambda: True)
        for s in r:
            if s in calls:
                try:
                    d = s.recv(4096)
                except BlockingIOError:
                    continue
                except OSError as e:
                    hang(s, str(e))
                    continue
                if not d:
                    hang(s, 'socket closed')
                else:
                    calls[s][0].sendall(d)
        for s in w:
            if s in calls:
                try:
                    n = s.send(calls[s][1])
                    del calls[s][1][:n]
                except BlockingIOError:
                    pass
                except OSError as e:
                    hang(s, str(e))
        LOOP.run_due()


SERVICE = None
WEB = None


def main():
    global OUT, VERBOSE, SERVICE, WEB
    ap = argparse.ArgumentParser(description='WebTV modem, line and service for the MiSTer WebTV core')
    ap.add_argument('--config', help='KEY=VALUE file (see webtv.cfg); arguments override it')
    ap.add_argument('--tty')
    ap.add_argument('--connect', help='local (built-in service, the default) or HOST:PORT of a line server')
    ap.add_argument('--listen', type=int, help='be a line server on this TCP port instead of a modem')
    ap.add_argument('--log', action='store_true', default=None, help='print the core debug console')
    ap.add_argument('--trace', action='store_true', default=None, help='print every byte from the box')
    ap.add_argument('--core', help='run only while this core is loaded (/tmp/CORENAME), e.g. WebTV')
    ap.add_argument('--logfile', help='write to this file (kept under 4 MB, one old copy) instead of stdout')
    ap.add_argument('--store', help='accounts file (default: webtv-accounts.json next to this script)')
    ap.add_argument('--verbose', action='store_true', default=None, help='log PPP, TCP and service details')
    args = ap.parse_args()
    cfg = read_config(args.config) if args.config else {}
    yes = lambda v: str(v).lower() in ('1', 'yes', 'true', 'on')
    args.tty = args.tty or cfg.get('tty', '/dev/ttyS1')
    args.connect = args.connect or cfg.get('connect') or 'local'
    if args.connect.lower() in ('none', 'off'):
        args.connect = None
    args.log = args.log if args.log is not None else yes(cfg.get('log', '0'))
    args.trace = args.trace if args.trace is not None else yes(cfg.get('trace', '0'))
    VERBOSE = args.verbose if args.verbose is not None else yes(cfg.get('verbose', '0'))
    if args.logfile:
        OUT = Output(args.logfile)
    store = args.store or cfg.get('store') or os.path.join(HERE, 'webtv-accounts.json')
    SERVICE = WebTVService(FileStore(store), name=cfg.get('name', 'WebTV on MiSTer'))
    WEB = Web(enabled=yes(cfg.get('web', '1')), max_page=num(cfg.get('max_page'), 384 * 1024),
              images=yes(cfg.get('images', '1')), quality=num(cfg.get('image_quality'), 60),
              verify=yes(cfg.get('tls_verify', '1')), cafile=cfg.get('cafile') or None)
    if args.listen:
        serve(args.listen)
        return
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
            log(f'[modem] {e}; retrying')
            time.sleep(2)


# ==================================================================================== CA roots
# Mozilla's root certificates (curl.se/ca/cacert.pem), DER, zlib, base64: the MiSTer's own bundle
# dates from 2020 and lacks newer roots. Regenerate with linux/update_ca.py.

def ca_roots():
    return zlib.decompress(base64.b64decode(''.join(CA_ROOTS.split())))


# Mozilla root certificates as of: Thu Nov  5 04:12:01 2026 GMT, 118 roots
CA_ROOTS = '''
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
dlLu2qDQ0sh7hP8wU/JRT3gkJDLw+uEyxzSdENePNB0eJM6uCwxvLWe2Rbl4N4XaJyBzM5IqgyGa4f0FIBchZbZAD01vCjs4m8dX
bYB3eNcMpG4BgV/2L7rlELugcEGIoBULJWnF+sWnG611YSy+WkQEERs2hcGWk4hocE16i3UMfoIcWLnzhkV7MyuaPGUXfwHHzsNk
ju21dEVY1WZ2w1hfJKo0DQdLenTSCEVdHMQ8/qw2lD09zqNOwdTCHThRYzSnFhen7ETQ7ZL14L6tmzlbCYJ+43msnRCjIE5IcS9K
xSMVXKHhMwqWqqa7pGqUGCU4fefjTebjVeV7Cy7ZyJNhp5gKIvGs+pDyi8pj0itpvH+K8EMlYHMssJt8NiHq7K1Ou5H4W74a/V44
8dfsUiRoQTMTs19UmX6RQPwVhlBI8N/zBF9f+uXJ3y9ix/TEdIQ/YIj1lzP4HRyc7I0M8cUEf3Dxh4DjL/L8v/D2t9XXmH82/1OX
8WereMuH5LTyvCz2YqEJTNf35rj0ir7ZlYr8DSKbSSVz1b7ULZCTTs9hhV7Ej7uE0FTtiWhQjJ0YUvxgsQAd0FLw38AbDrGtCZXo
jZI7ZtFmcPWvVz9bykbyBkInTTaNAm+NWOUiS2KFrZ8CfJD3rI6zrGFDmv6E+KYL4AM2FcKKiy1LetWEW8iav+0BhKOtkll1vml2
53qjW91Vpi2F0k35S6Le9TCfDc70x4S22VDKtsxOe3VlO07euetpyG/k5/lny6nVwLMxuk1X8bk1HWFheHTjvUU0+oxVqEAuguqH
fpBcxYI0bs28IO2aOSHbWNVy0eMnbx/vv1ldcHiWReyZJNJH/bfJFPwbMk30irekKl01r+p2lnp3KDcksxQv/NEq3kihUuTuEL+1
GVmxE8I5VzCLzUzmgCsbjllSXrwZDZtluhfIXFhhDT1r+DDBWLnleAR22kKn6AyDcXd41zUtx3nX7lxc8LTsLvCqg4uNOLvC6Qbp
YINXNdW7aSf9XXEqoEFZiS2znSRLWEFjeMGYStDje7eKIqwjVqZMhWG9sjz5anFb1OAejqEaJFuWpcmzG0imeQ3JZ/CMvNZlQHvN
a6nuddgabJg+g4+VN8hPYSd5/LCSY0MqfFPWwGXj0NFhqamWF1x01WybNu35HynwycodX5AIXTeS5ZVwAxoU8YHPqrpklDdYx3p9
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
'''

if __name__ == '__main__':
    main()
