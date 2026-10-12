/* Pack slips: ticket/token jackpot cards that replace a card in a pack.
   Centralizes slip rendering so app.js stays under the push size limit.
   Element of Surprise: slips use the standard flippable card structure, so
   pre-flip they show the pack's set back exactly like every other card —
   the jackpot is only revealed on flip. Registers as CPS.slips. */
(function (CPS) {
  function isSlip(p) { return !!(p && (p.ticket || p.tokens)); }

  function esc(s) {
    return String(s == null ? '' : s).replace(/[&<>"']/g, function (c) {
      return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c];
    });
  }

  /* The set whose pack this slip came from — its back is the disguise. */
  function slipSet(p) {
    if (p && p.homeSet) return p.homeSet;
    var C = window.CPS && CPS.appCtx;
    if (C && C.S && C.S.opening && C.S.opening.set) return C.S.opening.set;
    return { id: '', code: '?', name: '', theme: { primary: '#1a1a2e', secondary: '#16213e' } };
  }

  function render(p) {
    var set = slipSet(p);
    var cls = p.ticket ? 'ticket-card' : (p.credit ? 'credit-card' : 'token-card');
    var attr = p.ticket ? ' data-ticket="1"' : (p.credit ? ' data-credit="1"' : ' data-tokens="1"');
    var face = p.ticket
      ? '<div class="ticket-face">🎟️<b>SPIN TICKET</b><span>Jackpot!</span></div>'
      : (p.credit
        ? '<div class="credit-face">💵<b>$' + p.credit + ' STORE CREDIT</b><span>Ka-ching!</span></div>'
        : '<div class="token-face">🪙<b>' + p.tokens + ' GAME TOKEN' + (p.tokens === 1 ? '' : 'S') + '</b><span>Good luck!</span></div>');
    return '<div class="card ' + cls + ' flippable deal" data-slip="1"' + attr +
      ' data-set="' + esc(set.id) + '" style="' + CPS.cards.themeStyle(set) + '">' +
      '<div class="card-inner"><div class="face front">' + face + '</div>' +
      CPS.cards.back(set) + '</div></div>';
  }

  function banner(p) {
    if (p.ticket) return '🎟️ SPIN TICKET!';
    if (p.credit) return '💵 +$' + p.credit + ' STORE CREDIT!';
    return '🪙 +' + p.tokens + ' TOKENS!';
  }

  function isBig() { return false; } // slips never get the "big pull" treatment

  // Server grants slip currencies at pack-open; mirror the balances live so
  // the Arcade header / wheel glow update without a refresh. Lazy appCtx:
  // this module loads before app.js.
  function applyPackGrants(pulls) {
    var C = window.CPS && CPS.appCtx;
    if (!C || !C.isCloud || !C.isCloud()) return;
    var tok = 0, tik = 0;
    (pulls || []).forEach(function (p) { if (p.tokens) tok += p.tokens; else if (p.ticket) tik++; });
    if (tok) C.S.gameTokens = (C.S.gameTokens || 0) + tok;
    if (tik) { C.S.spins = (C.S.spins || 0) + tik; C.updateWheelBadge(); }
  }

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

  CPS.slips = { isSlip: isSlip, render: render, banner: banner, isBig: isBig, summaryBits: summaryBits, applyPackGrants: applyPackGrants };
})(window.CPS);
