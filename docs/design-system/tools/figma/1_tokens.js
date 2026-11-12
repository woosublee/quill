const T = await getJSON('tokens.json');
const cols = await figma.variables.getLocalVariableCollectionsAsync();
const allVars = await figma.variables.getLocalVariablesAsync();
function coll(name, mode) {
  let c = cols.find(c => c.name === name);
  if (!c) { c = figma.variables.createVariableCollection(name); c.renameMode(c.modes[0].modeId, mode); cols.push(c); }
  return c;
}
function upsert(c, name, type, value, scopes, web, desc) {
  let v = allVars.find(v => v.variableCollectionId === c.id && v.name === name);
  if (!v) { v = figma.variables.createVariable(name, c, type); allVars.push(v); }
  v.setValueForMode(c.modes[0].modeId, value);
  v.scopes = scopes;
  v.setVariableCodeSyntax('WEB', `var(--${web})`);
  if (desc) v.description = desc;
  return v;
}
const out = { color: 0, size: 0, text: 0, effect: 0 };
const light = coll('Color · Light', 'Light'), dark = coll('Color · Dark', 'Dark');
for (const t of T.color.tokens) {
  const name = colorGroup(t.name) + '/' + t.name;
  upsert(light, name, 'COLOR', parseColor(t.value.light), colorScopes(t.name), t.name, t.usage);
  upsert(dark, name, 'COLOR', parseColor(t.value.dark), colorScopes(t.name), t.name, t.usage);
  out.color++;
}
const size = coll('Size', 'Value');
const fam = [['spacing', 'spacing', ['GAP']], ['radius', 'radius', ['CORNER_RADIUS']], ['size', 'size', ['WIDTH_HEIGHT']], ['breakpoint', 'breakpoint', ['WIDTH_HEIGHT']]];
for (const [key, group, scopes] of fam) for (const t of T[key].tokens) { upsert(size, group + '/' + t.name, 'FLOAT', px(t.value), scopes, t.name, t.usage); out.size++; }
for (const t of T.opacity.tokens) { upsert(size, 'opacity/' + t.name, 'FLOAT', parseFloat(t.value) * 100, ['OPACITY'], t.name, t.usage); out.size++; }

// text styles
const existingTS = await figma.getLocalTextStylesAsync();
const fonts = new Map();
const specs = [];
for (const g of T.type.groups) for (const s of g.styles) {
  const f = fontFor(s.family || g.family, s.fontWeight);
  fonts.set(JSON.stringify(f), f);
  specs.push({ name: g.name + '/' + s.name, f, s });
}
await Promise.all([...fonts.values()].map(f => figma.loadFontAsync(f)));
for (const { name, f, s } of specs) {
  let ts = existingTS.find(x => x.name === name) || figma.createTextStyle();
  ts.name = name; ts.fontName = f; ts.fontSize = px(s.fontSize);
  ts.lineHeight = { unit: 'PIXELS', value: px(s.lineHeight) };
  ts.letterSpacing = { unit: 'PIXELS', value: s.letterSpacing ? px(s.letterSpacing) : 0 };
  if (s.paragraphSpacing) ts.paragraphSpacing = px(s.paragraphSpacing);
  ts.description = s.usage || '';
  out.text++;
}
// effect styles
const existingES = await figma.getLocalEffectStylesAsync();
function effect(name, css, desc) {
  let es = existingES.find(x => x.name === name) || figma.createEffectStyle();
  es.name = name; es.effects = [parseShadow(css)]; es.description = desc || ''; out.effect++;
}
for (const t of T.shadow.tokens) {
  if (typeof t.value === 'string') effect(t.name, t.value, t.usage);
  else { effect(t.name + '/light', t.value.light, t.usage); effect(t.name + '/dark', t.value.dark, t.usage); }
}
return out;
