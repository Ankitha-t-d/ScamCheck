function verdict(score) {
  const s = Math.max(0, Math.min(100, Math.round(score)));
  if (s >= 55) return { score: s, level: 'dangerous', label: 'Likely a scam' };
  if (s >= 25) return { score: s, level: 'suspicious', label: 'Suspicious' };
  return { score: s, level: 'safe', label: 'No strong warning signs' };
}
module.exports = { verdict };
