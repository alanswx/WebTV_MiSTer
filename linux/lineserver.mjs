// WebTV MiSTer core: the network behind the modem. Each TCP connection is one phone call: the
// webtv-bridge network line (PPP server + IP gateway, src/net/line.js) answers it, with the
// built-in WebTV service (src/wtvsrv) and/or a relay to the real Internet.
//
// The MiSTer side (linux/webtv_modem.py --connect HOST:PORT) dials this when the box sends ATD and
// relays the modem's online data both ways.
//
//   node linux/lineserver.mjs [--port 2323] [--bridge PATH_TO_webtv-bridge] [--relay ws://host:8081]
//
// Without --relay the line answers with the built-in service only (registration / home pages).
import net from 'node:net';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const args = process.argv.slice(2);
const opt = (n, d) => { const i = args.indexOf('--' + n); return i >= 0 ? args[i + 1] : d; };
const HERE = dirname(fileURLToPath(import.meta.url));
const BR = opt('bridge', join(HERE, '../ext/webtv-bridge'));
const PORT = Number(opt('port', '2323'));
const RELAY = opt('relay', null);
const VERBOSE = args.includes('--verbose');

const { createNetworkLine } = await import(join(BR, 'src/net/line.js'));
const { WebTVService } = await import(join(BR, 'src/wtvsrv/service.js'));

const ts = () => new Date().toISOString().slice(11, 23);
const log = (...a) => console.log(ts(), ...a);
const quiet = VERBOSE ? log : () => {};

// one service for all calls: registrations and sessions persist between calls
const service = new WebTVService({ log: quiet });

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
