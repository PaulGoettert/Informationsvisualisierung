import http from 'node:http';
import { readFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import path from 'node:path';

const publicDir = fileURLToPath(new URL('../public/', import.meta.url));
const port = Number(process.env.PORT || 8000);
const files = new Map([
  ['/', ['index.html', 'text/html; charset=utf-8']],
  ['/index.html', ['index.html', 'text/html; charset=utf-8']],
  ['/styles.css', ['styles.css', 'text/css; charset=utf-8']],
  ['/elm.js', ['elm.js', 'application/javascript; charset=utf-8']]
]);
const server = http.createServer(async (req, res) => {
  const entry = files.get(new URL(req.url, 'http://localhost').pathname);
  if (!entry || req.method !== 'GET') { res.writeHead(404); res.end('Nicht gefunden'); return; }
  try {
    const body = await readFile(path.join(publicDir, entry[0]));
    res.writeHead(200, { 'Content-Type': entry[1], 'Cache-Control': 'no-store' });
    res.end(body);
  } catch { res.writeHead(500); res.end('Bitte zuerst npm run build ausführen.'); }
});
server.listen(port, '127.0.0.1', () => console.log(`Anwendung: http://127.0.0.1:${port}`));
process.on('SIGTERM', () => server.close());
