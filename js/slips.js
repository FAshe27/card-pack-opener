/* Pack slips: ticket/token jackpot cards that replace a card in a pack.
   Centralizes slip rendering so app.js stays under the push size limit.
   Registers as CPS.slips. */
(function (CPS) {
  function isSlip(p) { return !!(p && (p.ticket || p.tokens)); }

  function render(p) {
    if (p.ticket) return '<div class="card ticket-card deal" data-ticket="1"><div class="card-back"></div><div class="ticket-face">🎟️<b>SPIN TICKET</b><span>Jackpot!</span></div></div>';
    return '<div class="card token-card deal" data-tokens="1"><div class="card-back"></div><div class="token-face">🪙<b>' +
      p.tokens + ' GAME TOKEN' + (p.tokens === 1 ? '' : 'S') + '</b><span>Good luck!</span></div></div>';
  }

  function banner(p) {
    return p.ticket ? '🎟️ SPIN TICKET!' : '🪙 +' + p.tokens + ' TOKENS!';
  }

  function isBig() { return false; } // slips never get the "tease" treatment

  function summaryBits(o) {
    var tickets = 0, tokTotal = 0, out = '';
    o.pulls.forEach(function (p) {
      if (p.ticket) tickets++;
      else if (p.tokens) tokTotal += p.tokens;
    });
    if (tickets) out += ' · 🎟️ <b>' + tickets + '</b> spin ticket' + (tickets === 1 ? '' : 's');
    if (tokTotal) out += ' · 🪙 <b>' + tokTotal + '</b> token' + (tokTotal === 1 ? '' : 's');
    return out;
  }

  CPS.slips = { isSlip: isSlip, render: render, banner: banner, isBig: isBig, summaryBits: summaryBits };
})(window.CPS);
