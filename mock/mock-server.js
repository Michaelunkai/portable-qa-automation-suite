'use strict';
const http = require('node:http');
const port = Number(process.env.QA_MOCK_PORT || 8765);
const server = http.createServer((req, res) => {
  if (req.url === '/api' || req.url === '/health') {
    res.writeHead(200, { 'content-type': 'application/json; charset=utf-8', 'cache-control': 'no-store' });
    res.end(JSON.stringify({ ok: true, items: [{ id: 1, name: 'sample' }] }));
    return;
  }
  res.writeHead(200, { 'content-type': 'text/html; charset=utf-8', 'cache-control': 'no-store' });
  const body = req.url === '/about'
    ? '<!doctype html><html lang="en"><head><meta charset="utf-8"><title>QA Mock About</title></head><body><main><h1>About</h1><p>Accessible mock page.</p><a href="/">Home</a></main></body></html>'
    : '<!doctype html><html lang="en"><head><meta charset="utf-8"><title>QA Mock</title></head><body><header><h1>QA Mock</h1></header><main><p>Local portable QA smoke target.</p><a href="/about">About page</a><button type="button" aria-label="Check status">Status</button></main></body></html>';
  res.end(body);
});
server.listen(port, '127.0.0.1', () => process.stdout.write('ready:' + port + '\n'));
process.on('SIGTERM', () => server.close(() => process.exit(0)));
