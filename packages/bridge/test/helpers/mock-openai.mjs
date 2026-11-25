import http from 'node:http';

export async function startMockOpenAiServer() {
  const requests = [];
  let behavior = { mode: 'ok', title: '模拟摘要标题', delayMs: 0 };

  const server = http.createServer(async (req, res) => {
    const chunks = [];
    for await (const c of req) chunks.push(c);
    const bodyText = Buffer.concat(chunks).toString('utf8');
    let parsed = null;
    try {
      parsed = JSON.parse(bodyText);
    } catch {
      // ignore
    }
    requests.push({
      method: req.method,
      url: req.url,
      headers: req.headers,
      bodyText,
      bodyBytes: Buffer.byteLength(bodyText, 'utf8'),
      body: parsed,
    });

    if (behavior.delayMs > 0) {
      await new Promise((r) => setTimeout(r, behavior.delayMs));
    }

    if (behavior.mode === 'http_500') {
      res.writeHead(500, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ error: 'boom' }));
      return;
    }

    const content =
      behavior.mode === 'think_only'
        ? '<think>reasoning only without final text</think>'
        : behavior.title;

    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(
      JSON.stringify({
        choices: [{ message: { content } }],
      })
    );
  });

  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  const addr = server.address();
  return {
    port: addr.port,
    baseUrl: `http://127.0.0.1:${addr.port}/v1`,
    requests,
    setBehavior(next) {
      behavior = { ...behavior, ...next };
    },
    async close() {
      server.closeAllConnections?.();
      await new Promise((resolve) => server.close(resolve));
    },
  };
}
