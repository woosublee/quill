const T = await getJSON('tokens.json'); await loadDocFonts();
const styles = await figma.getLocalTextStylesAsync();
const page = getPage('글자');
const b = board(page, '글자', 1440);
heading(b, '글자', '글꼴은 시스템 하나예요: SF Pro, 온보딩 큰 제목만 SF Rounded, 코드·타이머는 SF Mono. 크기는 역할 이름으로 골라요. 이 파일에서는 SF Pro 자리에 Pretendard, SF Mono 자리에 Menlo를 썼어요(Figma 브라우저에서 SF 글꼴이 그려지지 않아요). 값은 macOS 기준이고, iPhone은 Dynamic Type을 따라요.');
const W = { 400: 'Regular', 500: 'Medium', 600: 'Semibold', 700: 'Bold' };
const GN = { Display: '큰 제목', Headings: '제목', Body: '본문', Labels: '라벨', Mono: '고정폭' };
let n = 0;
for (const g of T.type.groups) {
  const s = section(b, GN[g.name] || g.name, g.name);
  const list = box('V', { gap: 0, width: 1296, name: 'rows' }); s.appendChild(list);
  for (const st of g.styles) {
    const row = box('H', { gap: 32, pad: [18, 0, 18, 0], align: 'CENTER', width: 1296, name: st.name });
    row.strokes = [LINE()]; row.strokeTopWeight = 1; row.strokeBottomWeight = 0; row.strokeLeftWeight = 0; row.strokeRightWeight = 0;
    const meta = box('V', { gap: 4, width: 380, name: 'meta' });
    const fam = (st.family || g.family);
    const spec = `${px(st.fontSize)} / ${px(st.lineHeight)} · ${W[st.fontWeight]}` + (fam !== 'sans' ? ` · ${fam}` : '') + (st.letterSpacing ? ` · 자간 ${st.letterSpacing}` : '') + (st.paragraphSpacing ? ` · 문단 ${st.paragraphSpacing}` : '');
    add(meta, txt(st.name, { size: 13, weight: 600, lh: 16 }), txt(spec, { family: 'mono', size: 10, lh: 13, fill: INK2() }));
    if (st.usage) add(meta, txt(st.usage, { size: 11, lh: 15, fill: INK2(), width: 380 }));
    const sample = txt(st.sample || (fam === 'mono' ? '00:12:48  whisper-large-v3' : '말로 쓰는 노트, Quill'), { size: 13, width: 860, name: 'sample' });
    const ts = styles.find(x => x.name === g.name + '/' + st.name);
    if (ts) await sample.setTextStyleIdAsync(ts.id);
    add(row, meta, sample); list.appendChild(row); n++;
  }
}
return { page: page.id, board: b.id, rows: n, h: Math.round(b.height) };
