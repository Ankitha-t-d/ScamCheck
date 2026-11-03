const express = require('express');
const cors = require('cors');
const { analyzeUrl } = require('./src/url');
const { analyzeMessage } = require('./src/message');

const app = express();
const PORT = process.env.PORT || 3000;
// Set ALLOWED_ORIGIN=http://<frontend-ip> in production. Defaults to any origin for local use.
const origins = (process.env.ALLOWED_ORIGIN || '*').split(',').map(s => s.trim());
app.use(cors({ origin: origins.includes('*') ? true : origins }));
app.use(express.json({ limit: '20kb' }));

const hits = new Map(); // in-memory rate limit: 60 requests per minute per IP
app.use('/api', (req, res, next) => {
  const now = Date.now(), e = hits.get(req.ip);
  if (!e || now > e.reset) hits.set(req.ip, { n: 1, reset: now + 60000 });
  else if (++e.n > 60) return res.status(429).json({ error: 'Too many requests. Try again in a minute.' });
  next();
});

app.get('/api/health', (_req, res) => res.json({ status: 'ok', time: new Date().toISOString() }));
const run = fn => (req, res) => { const r = fn(req.body.input); res.status(r.error ? 400 : 200).json(r); };
app.post('/api/analyze/url', run(analyzeUrl));
app.post('/api/analyze/message', run(analyzeMessage));
app.use((_req, res) => res.status(404).json({ error: 'Not found' }));

if (require.main === module) app.listen(PORT, '0.0.0.0', () => console.log(`ScamCheck API on port ${PORT}`));
module.exports = app;
