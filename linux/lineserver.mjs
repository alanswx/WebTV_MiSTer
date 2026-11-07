// WebTV MiSTer core: the network behind the modem. Each TCP connection is one phone call: the
// webtv-bridge network line (PPP server + IP gateway, src/net/line.js) answers it, with the
// built-in WebTV service (src/wtvsrv) and/or a relay to the real Internet.
//
// The MiSTer side (linux/webtv_modem.py --connect HOST:PORT) dials this when the box sends ATD and
// relays the modem's online data both ways.
//
//   node linux/lineserver.mjs [--port 2323] [--bridge PATH_TO_webtv-bridge] [--relay ws://host:8081]
//                             [--store FILE (default ~/.webtv-lineserver.json)] [--no-web]
//                             [--max-page BYTES (default 393216)]
//
// Web pages the box asks the service for (http/https) are fetched by this host (--no-web to disable).
// Without --relay the line answers with the built-in service only (registration / home pages).
import net from 'node:net';
import { readFileSync, writeFileSync, renameSync } from 'node:fs';
import { homedir } from 'node:os';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const args = process.argv.slice(2);
const opt = (n, d) => { const i = args.indexOf('--' + n); return i >= 0 ? args[i + 1] : d; };
const HERE = dirname(fileURLToPath(import.meta.url));
const BR = opt('bridge', join(HERE, '../ext/webtv-bridge'));
const PORT = Number(opt('port', '2323'));
const RELAY = opt('relay', null);
const VERBOSE = args.includes('--verbose');
const MAX_PAGE = Number(opt('max-page', String(384 * 1024)));
const STORE = opt('store', join(homedir(), '.webtv-lineserver.json'));

const { createNetworkLine } = await import(join(BR, 'src/net/line.js'));
const { WebTVService } = await import(join(BR, 'src/wtvsrv/service.js'));

const ts = () => new Date().toISOString().slice(11, 23);
const log = (...a) => console.log(ts(), ...a);
const quiet = VERBOSE ? log : () => {};

// The box's browser is Latin-1: a UTF-8 page shows "Â " for every no-break space. Decode text as
// UTF-8 when it says so (or is valid UTF-8), map common punctuation to ASCII, and send Latin-1.
const ASCII = { '\u2018': "'", '\u2019': "'", '\u201a': "'", '\u201c': '"', '\u201d': '"', '\u201e': '"',
  '\u2013': '-', '\u2014': '--', '\u2026': '...', '\u2022': '*', '\u2122': '(TM)', '\u00a0': '\u00a0' };
function toLatin1(bytes, type) {
  const declared = (/charset=([\w-]+)/i.exec(type) || [])[1];
  let text;
  if (declared && !/utf-?8/i.test(declared)) return bytes;
  try { text = new TextDecoder('utf-8', { fatal: !declared }).decode(bytes); } catch { return bytes; }
  text = text.replace(/<meta[^>]+charset=[^>]*>/gi, '');
  const out = new Uint8Array(text.length * 5);
  let n = 0;
  for (const ch of text) {
    const c = ch.codePointAt(0);
    if (c < 256) { out[n++] = c; continue; }
    for (const a of (ASCII[ch] ?? '?')) out[n++] = a.charCodeAt(0);
  }
  return out.subarray(0, n);
}

// web pages (http/https proxied by the service): fetched by this host, unless --no-web
async function fetchUrl(url, { method = 'GET', headers = {}, body } = {}) {
  const h = { 'User-Agent': 'Mozilla/4.0 WebTV/2.8 (compatible; MSIE 4.0)' };
  if (headers['Content-Type']) h['Content-Type'] = headers['Content-Type'];
  const r = await fetch(url, { method, headers: h, body, redirect: 'follow', signal: AbortSignal.timeout(20000) });
  let out = new Uint8Array(await r.arrayBuffer());
  const type = r.headers.get('content-type') || 'text/html';
  if (/^text\//i.test(type)) out = toLatin1(out, type);
  log(`web ${method} ${url} -> ${r.status} (${out.length} bytes)`);
  // an 8 MB box can't take a modern multi-megabyte page (it fails with an out-of-memory alert)
  if (out.length > MAX_PAGE) {
    const msg = `<html><head><title>Page too large</title></head><body><h2>Page too large</h2>` +
      `<p>${url.replace(/[<&"]/g, '')} is ${Math.round(out.length / 1024)} KB; this box can show pages up to ` +
      `${Math.round(MAX_PAGE / 1024)} KB. Try FrogFind or 68k.news for lighter versions of sites.</p></body></html>`;
    return { status: '200 OK', headers: { 'content-type': 'text/html' }, body: new TextEncoder().encode(msg) };
  }
  return { status: `${r.status} ${r.statusText || 'OK'}`, headers: { 'content-type': type.replace(/;.*$/, '') }, body: out };
}

// accounts (registrations) kept in a JSON file, so restarting the server doesn't make the box
// register again
class FileStore {
  constructor(path) {
    this.path = path;
    try { this.m = JSON.parse(readFileSync(path, 'utf8')); } catch { this.m = {}; }
  }
  async get(k) { return this.m[k] ?? null; }
  async set(k, v) {
    this.m[k] = v;
    try { writeFileSync(this.path + '.tmp', JSON.stringify(this.m, null, 1)); renameSync(this.path + '.tmp', this.path); }
    catch (e) { log(`store: ${e.message}`); }
  }
}

// one service for all calls: registrations and sessions persist between calls
const store = new FileStore(STORE);
const service = new WebTVService({ store, log: quiet, fetchUrl: args.includes('--no-web') ? null : fetchUrl });

// every request and its status line in the log (the service's own log is --verbose)
// A box sometimes sends a bare path ("GET /relogin?" after a reconnect); as minisrv does, it names the
// service on the port it came in on. Ports from webtv-bridge's src/wtvsrv/service.js SERVICES.
const PORT_SERVICE = { 1601: 'wtv-head-waiter', 1602: 'wtv-tricks', 1603: 'wtv-star', 1607: 'wtv-register',
  1608: 'wtv-mail', 1609: 'wtv-log', 1611: 'wtv-favorite', 1612: 'wtv-home', 1613: 'wtv-setup',
  1615: 'wtv-1800', 1618: 'wtv-flashrom', 1619: 'wtv-cookie' };
// Requests that don't carry the box's serial (a relogin after a reconnect) are taken as the last box
// seen; remember it across restarts too, or the first such request after one gets "400 Please reconnect".
service.lastSsid = await store.get('lastSsid');
// The home page's "Go to page" form posts to client:goto, which this OS build ignores
// ("ExecuteClientFunction: ignoring client:goto"); point it at wtv-home:/go, which sends the box
// to the URL with wtv-visit.
const home = service.routes['wtv-home:/home'];
service.routes['wtv-home:/home'] = async function (ctx) {
  const r = await home.call(this, ctx);
  if (typeof r.body === 'string') r.body = r.body.replace('action="client:goto"', 'action="wtv-home:/go"');
  return r;
};
service.routes['wtv-home:/go'] = async function ({ query }) {
  let url = String(query.url || '').trim();
  if (!url || url === 'http://') return { head: '200 OK\nwtv-visit: wtv-home:/home\nContent-Type: text/html', body: '' };
  if (!/^[\w-]+:/.test(url)) url = 'http://' + url;
  if (/^https?:\/\/[^/?#]+$/i.test(url)) url += '/';   // the box fetches "host/"; visit the same URL
  return { head: `302 Moved\nLocation: ${url.replace(/[\r\n]/g, '')}\nContent-Type: text/html`, body: '' };
};
const handle = service.handle.bind(service);
service.handle = async (req, conn) => {
  if (req.url.startsWith('/') && PORT_SERVICE[req.port]) req.url = `${PORT_SERVICE[req.port]}:${req.url}`;
  // relogin needs no session (it sends the box to wtv-1800:/preregister, where it identifies itself):
  // answer it even when no box is known yet, instead of "400 Please reconnect"
  const known = req.headers['wtv-client-serial-number'] || conn.ssid || service.lastSsid;
  const relogin = /^wtv-head-waiter:\/relogin(\?|$)/.test(req.url);
  const r = (!known && relogin)
    ? await service.routes['wtv-head-waiter:/relogin'].call(service, { query: Object.fromEntries(new URLSearchParams(req.url.split('?')[1] || '')) })
    : await handle(req, conn);
  if (service.lastSsid && service.lastSsid !== (await store.get('lastSsid'))) await store.set('lastSsid', service.lastSsid);
  log(`wtvp ${req.method} ${JSON.stringify(req.url)} -> ${String(r.head).split('\n')[0]}`);
  return r;
};

net.createServer((sock) => {
  const who = `${sock.remoteAddress}:${sock.remotePort}`;
  log(`call from ${who}`);
  // A new call is a new login: forget the previous call's key exchange, so a box that comes back
  // straight to wtv-head-waiter:/login (without wtv-1800:/preregister, e.g. after losing its
  // secret) is sent through preregister instead of getting a challenge it can't answer -- the OS
  // asserts on that (Network::ProcessChallenge, "no secret").
  for (const s of service.sessions.values()) s.login = null;
  sock.setNoDelay(true);
  const line = createNetworkLine({ relayUrl: RELAY, service, hostMap: {}, log });
  let closed = false;
  const hang = (why) => {
    if (closed) return;
    closed = true;
    log(`hangup ${who} (${why})`);
    try { line.close(); } catch {}
    sock.destroy();
  };
  line.onData = (b) => { if (!closed) sock.write(Buffer.from([b])); };
  line.onClose = () => hang('PPP down');
  line.backlog = () => sock.writableLength;
  line.connect('mister');
  sock.on('data', (d) => { for (const b of d) line.send(b); });
  sock.on('close', () => hang('socket closed'));
  sock.on('error', (e) => hang(e.message));
}).listen(PORT, () => log(`WebTV line server on port ${PORT}${RELAY ? `, relay ${RELAY}` : ', built-in service only'}`));

process.on('uncaughtException', (e) => log(`uncaught: ${e.stack || e}`));
process.on('unhandledRejection', (e) => log(`unhandled rejection: ${e?.stack || e}`));
