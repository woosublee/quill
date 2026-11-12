const T = await getJSON('tokens.json'); const V = await loadVars(); await loadDocFonts();
const page = getPage('색');
const b = board(page, '색', 1440);
heading(b, '색', '앱 UI는 플랫폼의 의미 색으로 그려요. 표의 값은 기본 파랑 강조색 기준의 근사값이고, 코드에서는 hex 대신 시스템 의미 색과 QuillColor를 써요. 각 카드의 왼쪽은 라이트, 오른쪽은 다크예요.');
const GROUPS = [['brand','브랜드','아이콘·스토어·웹사이트에만 써요. 앱 UI 표면에는 쓰지 않아요.'],['web','웹사이트',''],['accent','강조','사용자가 강조색을 바꾸면 함께 바뀌어요.'],['surface','표면','창 바탕 → 카드 → 읽고 쓰는 영역.'],['label','글자',''],['status','상태','녹음 · 처리 중 · 완료.'],['issue','이슈','아이콘 전용이에요. 글자에는 쓰지 않아요.'],['fill','채움','primary 불투명도 단계로만 만들어요.'],['line','선',''],['overlay','오버레이','테마와 상관없이 검정 위 흰색.'],['record','녹음','']];
const gkey = n => { const g = colorGroup(n); return ['hairline','divider','stroke'].includes(g) ? 'line' : g; };
const fmt = s => s.replace(/rgba\((\d+), (\d+), (\d+), ([\d.]+)\)/, (m, r, g, b2, a) => (r+g+b2 === '000' ? '검정' : r+g+b2 === '255255255' ? '흰색' : `rgb ${r} ${g} ${b2}`) + ' ' + Math.round(a * 1000) / 10 + '%');
let n = 0;
for (const [g, title, sub] of GROUPS) {
  const toks = T.color.tokens.filter(t => gkey(t.name) === g); if (!toks.length) continue;
  const s = section(b, title, sub);
  const grid = box('H', { gap: 16, wrap: true, wrapGap: 16, width: 1296, name: 'grid' });
  s.appendChild(grid);
  for (const t of toks) {
    const card = box('V', { gap: 10, pad: 12, radius: 12, stroke: LINE(), width: 312, name: t.name });
    const sw = box('H', { gap: 0, radius: 8, name: 'swatches' }); sw.clipsContent = true;
    for (const mode of ['light', 'dark']) {
      const back = box('H', { pad: 0, fill: solid(mode === 'light' ? '#ffffff' : '#1e1e1e'), name: mode, width: 144, height: 64 });
      const r = figma.createRectangle(); r.resize(144, 64); r.fills = [varPaint(V[mode][t.name])]; r.name = t.name;
      back.appendChild(r); sw.appendChild(back);
    }
    sw.strokes = [LINE()]; sw.strokeWeight = 1; sw.strokeAlign = 'INSIDE';
    add(card, sw, txt(t.name, { size: 13, weight: 600, lh: 16 }), txt(fmt(t.value.light) + (t.value.light === t.value.dark ? '' : '  ·  ' + fmt(t.value.dark)), { family: 'mono', size: 10, lh: 13, fill: INK2(), width: 288 }));
    if (t.usage) add(card, txt(t.usage, { size: 11, lh: 15, fill: INK2(), width: 288 }));
    grid.appendChild(card); n++;
  }
}
return { page: page.id, board: b.id, cards: n, h: Math.round(b.height) };
