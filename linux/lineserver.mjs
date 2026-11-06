// WebTV MiSTer core: the network behind the modem. Each TCP connection is one phone call: the
// webtv-bridge network line (PPP server + IP gateway, src/net/line.js) answers it, with the
// built-in WebTV service (src/wtvsrv) and/or a relay to the real Internet.
//
// The MiSTer side (linux/webtv_modem.py --connect HOST:PORT) dials this when the box sends ATD and
// relays the modem's online data both ways.
//
//   node linux/lineserver.mjs [--port 2323] [--bridge PATH_TO_webtv-bridge] [--relay ws://host:8081]
//                             [--store FILE (default ~/.webtv-lineserver.json)] [--no-web]
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
const STORE = opt('store', join(homedir(), '.webtv-lineserver.json'));

const { createNetworkLine } = await import(join(BR, 'src/net/line.js'));
const { WebTVService } = await import(join(BR, 'src/wtvsrv/service.js'));

const ts = () => new Date().toISOString().slice(11, 23);
const log = (...a) => console.log(ts(), ...a);
const quiet = VERBOSE ? log : () => {};

// web pages (http/https proxied by the service): fetched by this host, unless --no-web
async function fetchUrl(url, { method = 'GET', headers = {}, body } = {}) {
  const h = { 'User-Agent': 'Mozilla/4.0 WebTV/2.8 (compatible; MSIE 4.0)' };
  if (headers['Content-Type']) h['Content-Type'] = headers['Content-Type'];
  const r = await fetch(url, { method, headers: h, body, redirect: 'follow', signal: AbortSignal.timeout(20000) });
  const out = new Uint8Array(await r.arrayBuffer());
  log(`web ${method} ${url} -> ${r.status} (${out.length} bytes)`);
  return { status: `${r.status} ${r.statusText || 'OK'}`, headers: { 'content-type': r.headers.get('content-type') || 'text/html' }, body: out };
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
const service = new WebTVService({ store: new FileStore(STORE), log: quiet, fetchUrl: args.includes('--no-web') ? null : fetchUrl });

// every request and its status line in the log (the service's own log is --verbose)
const handle = service.handle.bind(service);
service.handle = async (req, conn) => {
  const r = await handle(req, conn);
  log(`wtvp ${req.method} ${JSON.stringify(req.url)} -> ${String(r.head).split('\n')[0]}`);
  return r;
};

net.createServer((sock) => {
  const who = `${sock.remoteAddress}:${sock.remotePort}`;
  log(`call from ${who}`);
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
