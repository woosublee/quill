// window.quillArg = { group: '2 · 분자' } or { names: ['StatusBanner'] } limits a run; unset builds every group.
const ARG = window.quillArg || {};
const T = await getJSON('tokens.json'); const V = await loadVars(); await loadDocFonts();
await Promise.all(['ExtraBold', 'Light'].map(st => figma.loadFontAsync({ family: 'Pretendard', style: st }).catch(() => null)));
const index = await getJSON('out/index.json');
const textStyles = await figma.getLocalTextStylesAsync(); const effectStyles = await figma.getLocalEffectStylesAsync();
// text style lookup: kind|size|weight|ls -> style
const PRIORITY = ['body', 'row-title', 'headline', 'callout', 'caption', 'banner-title', 'chip-label', 'toast-text', 'transcript', 'note-title', 'meta-label', 'badge-label', 'row-preview', 'code-body', 'code-caption'];
const tsMap = new Map();
for (const g of T.type.groups) for (const s of g.styles) {
  const kind = (s.family || g.family) === 'mono' ? 'mono' : 'sans';
  const key = [kind, px(s.fontSize), kind === 'mono' ? (s.fontWeight >= 600 ? 700 : 400) : s.fontWeight, s.letterSpacing ? px(s.letterSpacing) : 0].join('|');
  const style = textStyles.find(x => x.name === g.name + '/' + s.name); if (!style) continue;
  const cur = tsMap.get(key), rank = n => { const i = PRIORITY.indexOf(n); return i < 0 ? 99 : i; };
  if (!cur || rank(s.name) < rank(cur.token)) tsMap.set(key, { style, token: s.name });
}
const shadowTokens = [];
for (const t of T.shadow.tokens) { const css = typeof t.value === 'string' ? t.value : t.value.light; const name = typeof t.value === 'string' ? t.name : t.name + '/light'; shadowTokens.push({ e: parseShadow(css), style: effectStyles.find(x => x.name === name) }); }
const radiusTokens = T.radius.tokens.map(t => ({ name: t.name, v: px(t.value) }));
const stats = { nodes: 0, bound: 0, raw: 0, textStyled: 0, text: 0, comps: 0, errors: [] };
const near = (a, b) => Math.abs(a - b) < 0.006;
function P(color, tok) {
  if (tok && V.light[tok]) { stats.bound++; return varPaint(V.light[tok]); }
  stats.raw++; const c = parseColor(color); return { type: 'SOLID', color: { r: c.r, g: c.g, b: c.b }, opacity: c.a };
}
function splitTop(s) { const out = []; let d = 0, cur = ''; for (const ch of s) { if (ch === '(') d++; if (ch === ')') d--; if (ch === ',' && d === 0) { out.push(cur.trim()); cur = ''; } else cur += ch; } if (cur.trim()) out.push(cur.trim()); return out; }
function gradient(css) {
  const m = css.match(/^linear-gradient\((.*)\)$/s); if (!m) return null;
  const parts = splitTop(m[1]); let angle = 180;
  if (/deg$/.test(parts[0])) angle = parseFloat(parts.shift()); else if (/^to /.test(parts[0])) { const d = parts.shift(); angle = { 'to top': 0, 'to right': 90, 'to bottom': 180, 'to left': 270, 'to bottom right': 135, 'to top right': 45 }[d] ?? 180; }
  const stops = parts.map((p, i) => { const mm = p.match(/^(.*\))\s*([\d.]+%)?$/) || [null, p]; const c = parseColor(mm[1]); return { c, pos: mm[2] ? parseFloat(mm[2]) / 100 : i / (parts.length - 1) }; });
  const solidStop = stops.find(s => s.c.a > 0); for (const s of stops) if (s.c.a === 0 && solidStop) Object.assign(s.c, { r: solidStop.c.r, g: solidStop.c.g, b: solidStop.c.b });
  const th = angle * Math.PI / 180, dx0 = Math.sin(th), dy0 = -Math.cos(th), L = Math.abs(dx0) + Math.abs(dy0);
  const x1 = 0.5 - dx0 * L / 2, y1 = 0.5 - dy0 * L / 2, dx = dx0 * L, dy = dy0 * L, l2 = dx * dx + dy * dy;
  return { type: 'GRADIENT_LINEAR', gradientTransform: [[dx / l2, dy / l2, -(x1 * dx + y1 * dy) / l2], [-dy / l2, dx / l2, (x1 * dy - y1 * dx) / l2 + 0.5]], gradientStops: stops.map(s => ({ position: s.pos, color: { r: s.c.r, g: s.c.g, b: s.c.b, a: s.c.a } })) };
}
function imageFill(src) {
  const m = src.match(/^data:[^;]+;base64,(.*)$/s); if (!m) return null;
  const bin = atob(m[1]); const bytes = new Uint8Array(bin.length); for (let i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
  return { type: 'IMAGE', scaleMode: 'FILL', imageHash: figma.createImage(bytes).hash };
}
function applyRadius(f, n) {
  if (!n.radius) return;
  const [a, b, c, d] = n.radius;
  if (a === b && b === c && c === d) {
    f.cornerRadius = a;
    const t = n.radiusRaw === '999px' ? radiusTokens.find(r => r.name === 'radius-capsule') : radiusTokens.find(r => r.v === a && r.name !== 'radius-capsule');
    if (t && V.size[t.name] && 'setBoundVariable' in f) for (const k of ['topLeftRadius', 'topRightRadius', 'bottomLeftRadius', 'bottomRightRadius']) f.setBoundVariable(k, V.size[t.name]);
  } else { f.topLeftRadius = a; f.topRightRadius = b; f.bottomRightRadius = c; f.bottomLeftRadius = d; }
}
function applyStroke(f, n) {
  if (n.border) { const w = n.border.w; f.strokes = [P(n.border.color, n.border.tok)]; f.strokeAlign = 'INSIDE';
    if (w.every(x => x === w[0])) f.strokeWeight = w[0]; else { f.strokeTopWeight = w[0]; f.strokeRightWeight = w[1]; f.strokeBottomWeight = w[2]; f.strokeLeftWeight = w[3]; } }
  else if (n.ring) { f.strokes = [P(n.ring.color, n.ring.tok)]; f.strokeAlign = n.ring.align; f.strokeWeight = n.ring.w; }
}
async function applyEffects(f, n) {
  const eff = [];
  for (const s of n.shadows || []) { const c = parseColor(s.color); eff.push({ type: s.inset ? 'INNER_SHADOW' : 'DROP_SHADOW', color: { r: c.r, g: c.g, b: c.b, a: c.a }, offset: { x: s.x, y: s.y }, radius: s.blur, spread: s.spread, visible: true, blendMode: 'NORMAL', ...(s.inset ? {} : { showShadowBehindNode: false }) }); }
  if (n.blur) eff.push({ type: 'BACKGROUND_BLUR', radius: n.blur, visible: true });
  if (!eff.length) return;
  if (eff.length === 1 && eff[0].type === 'DROP_SHADOW') {
    const e = eff[0]; const t = shadowTokens.find(t => t.style && t.e.offset.x === e.offset.x && t.e.offset.y === e.offset.y && t.e.radius === e.radius && near(t.e.color.a, e.color.a) && near(t.e.color.r, e.color.r));
    if (t) { await f.setEffectStyleIdAsync(t.style.id); return; }
  }
  try { f.effects = eff; } catch (e) { try { f.effects = eff.map(x => x.type === 'BACKGROUND_BLUR' ? { ...x, blurType: 'NORMAL' } : x); } catch (e2) { f.effects = eff.filter(x => x.type !== 'BACKGROUND_BLUR'); stats.errors.push('effects: ' + e2.message.slice(0, 80)); } }
}
async function build(n, parent) {
  stats.nodes++;
  let node;
  if (n.t === 'text') {
    stats.text++;
    const t = figma.createText(); parent.appendChild(t);
    t.fontName = fontFor(n.kind, n.weight); t.characters = n.chars; t.fontSize = n.size;
    if (n.ls) t.letterSpacing = { unit: 'PIXELS', value: n.ls };
    if (n.upper) t.textCase = 'UPPER';
    const key = [n.kind, n.size, n.kind === 'mono' ? (n.weight >= 600 ? 700 : 400) : (n.weight >= 700 ? 700 : n.weight >= 600 ? 600 : n.weight >= 500 ? 500 : 400), n.ls || 0].join('|');
    const ts = tsMap.get(key);
    if (ts) { await t.setTextStyleIdAsync(ts.style.id); stats.textStyled++; }
    else if (n.lines > 1 && n.lh) t.lineHeight = { unit: 'PIXELS', value: n.lh };
    t.fills = [P(n.color, n.tok)];
    if (n.align) t.textAlignHorizontal = n.align;
    if (n.trunc) { t.resize(Math.max(n.w, 1), t.height); t.textAutoResize = 'HEIGHT'; t.textTruncation = 'ENDING'; t.maxLines = 1; t.x = n.x; }
    else t.x = n.align === 'CENTER' ? n.x + (n.w - t.width) / 2 : n.align === 'RIGHT' ? n.x + n.w - t.width : n.x;
    t.y = n.y + (n.h - t.height) / 2;
    t.name = n.name || n.chars.slice(0, 24);
    node = t;
  } else if (n.t === 'svg') {
    try {
      const s = figma.createNodeFromSvg(n.svg); parent.appendChild(s); s.x = n.x; s.y = n.y; s.name = n.name || 'icon'; s.fills = []; s.clipsContent = false;
      const c = parseColor(n.color);
      for (const d of s.findAll(x => 'fills' in x)) for (const prop of ['fills', 'strokes']) {
        const arr = d[prop]; if (!Array.isArray(arr) || !arr.length) continue;
        d[prop] = arr.map(p => (p.type === 'SOLID' && near(p.color.r, c.r) && near(p.color.g, c.g) && near(p.color.b, c.b)) ? Object.assign(P(n.color, n.tok), n.tok ? {} : { opacity: c.a * (p.opacity ?? 1) }) : p);
      }
      if (n.opacity !== undefined) s.opacity = n.opacity;
      node = s;
    } catch (e) { stats.errors.push('svg: ' + String(e.message).slice(0, 80)); return null; }
  } else if (n.t === 'img') {
    const r = figma.createRectangle(); parent.appendChild(r); r.resize(Math.max(n.w, 0.01), Math.max(n.h, 0.01)); r.x = n.x; r.y = n.y; r.name = 'image';
    const fill = imageFill(n.src); r.fills = fill ? [fill] : [solid('#cccccc')];
    applyRadius(r, n); applyStroke(r, n); node = r;
  } else {
    const f = figma.createFrame(); parent.appendChild(f);
    f.resize(Math.max(n.w, 0.01), Math.max(n.h, 0.01)); f.x = n.x; f.y = n.y; f.name = n.cls || 'frame'; f.clipsContent = !!n.clip;
    const fills = [];
    if (n.bg) fills.push(P(n.bg, n.bgTok));
    if (n.bgImg) { const g = n.bgImg.startsWith('url(') ? imageFill(n.bgImg.slice(5, -2)) : gradient(n.bgImg); if (g) fills.push(g); else stats.errors.push('bgImg: ' + n.bgImg.slice(0, 40)); }
    f.fills = fills;
    applyRadius(f, n); applyStroke(f, n); await applyEffects(f, n);
    if (n.opacity !== undefined) f.opacity = n.opacity;
    for (const k of n.kids || []) await build(k, f);
    node = f;
  }
  if (n.comp !== undefined) build.pending.push([node, n.comp]);
  return node;
}
function rules(md) {
  return md.split('\n').filter(l => l.trim() && !l.startsWith('# ')).map(l => l.replace(/^\s*-\s+/, '·  ').replace(/`/g, '').replace(/\*\*/g, '')).join('\n');
}
const groups = [...new Set(index.map(i => i.group))].filter(g => !ARG.group || g === ARG.group);
const result = [];
for (const g of groups) {
  const items = index.filter(i => i.group === g && (!ARG.names || ARG.names.includes(i.name)));
  const page = getPage('컴포넌트 ' + g);
  const maxW = Math.max(...items.map(i => i.width));
  const b = board(page, '컴포넌트 ' + g, 144 + 340 + 56 + maxW);
  heading(b, g.replace(/^\d+ · /, ''), '레포 docs/design-system/components의 미리보기를 그대로 옮겼어요. 캡션이 붙은 상태 하나하나가 Figma 컴포넌트예요(에셋 패널에서 찾을 수 있어요). 레이어는 미리보기의 위치 그대로 놓여 있고, 색·반경·글자·그림자는 토큰에 연결돼 있어요.', 340 + 56 + maxW);
  for (const it of items) {
    const d = await getJSON('out/' + it.name + '.json');
    const block = box('H', { gap: 56, name: it.name });
    const meta = box('V', { gap: 8, width: 340, name: 'meta' });
    add(meta, txt(it.name, { size: 20, weight: 600, lh: 25 }), txt(it.subtitle || '', { size: 13, lh: 18, fill: INK2(), width: 340 }), txt(rules(d.readme), { size: 11.5, lh: 17, fill: INK2(), width: 340 }));
    block.appendChild(meta); b.appendChild(block);
    build.pending = [];
    const stage = await build(d.root, block);
    stage.name = it.name + ' · 미리보기'; stage.cornerRadius = 12; stage.clipsContent = true; stage.strokes = [LINE()]; stage.strokeWeight = 1; stage.strokeAlign = 'INSIDE';
    for (const [node, comp] of build.pending) {
      try {
        let target = node;
        if (node.type !== 'FRAME') { const w = figma.createFrame(); const par = node.parent, idx = par.children.indexOf(node); par.insertChild(idx, w); w.fills = []; w.clipsContent = false; w.resize(Math.max(node.width, 1), Math.max(node.height, 1)); w.x = node.x; w.y = node.y; w.appendChild(node); node.x = 0; node.y = 0; target = w; }
        const c = figma.createComponentFromNode(target); c.name = comp ? `${it.name}/${comp}` : it.name; c.description = it.subtitle || ''; stats.comps++;
      } catch (e) { stats.errors.push(`comp ${it.name}/${comp}: ` + String(e.message).slice(0, 80)); }
    }
  }
  result.push({ page: page.id, name: page.name, board: b.id, w: Math.round(b.width), h: Math.round(b.height), items: items.length });
}
const ORDER = ['시작', '색', '글자', '간격 · 모양', ...[...new Set(index.map(i => i.group))].map(g => '컴포넌트 ' + g)];
ORDER.forEach((name, i) => { const p = figma.root.children.find(p => p.name === name); if (p) figma.root.insertChild(Math.min(i, figma.root.children.length - 1), p); });
return { result, stats: { ...stats, errors: stats.errors.slice(0, 12), errorCount: stats.errors.length } };
