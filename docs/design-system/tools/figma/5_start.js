const T = await getJSON('tokens.json'); const V = await loadVars(); await loadDocFonts();
const page = getPage('시작', 'Page 2');
const b = board(page, '시작', 1440);
const hero = box('V', { gap: 16, pad: 56, radius: 20, fill: varPaint(V.light['brand-ink']), width: 1296, name: 'cover' });
add(hero, txt('Quill 디자인 시스템', { size: 56, weight: 700, lh: 64, fill: solid('#ffffff') }), txt('말로 쓰는 노트 앱. 화면은 조용하고, 녹음 중인 순간만 또렷해요.', { size: 20, lh: 28, fill: solid('#ffffff', 0.72), width: 1000 }),
  txt(`기준본: ${T.meta.repo} · docs/design-system  ·  토큰 기준 ${T.meta.ref} (${T.meta.synced})  ·  macOS · iPhone · iPad 공통`, { family: 'mono', size: 12, lh: 16, fill: varPaint(V.light['brand-glow']), width: 1100 }));
b.appendChild(hero);
function cards(title, sub, items, cols) {
  const s = section(b, title, sub);
  const w = Math.floor((1296 - 16 * (cols - 1)) / cols);
  const g = box('H', { gap: 16, wrap: true, wrapGap: 16, width: 1296, name: 'grid' }); s.appendChild(g);
  items.forEach(([h, d], i) => { const c = box('V', { gap: 8, pad: 20, radius: 12, stroke: LINE(), width: w, name: h });
    add(c, txt(h, { size: 15, weight: 600, lh: 20, width: w - 40 }), txt(d, { size: 13, lh: 19, fill: INK2(), width: w - 40 })); g.appendChild(c); });
}
cards('디자인 원칙', null, [
  ['1. 시스템이 먼저, 브랜드는 한 점', '앱 UI는 플랫폼의 의미 색과 시스템 글꼴로 그려요. 브랜드 색은 아이콘·스토어·웹사이트에만 써요. 사용자가 강조색을 바꾸면 Quill도 따라 바뀌어요.'],
  ['2. 녹음은 검정 알약', '녹음 상태는 테마와 상관없이 검정(overlay-surface) 위 흰 파형으로 보여 줘요. 노치·Dynamic Island와 이어 보이는 모양이 Quill의 얼굴이에요.'],
  ['3. 심각도는 아이콘 색에만', '경고·오류 배너는 중립 표면(fill-banner + hairline-strong)에 아이콘만 issue-warning / issue-error로 칠해요. 표면 전체를 빨갛게 칠하지 않아요.'],
  ['4. 새 규칙보다 있는 컴포넌트', '새 알림은 StatusBanner, 여러 개면 +N 알약으로 묶어요. 새 배너 모양, 새 색을 만들지 않아요.'],
  ['5. 접근성 설정을 그대로 존중', '동작 줄이기·투명도 줄이기·대비 높이기·색 구분 없이 보기 각각에 대체 표현이 있어요.'],
], 3);
cards('이 파일 보는 법', '왼쪽 페이지 목록에서 골라요.', [
  ['색', '의미 색 55개. 카드 왼쪽이 라이트, 오른쪽이 다크예요.'],
  ['글자', '역할별 글자 스타일 34개.'],
  ['간격 · 모양', '간격, 반경, 그림자, 불투명도, 크기, 폭 기준.'],
  ['컴포넌트', '원자 → 분자 → 유기체 → 화면 순서. 레포의 컴포넌트 미리보기를 그대로 옮긴 그림이에요.'],
], 4);
cards('알아 둘 점', null, [
  ['기준은 코드예요', '이 파일은 레포의 docs/design-system과 Packages/QuillDesignTokens에서 한 방향으로 내보낸 사본이에요. 값을 바꿀 때는 레포를 먼저 고치고 여기를 다시 만들어요.'],
  ['라이트·다크가 컬렉션 두 개', 'Figma 스타터 플랜은 변수 모드가 하나라서, 색 변수를 "Color · Light"와 "Color · Dark" 두 컬렉션에 같은 이름으로 넣었어요. 컴포넌트 그림은 라이트 기준이에요.'],
  ['글꼴 대체', 'SF Pro와 SF Pro Rounded 자리에 Pretendard, SF Mono 자리에 Menlo를 썼어요. 글자 폭이 실제 앱과 조금 달라요.'],
  ['시스템 색은 근사값', T.meta.note],
], 2);
return { page: page.id, board: b.id, h: Math.round(b.height) };
