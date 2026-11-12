// Shared helpers. console.js puts this file in front of each numbered script before running it in the Figma tab.
const BASE = 'http://127.0.0.1:8765/';
const getJSON = async n => { const r = await fetch(BASE + n + '?' + Date.now()); if (!r.ok) throw new Error(n + ': ' + r.status); return r.json(); };
function parseColor(s) {
  s = s.trim();
  let m;
  if ((m = s.match(/^#([0-9a-f]{6})$/i))) { const h = m[1]; return { r: parseInt(h.slice(0,2),16)/255, g: parseInt(h.slice(2,4),16)/255, b: parseInt(h.slice(4,6),16)/255, a: 1 }; }
  if ((m = s.match(/^rgba?\(([^)]+)\)$/))) { const p = m[1].split(/[,\s\/]+/).filter(Boolean).map(Number); return { r: p[0]/255, g: p[1]/255, b: p[2]/255, a: p.length > 3 ? p[3] : 1 }; }
  if ((m = s.match(/^color\(srgb ([^)]+)\)$/))) { const p = m[1].split(/[\s\/]+/).filter(Boolean).map(Number); return { r: p[0], g: p[1], b: p[2], a: p.length > 3 ? p[3] : 1 }; }
  throw new Error('color? ' + s);
}
const px = s => parseFloat(s);
// SF Pro / SF Pro Rounded do not render in Figma's browser editor here, so Pretendard stands in for both.
const FAMILY = { sans: 'Pretendard', rounded: 'Pretendard', mono: 'Menlo' };
function fontFor(family, weight) {
  if (family === 'mono') return { family: 'Menlo', style: weight >= 600 ? 'Bold' : 'Regular' };
  const st = weight >= 700 ? 'Bold' : weight >= 600 ? 'SemiBold' : weight >= 500 ? 'Medium' : 'Regular';
  return { family: FAMILY[family] || 'Pretendard', style: st };
}
function colorGroup(name) { return name.split('-')[0]; }
function colorScopes(name) {
  const g = colorGroup(name);
  if (g === 'label' || name.startsWith('overlay-text') || name === 'web-text' || name === 'web-muted' || name === 'overlay-button-text') return ['TEXT_FILL', 'SHAPE_FILL', 'STROKE_COLOR'];
  if (g === 'hairline' || g === 'divider' || g === 'stroke' || name === 'accent-stroke-selected' || name === 'record-ring') return ['STROKE_COLOR'];
  if (g === 'status' || g === 'issue' || name === 'accent' || name === 'accent-highlight' || g === 'brand') return ['ALL_FILLS', 'STROKE_COLOR'];
  return ['FRAME_FILL', 'SHAPE_FILL'];
}
function parseShadow(s) { // "0 1px 3px rgba(0, 0, 0, 0.12)"
  const m = s.match(/^(-?[\d.]+)(?:px)?\s+(-?[\d.]+)(?:px)?\s+([\d.]+)(?:px)?\s+(rgba?\([^)]+\))$/);
  if (!m) throw new Error('shadow? ' + s);
  const c = parseColor(m[4]);
  return { type: 'DROP_SHADOW', color: { r: c.r, g: c.g, b: c.b, a: c.a }, offset: { x: +m[1], y: +m[2] }, radius: +m[3], spread: 0, visible: true, blendMode: 'NORMAL', showShadowBehindNode: false };
}
// ---- doc helpers ----
async function loadVars() {
  const cs = await figma.variables.getLocalVariableCollectionsAsync();
  const vs = await figma.variables.getLocalVariablesAsync();
  const m = { light: {}, dark: {}, size: {} };
  for (const v of vs) {
    const c = cs.find(c => c.id === v.variableCollectionId); if (!c) continue;
    const key = v.name.split('/').pop();
    if (c.name === 'Color · Light') m.light[key] = v; else if (c.name === 'Color · Dark') m.dark[key] = v; else if (c.name === 'Size') m.size[key] = v;
  }
  return m;
}
function varPaint(v) {
  const val = Object.values(v.valuesByMode)[0];
  return figma.variables.setBoundVariableForPaint({ type: 'SOLID', color: { r: val.r, g: val.g, b: val.b }, opacity: val.a === undefined ? 1 : val.a }, 'color', v);
}
function solid(hex, opacity) { const c = parseColor(hex); return { type: 'SOLID', color: { r: c.r, g: c.g, b: c.b }, opacity: opacity === undefined ? c.a : opacity }; }
async function loadDocFonts() {
  const fs = [];
  for (const st of ['Regular', 'Medium', 'SemiBold', 'Bold']) fs.push({ family: 'Pretendard', style: st });
  fs.push({ family: 'Menlo', style: 'Regular' }, { family: 'Menlo', style: 'Bold' });
  await Promise.all(fs.map(f => figma.loadFontAsync(f)));
}
function txt(str, o = {}) {
  const t = figma.createText();
  t.fontName = fontFor(o.family || 'sans', o.weight || 400);
  t.characters = String(str);
  t.fontSize = o.size || 13;
  if (o.lh) t.lineHeight = { unit: 'PIXELS', value: o.lh };
  if (o.ls) t.letterSpacing = { unit: 'PIXELS', value: o.ls };
  t.fills = [o.fill || solid('#000000', 0.85)];
  if (o.width) { t.resize(o.width, t.height); t.textAutoResize = 'HEIGHT'; }
  if (o.name) t.name = o.name;
  return t;
}
function box(dir, o = {}) {
  const f = figma.createFrame();
  f.layoutMode = dir === 'V' ? 'VERTICAL' : 'HORIZONTAL';
  f.primaryAxisSizingMode = 'AUTO'; f.counterAxisSizingMode = 'AUTO';
  f.itemSpacing = o.gap || 0;
  const p = o.pad || 0; const [pt, pr, pb, pl] = Array.isArray(p) ? p : [p, p, p, p];
  f.paddingTop = pt; f.paddingRight = pr; f.paddingBottom = pb; f.paddingLeft = pl;
  f.fills = o.fill ? [o.fill] : [];
  if (o.radius) f.cornerRadius = o.radius;
  if (o.stroke) { f.strokes = [o.stroke]; f.strokeWeight = o.strokeWeight || 1; f.strokeAlign = 'INSIDE'; }
  if (o.align) f.counterAxisAlignItems = o.align;
  if (o.justify) f.primaryAxisAlignItems = o.justify;
  if (o.wrap) { f.layoutWrap = 'WRAP'; f.counterAxisSpacing = o.wrapGap ?? o.gap ?? 0; }
  if (o.name) f.name = o.name;
  if (o.width || o.height) {
    f.resize(o.width || 100, o.height || 100);
    const wFixed = !!o.width, hFixed = !!o.height;
    if (dir === 'V') { f.counterAxisSizingMode = wFixed ? 'FIXED' : 'AUTO'; f.primaryAxisSizingMode = hFixed ? 'FIXED' : 'AUTO'; }
    else { f.primaryAxisSizingMode = wFixed ? 'FIXED' : 'AUTO'; f.counterAxisSizingMode = hFixed ? 'FIXED' : 'AUTO'; }
  }
  return f;
}
function add(parent, ...kids) { for (const k of kids) parent.appendChild(k); return parent; }
async function getPage(name, reuse) {
  let p = figma.root.children.find(p => p.name === name);
  if (!p && reuse) { const r = figma.root.children.find(p => p.name === reuse); if (r) { await r.loadAsync(); if (r.children.length === 0) { r.name = name; p = r; } } }
  if (!p) { p = figma.createPage(); p.name = name; }
  await p.loadAsync();
  return p;
}
// A new board replaces the ones an earlier run made (same name, same page). The old ones stay until
// done() runs, so a script that throws halfway leaves the previous board in place.
const STALE = [];
function done(result) { for (const n of STALE.splice(0)) if (!n.removed) n.remove(); return result; }
function board(page, name, width) {
  STALE.push(...page.children.filter(n => n.name === name && n.type === 'FRAME'));
  const b = box('V', { name, pad: 72, gap: 48, fill: solid('#ffffff'), width });
  page.appendChild(b); b.x = 0; b.y = 0; return b;
}
const INK = () => solid('#000000', 0.85), INK2 = () => solid('#000000', 0.5), LINE = () => solid('#000000', 0.08);
function heading(parent, title, sub, width) {
  const h = box('V', { gap: 8, name: 'heading' });
  add(h, txt(title, { size: 40, weight: 700, lh: 48 }));
  if (sub) add(h, txt(sub, { size: 15, lh: 23, fill: INK2(), width: width || 880 }));
  parent.appendChild(h); return h;
}
function section(parent, title, sub) {
  const s = box('V', { gap: 20, name: title });
  const h = box('V', { gap: 4 });
  add(h, txt(title, { size: 20, weight: 600, lh: 25 }));
  if (sub) add(h, txt(sub, { size: 13, lh: 18, fill: INK2(), width: 880 }));
  add(s, h); parent.appendChild(s); return s;
}
