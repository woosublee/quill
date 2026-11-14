// Paste into the DevTools console of the Figma file's browser tab (the editor exposes `figma` there).
// Needs server.py running and walk.html opened once. Each script replaces what it made before.
window.quillRun = async (name) => {
  const AsyncFunction = Object.getPrototypeOf(async function () {}).constructor;
  const get = async (file) => (await fetch('http://127.0.0.1:8765/' + file + '?' + Date.now())).text();
  return await new AsyncFunction((await get('lib.js')) + '\n' + (await get(name)))();
};
for (const name of ['1_tokens.js', '2_color.js', '3_type.js', '4_shape.js', '5_start.js', '6_components.js']) {
  console.log(name, JSON.stringify(await window.quillRun(name)));
}
