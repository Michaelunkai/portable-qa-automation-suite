'use strict';

const http = require('node:http');
const port = Number(process.env.QA_MOCK_PORT || 8765);

const server = http.createServer((req, res) => {
  const route = new URL(req.url, 'http://127.0.0.1').pathname;
  if (route === '/api' || route === '/health') {
    res.writeHead(200, { 'content-type': 'application/json; charset=utf-8', 'cache-control': 'no-store' });
    res.end(JSON.stringify({ ok: true, items: [{ id: 1, name: 'sample' }] }));
    return;
  }
  if (route === '/contrast') {
    res.writeHead(200, { 'content-type': 'text/html; charset=utf-8', 'cache-control': 'no-store' });
    res.end('<!doctype html><html lang="en"><head><meta charset="utf-8"><title>QA Contrast Fixture</title></head><body><main><h1>Contrast fixture</h1><p style="color:#aaa;background:#fff">Intentionally low contrast.</p></main></body></html>');
    return;
  }
  if (route === '/browser-404') {
    res.writeHead(200, { 'content-type': 'text/html; charset=utf-8', 'cache-control': 'no-store' });
    res.end('<!doctype html><html lang="en"><head><meta charset="utf-8"><title>QA Browser 404 Fixture</title></head><body><main><h1>Browser 404 fixture</h1><p>The link below intentionally returns HTTP 404.</p><a href="/missing-404">Missing route</a></main></body></html>');
    return;
  }
  if (route === '/console-error') {
    res.writeHead(200, { 'content-type': 'text/html; charset=utf-8', 'cache-control': 'no-store' });
    res.end('<!doctype html><html lang="en"><head><meta charset="utf-8"><title>QA Console Error Fixture</title></head><body><main><h1>Console error fixture</h1><script>console.error("QA_FIXTURE_CONSOLE_ERROR")</script></main></body></html>');
    return;
  }
  if (route === '/missing-404') {
    res.writeHead(404, { 'content-type': 'text/html; charset=utf-8', 'cache-control': 'no-store' });
    res.end('<!doctype html><html lang="en"><head><meta charset="utf-8"><title>QA Missing Route</title></head><body><main><h1>Not found</h1><p>This route is intentionally missing.</p></main></body></html>');
    return;
  }
  if (route === '/server-error') {
    res.writeHead(500, { 'content-type': 'text/html; charset=utf-8', 'cache-control': 'no-store' });
    res.end('<!doctype html><html lang="en"><head><meta charset="utf-8"><title>QA HTTP error fixture</title></head><body><main><h1>Local HTTP error fixture</h1><p>Intentional server error response.</p></main></body></html>');
    return;
  }
  res.writeHead(200, { 'content-type': 'text/html; charset=utf-8', 'cache-control': 'no-store' });
  const body = route === '/about'
    ? '<!doctype html><html lang="en"><head><meta charset="utf-8"><title>QA Mock About</title></head><body><main><h1>About</h1><p>Accessible mock page.</p><a href="/">Home</a></main></body></html>'
    : '<!doctype html><html lang="en"><head><meta charset="utf-8"><title>QA Mock</title></head><body><header><h1>QA Mock</h1></header><main><p>Local portable QA smoke target.</p><a href="/about">About page</a><button type="button" aria-label="Check status">Status</button></main></body></html>';
  res.end(body);
});

server.listen(port, '127.0.0.1', () => process.stdout.write('ready:' + server.address().port + '\n'));
process.on('SIGTERM', () => server.close(() => process.exit(0)));
