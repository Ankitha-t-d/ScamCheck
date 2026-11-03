const API = ((window.APP_CONFIG || {}).API_BASE || '').replace(/\/$/, '');
const $ = s => document.querySelector(s);
const result = $('#result'), go = $('#go');
let tab = 'message';

const EXAMPLES = {
  message: [
    ['Bank KYC scam', 'Dear customer, your SBI account will be blocked today. Update KYC immediately: http://sbi-kyc-update.top/login'],
    ['Digital arrest', 'This is CBI. A parcel in your name has narcotics. Call +91 9876543210 now to avoid arrest.'],
    ['Genuine OTP', '482913 is your OTP for login. Do not share it with anyone.']
  ],
  url: [
    ['Fake bank', 'http://hdfcbank-kyc-update.xyz/login'],
    ['Look-alike', 'https://paypa1.com/verify'],
    ['Official site', 'https://www.irctc.co.in']
  ],
  password: [['Weak', 'rahul2004'], ['Common', 'password123'], ['Strong', 'correct-horse-7-staple-Mango']]
};
const LABEL = { message: 'Check message', url: 'Check link', password: 'Check password' };

function el(tag, cls, text) {
  const e = document.createElement(tag);
  if (cls) e.className = cls;
  if (text !== undefined) e.textContent = text;
  return e;
}

function setTab(t) {
  tab = t;
  document.querySelectorAll('.tabs button').forEach(b => b.setAttribute('aria-selected', b.dataset.tab === t));
  ['message', 'url', 'password'].forEach(n => { $('#panel-' + n).hidden = n !== t; });
  go.textContent = LABEL[t];
  const box = $('#examples');
  box.replaceChildren(document.createTextNode('Try: '));
  EXAMPLES[t].forEach(([name, value]) => {
    const b = el('button', '', name);
    b.type = 'button';
    b.onclick = () => { $('#in-' + t).value = value; run(); };
    box.append(b);
  });
}
document.querySelectorAll('.tabs button').forEach(b => b.onclick = () => setTab(b.dataset.tab));

function verdictBox(r, sub) {
  const v = el('div', 'verdict ' + r.level);
  v.append(el('h2', '', `${r.label} (${r.score}/100)`));
  const m = el('div', 'meter'), i = el('i');
  i.style.width = '0%'; m.append(i); v.append(m);
  if (sub) v.append(el('small', '', sub));
  requestAnimationFrame(() => { i.style.width = r.score + '%'; });
  return v;
}

function highlighted(text, marks) {
  const p = el('p', 'bubble');
  let pos = 0;
  [...marks].sort((a, b) => a.start - b.start).forEach(m => {
    if (m.start < pos) return;
    p.append(document.createTextNode(text.slice(pos, m.start)));
    const k = el('mark', '', text.slice(m.start, m.end));
    k.title = m.label;
    p.append(k);
    pos = m.end;
  });
  p.append(document.createTextNode(text.slice(pos)));
  return p;
}

function findingsList(title, items, empty) {
  const f = document.createDocumentFragment();
  f.append(el('h3', '', title));
  if (!items.length) { f.append(el('p', 'empty', empty)); return f; }
  const ul = el('ul', 'list');
  items.forEach(x => {
    const li = el('li', x.severity);
    li.append(el('b', '', x.title), el('span', '', x.detail));
    ul.append(li);
  });
  f.append(ul);
  return f;
}

function tips(list) {
  const f = document.createDocumentFragment();
  f.append(el('h3', '', 'What to do'));
  const ul = el('ul', 'tips');
  list.forEach(t => ul.append(el('li', '', t)));
  f.append(ul);
  return f;
}

function show(...nodes) { result.replaceChildren(...nodes); }

async function callApi(kind, input) {
  const res = await fetch(`${API}/api/analyze/${kind}`, {
    method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ input })
  });
  const data = await res.json().catch(() => ({ error: 'Unexpected reply from server.' }));
  if (!res.ok) throw new Error(data.error || 'Request failed.');
  return data;
}

async function run() {
  const input = $('#in-' + tab).value;
  if (!input.trim()) { show(el('p', 'err', 'Enter something to check first.')); return; }
  if (tab === 'password') return showPassword(input);
  go.disabled = true;
  try {
    const r = await callApi(tab, input);
    const nodes = [verdictBox(r)];
    if (tab === 'message') nodes.push(highlighted(input.trim(), r.highlights));
    else nodes.push(el('p', 'note', 'Domain checked: ' + r.host));
    nodes.push(findingsList('Why', r.findings, 'No warning signs were found.'), tips(r.advice));
    show(...nodes);
  } catch (e) {
    show(el('p', 'err', e.message === 'Failed to fetch' ? 'Cannot reach the server. Check that the backend is running and config.js points to it.' : e.message));
  } finally { go.disabled = false; }
}
go.onclick = run;
['in-url', 'in-password'].forEach(id => $('#' + id).addEventListener('keydown', e => { if (e.key === 'Enter') run(); }));

// ---- Password check (runs only in the browser) ----
const COMMON = ['password', 'password1', 'password123', '123456', '12345678', '123456789', 'qwerty', 'qwerty123', 'admin', 'welcome', 'iloveyou', 'abc123', 'letmein', 'india123', 'sachin', 'dragon', 'monkey', 'football', 'cricket', 'passw0rd'];
function fmt(sec) {
  if (sec < 1) return 'instantly';
  const u = [['years', 31557600], ['days', 86400], ['hours', 3600], ['minutes', 60], ['seconds', 1]];
  for (const [n, s] of u) if (sec >= s) { const v = sec / s; return v > 1e6 && n === 'years' ? 'millions of years' : `about ${Math.round(v).toLocaleString()} ${n}`; }
}
function showPassword(p) {
  const found = [];
  const lower = p.toLowerCase().replace(/[^a-z0-9]/g, '');
  let pool = 0;
  if (/[a-z]/.test(p)) pool += 26;
  if (/[A-Z]/.test(p)) pool += 26;
  if (/\d/.test(p)) pool += 10;
  if (/[^A-Za-z0-9]/.test(p)) pool += 32;
  let bits = p.length * Math.log2(pool || 1);
  if (p.length < 12) found.push({ severity: p.length < 8 ? 'high' : 'medium', title: `Only ${p.length} characters`, detail: 'Aim for 12 or more. Length matters more than symbols.' });
  if (COMMON.some(c => lower === c || lower.startsWith(c))) { bits = Math.min(bits, 12); found.push({ severity: 'high', title: 'Appears in common password lists', detail: 'Attackers try these first.' }); }
  if (/(.)\1{2,}/.test(p)) { bits *= .8; found.push({ severity: 'medium', title: 'Repeated characters', detail: 'Patterns like "aaa" are easy to guess.' }); }
  if (/(0123|1234|2345|3456|4567|5678|6789|abcd|bcde|qwer|asdf)/i.test(p)) { bits *= .7; found.push({ severity: 'medium', title: 'Keyboard or number sequence', detail: 'Sequences are among the first guesses.' }); }
  if (/(19|20)\d{2}/.test(p)) { bits -= 8; found.push({ severity: 'medium', title: 'Contains a year', detail: 'Birth years are easy to guess.' }); }
  if (/^[a-zA-Z]+\d{1,4}$/.test(p)) { bits -= 6; found.push({ severity: 'low', title: 'Word followed by digits', detail: 'The most common password shape.' }); }
  bits = Math.max(bits, 0);
  const seconds = Math.pow(2, bits) / 1e10 / 2; // offline attack, 10 billion guesses per second
  const score = Math.min(100, Math.round(bits / 70 * 100));
  const r = score >= 70 ? { level: 'safe', label: 'Strong', score } : score >= 40 ? { level: 'suspicious', label: 'Fair', score } : { level: 'dangerous', label: 'Weak', score };
  show(verdictBox(r, `Estimated time to crack offline: ${fmt(seconds)}`),
    findingsList('Why', found, 'No common weaknesses found.'),
    tips(['Use a passphrase of 4 or more random words, or a password manager.', 'Use a different password for every account.', 'Turn on two-step verification for email and banking.']));
}

// ---- Server status ----
fetch(`${API}/api/health`).then(r => r.json()).then(() => {
  $('#status').textContent = 'Server online'; $('#status').classList.add('ok');
}).catch(() => {
  $('#status').textContent = 'Server unreachable'; $('#status').classList.add('down');
});
setTab('message');
