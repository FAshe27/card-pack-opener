/* CSV -> card set converter (UMD: used by the in-browser importer and tools/csv-to-set.js).
   Columns (header row recommended, any order, case-insensitive):
     name (required), rarity (required), subtitle, details, image, logo, id
   Without a header row the columns are assumed to be: name, rarity, subtitle, details, image, logo
   "logo" is an optional brand/logo picture shown in the details box (or beside the details text). */
(function (root, factory) {
  var R = (typeof module === 'object' && module.exports) ? require('./rarities.js') : root.CPSRarities;
  var api = factory(R);
  if (typeof module === 'object' && module.exports) module.exports = api;
  else root.CPSCsv = api;
})(typeof self !== 'undefined' ? self : this, function (R) {
  function parseCSV(text) {
    var rows = [], row = [], field = '', q = false, i = 0;
    text = String(text || '').replace(/^\uFEFF/, '');
    while (i < text.length) {
      var c = text[i];
      if (q) {
        if (c === '"') { if (text[i + 1] === '"') { field += '"'; i++; } else q = false; }
        else field += c;
      } else if (c === '"') q = true;
      else if (c === ',') { row.push(field); field = ''; }
      else if (c === '\n' || c === '\r') {
        if (c === '\r' && text[i + 1] === '\n') i++;
        row.push(field); rows.push(row); row = []; field = '';
      } else field += c;
      i++;
    }
    if (field !== '' || row.length) { row.push(field); rows.push(row); }
    return rows.filter(function (r) { return r.some(function (f) { return String(f).trim() !== ''; }); });
  }

  function slug(s) { return String(s || '').trim().toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-+|-+$/g, '') || 'my-set'; }

  /* meta: {id, name, code, description, primary, secondary}
     returns {set, errors[], counts{rarity:n}} */
  function toSet(text, meta) {
    meta = meta || {};
    var rows = parseCSV(text), errors = [], cards = [];
    if (!rows.length) return { set: null, errors: ['The CSV is empty.'], counts: {} };
    var head = rows[0].map(function (h) { return String(h).trim().toLowerCase(); });
    var cols;
    if (head.indexOf('name') >= 0 && head.indexOf('rarity') >= 0) {
      cols = {};
      ['id', 'name', 'rarity', 'subtitle', 'details', 'image', 'logo'].forEach(function (k) { cols[k] = head.indexOf(k); });
      ['flavor', 'text', 'description'].forEach(function (k) { if (cols.details < 0 && head.indexOf(k) >= 0) cols.details = head.indexOf(k); });
      rows = rows.slice(1);
    } else {
      cols = { id: -1, name: 0, rarity: 1, subtitle: 2, details: 3, image: 4, logo: 5 };
    }
    var counts = {};
    rows.forEach(function (r, idx) {
      var get = function (k) { return cols[k] >= 0 && r[cols[k]] != null ? String(r[cols[k]]).trim() : ''; };
      var name = get('name'), rawR = get('rarity'), rarity = R.normRarity(rawR);
      var line = idx + (cols.id === -1 && head.indexOf('name') < 0 ? 1 : 2);
      if (!name) { errors.push('Line ' + line + ': missing name'); return; }
      if (!rarity) { errors.push('Line ' + line + ' ("' + name + '"): unknown rarity "' + rawR + '"'); return; }
      var card = { name: name, rarity: rarity };
      if (get('id')) card.id = get('id');
      if (get('subtitle')) card.subtitle = get('subtitle');
      if (get('details')) card.details = get('details');
      if (get('image')) card.image = get('image');
      if (get('logo')) card.logo = get('logo');
      counts[rarity] = (counts[rarity] || 0) + 1;
      cards.push(card);
    });
    var name = meta.name || 'My Set';
    var set = {
      id: slug(meta.id || name),
      name: name,
      code: (meta.code || name.replace(/[^A-Za-z0-9]/g, '').slice(0, 3) || 'SET').toUpperCase().slice(0, 4),
      description: meta.description || '',
      theme: { primary: meta.primary || '#ff7a59', secondary: meta.secondary || '#7b2ff7' },
      cards: cards
    };
    if (!cards.length) errors.push('No valid cards found.');
    return { set: set, errors: errors, counts: counts };
  }

  function toJsFile(set) {
    return '/* Card set: ' + set.name + ' (generated from CSV). Add this file to sets/manifest.js. */\n' +
      'CardSets.register(' + JSON.stringify(set, null, 2) + ');\n';
  }
  return { parseCSV: parseCSV, toSet: toSet, toJsFile: toJsFile, slug: slug };
});
