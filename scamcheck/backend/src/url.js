const { verdict } = require('./score');

const LEGIT = {
  paypal: ['paypal.com'], google: ['google.com', 'google.co.in'], amazon: ['amazon.com', 'amazon.in'],
  flipkart: ['flipkart.com'], paytm: ['paytm.com'], phonepe: ['phonepe.com'], hdfc: ['hdfcbank.com'],
  icici: ['icicibank.com'], axis: ['axisbank.com'], irctc: ['irctc.co.in'], microsoft: ['microsoft.com'],
  netflix: ['netflix.com'], facebook: ['facebook.com'], instagram: ['instagram.com'],
  whatsapp: ['whatsapp.com'], sbi: ['sbi.co.in', 'onlinesbi.sbi', 'sbi.bank.in']
};
const BAD_TLDS = new Set(['zip', 'xyz', 'top', 'click', 'tk', 'ml', 'cf', 'ga', 'gq', 'work', 'support', 'icu', 'buzz', 'loan', 'rest']);
const SHORTENERS = new Set(['bit.ly', 'tinyurl.com', 't.co', 'goo.gl', 'is.gd', 'cutt.ly', 'rb.gy', 'shorturl.at', 'ow.ly']);
const WORDS = ['login', 'verify', 'update', 'secure', 'account', 'confirm', 'kyc', 'otp', 'password', 'wallet', 'reward', 'claim', 'gift', 'suspend', 'unlock', 'refund'];
const TWO_LEVEL = new Set(['co.in', 'org.in', 'gov.in', 'ac.in', 'net.in', 'co.uk', 'com.au', 'co.jp']);

function registrable(host) {
  const p = host.split('.');
  if (p.length <= 2) return host;
  return TWO_LEVEL.has(p.slice(-2).join('.')) ? p.slice(-3).join('.') : p.slice(-2).join('.');
}
function lev(a, b) {
  const d = Array.from({ length: a.length + 1 }, (_, i) => [i]);
  for (let j = 1; j <= b.length; j++) d[0][j] = j;
  for (let i = 1; i <= a.length; i++)
    for (let j = 1; j <= b.length; j++)
      d[i][j] = Math.min(d[i - 1][j] + 1, d[i][j - 1] + 1, d[i - 1][j - 1] + (a[i - 1] === b[j - 1] ? 0 : 1));
  return d[a.length][b.length];
}

function analyzeUrl(raw) {
  raw = String(raw || '').trim();
  if (!raw || raw.length > 2048) return { error: 'Enter a link up to 2048 characters long.' };
  const hadScheme = /^[a-z][a-z0-9+.-]*:\/\//i.test(raw);
  let u;
  try { u = new URL(hadScheme ? raw : 'http://' + raw); } catch { return { error: 'That does not look like a valid link.' }; }
  if (!['http:', 'https:'].includes(u.protocol)) return { error: 'Only http and https links can be checked.' };

  const host = u.hostname.toLowerCase().replace(/\.$/, '');
  const reg = registrable(host);
  const sld = reg.split('.')[0];
  const tld = host.split('.').pop();
  const findings = [];
  let score = 0;
  const add = (points, severity, title, detail) => { score += points; findings.push({ severity, title, detail, points }); };

  if (hadScheme && u.protocol === 'http:') add(12, 'low', 'Not encrypted', 'The link uses http, so data you enter can be read on the network.');
  if (/^\d{1,3}(\.\d{1,3}){3}$/.test(host) || host.startsWith('[')) add(30, 'high', 'Uses a raw IP address', 'Genuine services use a domain name, not a number.');
  if (u.username) add(25, 'high', 'Contains an @ sign', 'Text before the @ is ignored by browsers, so the real site is hidden after it.');
  if (host.includes('xn--')) add(25, 'high', 'Look-alike characters', 'The domain uses encoded characters that can imitate a real brand.');
  if (SHORTENERS.has(host)) add(20, 'medium', 'Shortened link', 'The real destination is hidden. Expand it before opening.');
  if (BAD_TLDS.has(tld)) add(15, 'medium', `Unusual ending ".${tld}"`, 'This ending is common on throwaway scam domains.');
  const subs = host.split('.').length - reg.split('.').length;
  if (subs >= 3) add(15, 'medium', 'Many subdomains', 'Long chains of subdomains are used to hide the real domain.');
  if (host.length > 30) add(8, 'low', 'Very long domain name', `The domain has ${host.length} characters.`);
  if ((host.match(/-/g) || []).length >= 3) add(10, 'medium', 'Many hyphens in the domain', 'Scam domains often chain words together with hyphens.');
  if ((sld.match(/\d/g) || []).length / sld.length > 0.3) add(10, 'medium', 'Many digits in the domain', 'Digits often replace letters in fake domains.');
  if (u.port && !['80', '443'].includes(u.port)) add(10, 'medium', `Unusual port ${u.port}`, 'Real websites rarely use custom ports.');

  const text = (host + u.pathname).toLowerCase();
  const hits = WORDS.filter(w => text.includes(w));
  if (hits.length) add(Math.min(20, hits.length * 6), 'medium', 'Bait words in the link', `Contains: ${hits.join(', ')}.`);

  const tokens = host.split(/[.-]/);
  const flagged = new Set();
  for (const [brand, domains] of Object.entries(LEGIT)) {
    const official = domains.some(d => host === d || host.endsWith('.' + d));
    const mentions = tokens.some(t => t === brand || t.startsWith(brand) || t.endsWith(brand) || (brand.length >= 5 && t.includes(brand)));
    if (mentions && !official) { flagged.add(brand); add(35, 'high', `Pretends to be ${brand}`, `The name appears in "${host}", but the real site is ${domains[0]}.`); }
  }
  for (const brand of Object.keys(LEGIT)) {
    if (brand.length < 5 || flagged.has(brand)) continue;
    const d = lev(sld, brand);
    if (d >= 1 && d <= 2 && !LEGIT[brand].includes(reg)) add(35, 'high', `Misspelling of ${brand}`, `"${sld}" is ${d} character${d > 1 ? 's' : ''} away from "${brand}".`);
  }
  if (u.href.length > 100) add(5, 'low', 'Very long link', 'Long links can hide the real destination.');

  const v = verdict(score);
  return {
    type: 'url', input: raw, host, ...v, findings,
    advice: v.level === 'safe'
      ? ['No warning signs found, but this is a rule-based check. Type official addresses yourself instead of following links.']
      : ['Do not enter passwords, card details or OTPs on this page.', 'Open the service by typing its official address or using its app.']
  };
}
module.exports = { analyzeUrl };
