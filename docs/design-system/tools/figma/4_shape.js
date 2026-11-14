const T = await getJSON('tokens.json'); const V = await loadVars(); await loadDocFonts();
const effects = await figma.getLocalEffectStylesAsync();
const page = await getPage('간격 · 모양');
const b = board(page, '간격 · 모양', 1440);
heading(b, '간격 · 모양', '간격, 반경, 그림자, 불투명도, 크기 토큰이에요. 표에 없는 값은 새로 쓰지 않아요.');
function table(parent, toks, draw) {
  const list = box('V', { gap: 0, width: 1296, name: 'rows' }); parent.appendChild(list);
  for (const t of toks) {
    const row = box('H', { gap: 24, pad: [12, 0, 12, 0], align: 'CENTER', width: 1296, name: t.name });
    row.strokes = [LINE()]; row.strokeTopWeight = 1; row.strokeBottomWeight = 0; row.strokeLeftWeight = 0; row.strokeRightWeight = 0;
    const nm = box('H', { width: 240 }); add(nm, txt(t.name, { size: 13, weight: 600, lh: 16 }));
    const val = box('H', { width: 72 }); add(val, txt(String(t.value), { family: 'mono', size: 11, lh: 14, fill: INK2() }));
    add(row, nm, val);
    if (draw) { const d = box('H', { width: 340, align: 'CENTER' }); const g = draw(t); if (g) d.appendChild(g); row.appendChild(d); }
    add(row, txt(t.usage || '', { size: 11, lh: 15, fill: INK2(), width: draw ? 548 : 912 }));
    list.appendChild(row);
  }
}
const accent = () => varPaint(V.light['accent']);
// spacing
let s = section(b, '간격', '막대의 길이가 실제 값이에요.');
table(s, T.spacing.tokens, t => { const r = figma.createRectangle(); r.resize(px(t.value), 16); r.fills = [accent()]; r.setBoundVariable('width', V.size[t.name]); r.name = t.name; return r; });
// radius
s = section(b, '반경', '화면 위에 뜨는 것은 연속 곡률(.continuous)을 써요.');
const grid = box('H', { gap: 24, wrap: true, wrapGap: 24, width: 1296, name: 'grid' }); s.appendChild(grid);
for (const t of T.radius.tokens) {
  const cell = box('V', { gap: 8, width: 192, name: t.name });
  const cap = t.name === 'radius-capsule';
  const r = figma.createRectangle(); r.resize(cap ? 160 : 96, cap ? 48 : 96); r.fills = [varPaint(V.light['fill-selected'])]; r.strokes = [varPaint(V.light['stroke-selected'])]; r.strokeWeight = 1; r.strokeAlign = 'INSIDE';
  r.cornerRadius = px(t.value); for (const k of ['topLeftRadius', 'topRightRadius', 'bottomLeftRadius', 'bottomRightRadius']) r.setBoundVariable(k, V.size[t.name]);
  add(cell, r, txt(t.name, { size: 13, weight: 600, lh: 16 }), txt(String(t.value), { family: 'mono', size: 10, lh: 13, fill: INK2() }));
  if (t.usage) add(cell, txt(t.usage, { size: 11, lh: 15, fill: INK2(), width: 192 }));
  grid.appendChild(cell);
}
// shadow
s = section(b, '그림자', T.shadow.note || '');
const sg = box('H', { gap: 24, wrap: true, wrapGap: 24, width: 1296, name: 'grid' }); s.appendChild(sg);
for (const t of T.shadow.tokens) {
  const variants = typeof t.value === 'string' ? [[t.name, t.value, 'light']] : [[t.name + '/light', t.value.light, 'light'], [t.name + '/dark', t.value.dark, 'dark']];
  for (const [name, css, mode] of variants) {
    const cell = box('V', { gap: 8, width: 300, name });
    const stage = box('H', { pad: 32, fill: varPaint(V[mode]['surface-window']), radius: 12, width: 300, height: 140, align: 'CENTER', justify: 'CENTER' });
    const card = figma.createRectangle(); card.resize(200, 64); card.cornerRadius = 10; card.fills = [varPaint(V[mode]['surface-control'])];
    const es = effects.find(e => e.name === name); if (es) await card.setEffectStyleIdAsync(es.id);
    stage.appendChild(card);
    add(cell, stage, txt(name, { size: 13, weight: 600, lh: 16 }), txt(css, { family: 'mono', size: 10, lh: 13, fill: INK2(), width: 300 }));
    if (t.usage) add(cell, txt(t.usage, { size: 11, lh: 15, fill: INK2(), width: 300 }));
    sg.appendChild(cell);
  }
}
// opacity
s = section(b, '불투명도');
table(s, T.opacity.tokens, t => { const r = figma.createRectangle(); r.resize(120, 20); r.cornerRadius = 4; r.fills = [solid('#000000')]; r.opacity = parseFloat(t.value); r.setBoundVariable('opacity', V.size[t.name]); return r; });
// size
s = section(b, '크기', '컨트롤과 배치의 고정 크기예요. 플랫폼마다 값이 다르면 -iphone 토큰이 따로 있어요.');
table(s, T.size.tokens, null);
s = section(b, '폭 기준', T.breakpoint.note || '');
table(s, T.breakpoint.tokens, null);
return done({ page: page.id, board: b.id, h: Math.round(b.height) });
