const { analyzeUrl } = require('./url');
const { verdict } = require('./score');

const NEG = '(?<!\\b(?:not|never|don\'?t|dont)\\s)';
const RULES = [
  { id: 'otp', title: 'Asks for an OTP, PIN or CVV', points: 35, re: new RegExp(NEG + '\\b(share|send|tell|give|provide|enter|reply with)\\b[^.\\n]{0,30}\\b(otp|pin|cvv|password|passcode)\\b', 'gi'), advice: 'Never share an OTP, PIN or CVV. Banks and apps never ask for them.' },
  { id: 'block', title: 'Threatens to block your account', points: 25, re: /\b(account|card|sim|number|upi|wallet)\b[^.\n]{0,40}\b(block(ed)?|suspend(ed)?|deactivat(ed|ion)|frozen|freeze|expire[sd]?|clos(ed|ure))\b/gi, advice: 'Call your bank on the number printed on your card, not the one in the message.' },
  { id: 'kyc', title: 'Asks for KYC, PAN or Aadhaar update', points: 25, re: /\b(kyc|pan( card)?|aadhaar|aadhar)\b[^.\n]{0,40}\b(update|verify|verification|expire[sd]?|pending|link|suspend(ed)?)\b/gi, advice: 'KYC updates are done at the bank branch or inside the official app only.' },
  { id: 'prize', title: 'Promises a prize or reward', points: 25, re: /\b(you (have )?won|lottery|lucky draw|prize|congratulations|cashback|reward points?|gift card|free recharge)\b/gi, advice: 'Real prizes never ask you to pay or click first.' },
  { id: 'pay', title: 'Asks you to pay or scan to receive money', points: 25, re: /\b(collect request|scan (the )?qr|processing fee|registration fee|advance fee|refundable (deposit|fee)|pay (rs\.?|₹|inr)\s?\d+)/gi, advice: 'You never need to scan a QR code or approve a request to receive money.' },
  { id: 'job', title: 'Offers easy online work', points: 20, re: /\b(part[- ]time job|work from home|earn (rs\.?|₹)?\s?\d[\d,]*\s?(per|a|\/) ?(day|hour)|like (and|&) subscribe|join (our )?telegram)\b/gi, advice: 'Genuine employers do not pay for likes or ask for a deposit to start work.' },
  { id: 'authority', title: 'Claims to be police, customs or a regulator', points: 25, re: /\b(digital arrest|arrest warrant|legal action|cbi|narcotics|customs|income tax (dept|department)|rbi|trai|fedex|courier)\b[\s\S]{0,80}?\b(arrest|illegal|parcel|seized|narcotics|case|fir|penalty|blocked)\b/gi, advice: 'No agency arrests people over video call or asks for money to close a case. Hang up and call 1930.' },
  { id: 'urgency', title: 'Creates urgency', points: 15, re: /\b(urgent(ly)?|immediately|right now|act now|last chance|final notice|expires? (today|soon|tonight)|within \d+ ?(hours?|hrs?|minutes?|mins?))\b/gi, advice: 'Scammers rush you so you do not think. Stop and verify first.' },
  { id: 'phone', title: 'Asks you to call or message a number', points: 10, re: /\b(call|whatsapp|contact)\b[^.\n]{0,25}\+?\d[\d\s-]{8,}/gi, advice: 'Look up the official helpline yourself instead of using numbers in messages.' }
];
const URL_RE = /https?:\/\/[^\s)]+|\bwww\.[^\s)]+|\b(?:bit\.ly|tinyurl\.com|cutt\.ly|rb\.gy|t\.co|is\.gd)\/[^\s)]+/gi;

function analyzeMessage(raw) {
  const text = String(raw || '').trim();
  if (text.length < 5 || text.length > 5000) return { error: 'Paste a message between 5 and 5000 characters.' };
  const findings = [], highlights = [], advice = new Set();
  let score = 0;

  for (const r of RULES) {
    const ms = [...text.matchAll(r.re)];
    if (!ms.length) continue;
    score += r.points;
    findings.push({ severity: r.points >= 25 ? 'high' : r.points >= 15 ? 'medium' : 'low', title: r.title, detail: `Matched: "${ms[0][0].trim().slice(0, 80)}"`, points: r.points });
    advice.add(r.advice);
    ms.forEach(m => highlights.push({ start: m.index, end: m.index + m[0].length, label: r.title }));
  }

  let worst = 0, links = 0;
  for (const m of text.matchAll(URL_RE)) {
    links++;
    const url = m[0].replace(/[.,;!?]+$/, '');
    highlights.push({ start: m.index, end: m.index + url.length, label: 'Link' });
    const a = analyzeUrl(url);
    if (!a.error) worst = Math.max(worst, a.score);
  }
  if (links) {
    const pts = Math.max(8, Math.min(40, Math.round(worst * 0.7)));
    score += pts;
    findings.push({ severity: worst >= 55 ? 'high' : worst >= 25 ? 'medium' : 'low', title: worst >= 25 ? 'Contains a risky link' : 'Contains a link', detail: worst >= 25 ? `The link scored ${worst}/100 in the link checker.` : 'Links in unexpected messages are a common scam route.', points: pts });
    advice.add('Do not tap links in unexpected messages. Open the official app or site yourself.');
  }
  const v = verdict(score);
  if (v.level !== 'safe') advice.add('Report fraud at cybercrime.gov.in or call 1930 (India).');
  return { type: 'message', ...v, findings, highlights, advice: [...advice] };
}
module.exports = { analyzeMessage };
