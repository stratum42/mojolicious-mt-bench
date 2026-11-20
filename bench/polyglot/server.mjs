import cluster from 'node:cluster';
import fs from 'node:fs';
import http from 'node:http';
import net from 'node:net';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

function parseArgs(argv) {
  const opts = {
    port: parseInt(process.env.PORT || '3000', 10),
    workers: parseInt(process.env.WORKERS || '8', 10),
    keydbPort: process.env.MOJO_KEYDB_PORT ? parseInt(process.env.MOJO_KEYDB_PORT, 10) : 0,
    publicDir: process.env.PUBLIC_DIR || path.resolve(__dirname, '..', 'public'),
  };
  for (let i = 2; i < argv.length; i++) {
    const a = argv[i];
    if (a === '--port' && argv[i + 1]) opts.port = parseInt(argv[++i], 10);
    else if (a === '--workers' && argv[i + 1]) opts.workers = parseInt(argv[++i], 10);
    else if (a === '--keydb-port' && argv[i + 1]) opts.keydbPort = parseInt(argv[++i], 10);
    else if (a === '--public-dir' && argv[i + 1]) opts.publicDir = argv[++i];
  }
  return opts;
}

const OPTS = parseArgs(process.argv);

function ensureStaticAsset(publicDir) {
  const assetPath = path.join(publicDir, 'static', 'payload.txt');
  let needsWrite = true;
  try {
    const st = fs.statSync(assetPath);
    if (st.isFile() && st.size === 16384) needsWrite = false;
  } catch {
    needsWrite = true;
  }
  if (needsWrite) {
    fs.mkdirSync(path.dirname(assetPath), { recursive: true });
    const line = '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcde\n';
    fs.writeFileSync(assetPath, line.repeat(256));
  }
}

function buildJsonPayload() {
  const items = [];
  for (let i = 1; i <= 50; i++) {
    items.push({
      id: i,
      name: `Benchmark User ${i}`,
      email: `user${i}@example.com`,
      role: i % 5 === 0 ? 'admin' : 'member',
      active: i % 3 !== 0,
      score: 10.5 + i * 1.25,
      tags: ['perf', 'mojo', `tier-${i % 4}`],
      meta: { region: i % 2 ? 'us-east' : 'eu-west', rev: i },
    });
  }
  return { status: 'ok', count: items.length, items };
}

function buildTemplateRows() {
  const rows = [];
  for (let i = 1; i <= 25; i++) {
    rows.push({
      id: i,
      title: `Item #${i} <script>alert("xss&${i}")</script> & 'quotes'`,
      owner: `User <u${i}@example.com> & "Team ${i}"`,
      note: `Value > 0 && Value < 100 ("ok" / 'checked')`,
      score: (50 + i * 1.75).toFixed(2),
    });
  }
  return rows;
}

const HTML_ESC_RE = /[&<>"']/g;
const HTML_ESC_MAP = {
  '&': '&amp;',
  '<': '&lt;',
  '>': '&gt;',
  '"': '&quot;',
  "'": '&#39;',
};
function escapeHtml(s) {
  return String(s).replace(HTML_ESC_RE, (ch) => HTML_ESC_MAP[ch]);
}

function renderTemplate(title, rows) {
  const escTitle = escapeHtml(title);
  let out =
    '<!DOCTYPE html>\n<html>\n<head><title>' +
    escTitle +
    '</title></head>\n<body>\n<h1>' +
    escTitle +
    '</h1>\n<table>\n<thead><tr><th>ID</th><th>Title</th><th>Owner</th><th>Note</th><th>Score</th></tr></thead>\n<tbody>\n';
  for (let i = 0; i < rows.length; i++) {
    const r = rows[i];
    out +=
      '<tr><td>' +
      escapeHtml(r.id) +
      '</td><td>' +
      escapeHtml(r.title) +
      '</td><td>' +
      escapeHtml(r.owner) +
      '</td><td>' +
      escapeHtml(r.note) +
      '</td><td>' +
      escapeHtml(r.score) +
      '</td></tr>\n';
  }
  out += '</tbody>\n</table>\n</body>\n</html>\n';
  return out;
}

// Persistent RESP2 TCP client with pipelined/queued FIFO response parser
class Resp2Client {
  constructor(host, port) {
    this.host = host;
    this.port = port;
    this.sock = null;
    this.buf = Buffer.alloc(0);
    this.queue = [];
    this.connecting = false;
  }

  _ensureSocket() {
    if (this.sock && !this.sock.destroyed) return this.sock;
    const sock = net.createConnection({ host: this.host, port: this.port });
    sock.setNoDelay(true);
    this.sock = sock;
    this.buf = Buffer.alloc(0);

    sock.on('data', (chunk) => {
      this.buf = this.buf.length === 0 ? chunk : Buffer.concat([this.buf, chunk]);
      this._drainResponses();
    });

    const onFail = (err) => {
      if (this.sock === sock) this.sock = null;
      const pending = this.queue.splice(0, this.queue.length);
      for (const item of pending) item.reject(err || new Error('RESP2 socket closed'));
    };
    sock.on('error', onFail);
    sock.on('close', () => onFail(new Error('RESP2 socket closed')));
    return sock;
  }

  _drainResponses() {
    let offset = 0;
    const buf = this.buf;
    const len = buf.length;

    while (offset < len && this.queue.length > 0) {
      const prefix = buf[offset];
      const crlf = buf.indexOf('\r\n', offset + 1);
      if (crlf === -1) break;

      if (prefix === 43 /* '+' */) {
        const val = buf.toString('utf8', offset + 1, crlf);
        offset = crlf + 2;
        this.queue.shift().resolve(val);
      } else if (prefix === 58 /* ':' */) {
        const val = parseInt(buf.toString('ascii', offset + 1, crlf), 10);
        offset = crlf + 2;
        this.queue.shift().resolve(val);
      } else if (prefix === 45 /* '-' */) {
        const msg = buf.toString('utf8', offset + 1, crlf);
        offset = crlf + 2;
        this.queue.shift().reject(new Error(msg));
      } else if (prefix === 36 /* '$' */) {
        const blen = parseInt(buf.toString('ascii', offset + 1, crlf), 10);
        if (blen === -1) {
          offset = crlf + 2;
          this.queue.shift().resolve(null);
        } else {
          const end = crlf + 2 + blen;
          if (end + 2 > len) break;
          const val = buf.toString('utf8', crlf + 2, end);
          offset = end + 2;
          this.queue.shift().resolve(val);
        }
      } else {
        const err = new Error(`Unexpected RESP2 prefix byte: ${prefix}`);
        offset = len;
        const pending = this.queue.splice(0, this.queue.length);
        for (const item of pending) item.reject(err);
        if (this.sock) this.sock.destroy();
        break;
      }
    }

    if (offset > 0) {
      this.buf = offset >= len ? Buffer.alloc(0) : buf.subarray(offset);
    }
  }

  command(...args) {
    return new Promise((resolve, reject) => {
      const sock = this._ensureSocket();
      let payload = `*${args.length}\r\n`;
      for (let i = 0; i < args.length; i++) {
        const s = String(args[i]);
        payload += `$${Buffer.byteLength(s)}\r\n${s}\r\n`;
      }
      this.queue.push({ resolve, reject });
      sock.write(payload);
    });
  }
}

function startWorker(opts) {
  const JSON_PAYLOAD = buildJsonPayload();
  const TEMPLATE_ROWS = buildTemplateRows();
  const TEMPLATE_TITLE = 'Benchmark <Report> & "Stats"';
  const LOCAL_CACHE = new Map();
  const STATIC_CACHE = new Map();
  const STATIC_CACHE_MAX_SIZE = 65536;
  const keydb = opts.keydbPort ? new Resp2Client('127.0.0.1', opts.keydbPort) : null;
  const publicRoot = path.resolve(opts.publicDir);

  const PLAINTEXT_BUF = Buffer.from('Hello, World!');

  const server = http.createServer((req, res) => {
    const method = req.method;
    const rawUrl = req.url || '/';
    const qIdx = rawUrl.indexOf('?');
    const pathname = qIdx === -1 ? rawUrl : rawUrl.slice(0, qIdx);

    // 1. GET /plaintext
    if (method === 'GET' && pathname === '/plaintext') {
      res.writeHead(200, {
        'Content-Type': 'text/plain;charset=UTF-8',
        'Content-Length': PLAINTEXT_BUF.length,
      });
      res.end(PLAINTEXT_BUF);
      return;
    }

    // 2. GET /json
    if (method === 'GET' && pathname === '/json') {
      const body = Buffer.from(JSON.stringify(JSON_PAYLOAD));
      res.writeHead(200, {
        'Content-Type': 'application/json;charset=UTF-8',
        'Content-Length': body.length,
      });
      res.end(body);
      return;
    }

    // 3. POST /json
    if (method === 'POST' && pathname === '/json') {
      const chunks = [];
      req.on('data', (c) => chunks.push(c));
      req.on('end', () => {
        let data;
        try {
          data = JSON.parse(Buffer.concat(chunks).toString('utf8'));
        } catch {
          const errBody = Buffer.from('{"error":"invalid json"}');
          res.writeHead(400, {
            'Content-Type': 'application/json;charset=UTF-8',
            'Content-Length': errBody.length,
          });
          res.end(errBody);
          return;
        }
        if (!data || typeof data !== 'object' || Array.isArray(data)) {
          const errBody = Buffer.from('{"error":"invalid json"}');
          res.writeHead(400, {
            'Content-Type': 'application/json;charset=UTF-8',
            'Content-Length': errBody.length,
          });
          res.end(errBody);
          return;
        }
        const items = Array.isArray(data.items) ? data.items : [];
        const count = items.length;
        let sum = 0;
        for (let i = 0; i < count; i++) {
          const sc = items[i] && typeof items[i].score === 'number' ? items[i].score : 0;
          sum += sc;
        }
        const body = Buffer.from(
          JSON.stringify({ status: 'ok', count, checksum: Math.floor(sum * 100 + 0.5) }),
        );
        res.writeHead(200, {
          'Content-Type': 'application/json;charset=UTF-8',
          'Content-Length': body.length,
        });
        res.end(body);
      });
      return;
    }

    // 4. GET /template
    if (method === 'GET' && pathname === '/template') {
      const body = Buffer.from(renderTemplate(TEMPLATE_TITLE, TEMPLATE_ROWS));
      res.writeHead(200, {
        'Content-Type': 'text/html;charset=UTF-8',
        'Content-Length': body.length,
      });
      res.end(body);
      return;
    }

    // 5. GET /static/*
    if ((method === 'GET' || method === 'HEAD') && pathname.startsWith('/static/')) {
      const rel = pathname.slice(1);
      if (rel.includes('..') || rel.includes('\\')) {
        res.writeHead(404);
        res.end('Not Found');
        return;
      }
      const fullPath = path.join(publicRoot, rel);
      let st;
      try {
        st = fs.statSync(fullPath);
      } catch {
        res.writeHead(404);
        res.end('Not Found');
        return;
      }
      if (!st.isFile()) {
        res.writeHead(404);
        res.end('Not Found');
        return;
      }
      let entry = STATIC_CACHE.get(fullPath);
      if (!entry || entry.mtimeMs !== st.mtimeMs || entry.size !== st.size) {
        const content = fs.readFileSync(fullPath);
        entry = {
          mtimeMs: st.mtimeMs,
          size: st.size,
          content,
          etag: `"${st.size.toString(16)}-${Math.floor(st.mtimeMs).toString(16)}"`,
          lastModified: st.mtime.toUTCString(),
        };
        if (st.size <= STATIC_CACHE_MAX_SIZE) {
          STATIC_CACHE.set(fullPath, entry);
        }
      }
      res.writeHead(200, {
        'Content-Type': 'text/plain;charset=UTF-8',
        'Content-Length': entry.size,
        'Accept-Ranges': 'bytes',
        ETag: entry.etag,
        'Last-Modified': entry.lastModified,
      });
      res.end(method === 'HEAD' ? undefined : entry.content);
      return;
    }

    // 6. GET /cache/:key (per-worker Map; cluster workers cannot share in-process memory)
    if (method === 'GET' && pathname.startsWith('/cache/')) {
      const key = pathname.slice('/cache/'.length);
      let val = LOCAL_CACHE.get(key);
      if (val === undefined) {
        val = `cached:${key}:v1`;
        LOCAL_CACHE.set(key, val);
      }
      const body = Buffer.from(JSON.stringify({ key, value: val, shared: false }));
      res.writeHead(200, {
        'Content-Type': 'application/json;charset=UTF-8',
        'Content-Length': body.length,
      });
      res.end(body);
      return;
    }

    // 7. GET /keydb/:key
    if (method === 'GET' && pathname.startsWith('/keydb/')) {
      if (!keydb) {
        const errBody = Buffer.from('{"error":"MOJO_KEYDB_PORT not configured"}');
        res.writeHead(503, {
          'Content-Type': 'application/json;charset=UTF-8',
          'Content-Length': errBody.length,
        });
        res.end(errBody);
        return;
      }
      const key = pathname.slice('/keydb/'.length);
      (async () => {
        const count = await keydb.command('INCR', `bench:cnt:${key}`);
        let val = await keydb.command('GET', `bench:val:${key}`);
        if (val === null) {
          val = `keydb:${key}:v1`;
          await keydb.command('SET', `bench:val:${key}`, val);
        }
        const body = Buffer.from(JSON.stringify({ key, value: val, count, xs: false }));
        res.writeHead(200, {
          'Content-Type': 'application/json;charset=UTF-8',
          'Content-Length': body.length,
        });
        res.end(body);
      })().catch((err) => {
        const errBody = Buffer.from(JSON.stringify({ error: err.message }));
        res.writeHead(500, {
          'Content-Type': 'application/json;charset=UTF-8',
          'Content-Length': errBody.length,
        });
        res.end(errBody);
      });
      return;
    }

    res.writeHead(404, { 'Content-Type': 'text/plain;charset=UTF-8' });
    res.end('Not Found');
  });

  server.keepAliveTimeout = 60000;
  server.maxRequestsPerSocket = 0;

  server.listen(opts.port, '127.0.0.1');
}

if (cluster.isPrimary) {
  ensureStaticAsset(OPTS.publicDir);

  let shuttingDown = false;
  const shutdown = () => {
    if (shuttingDown) return;
    shuttingDown = true;
    for (const id of Object.keys(cluster.workers)) {
      const w = cluster.workers[id];
      if (w) w.kill('SIGTERM');
    }
    setTimeout(() => process.exit(0), 200).unref();
  };
  process.on('SIGTERM', shutdown);
  process.on('SIGINT', shutdown);

  const count = Math.max(1, OPTS.workers);
  for (let i = 0; i < count; i++) {
    cluster.fork();
  }
} else {
  startWorker(OPTS);
}
