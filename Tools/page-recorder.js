// Records mouse and keyboard input (mouse events, not pointer events: only they carry click counts) in a web page in the format colorlearn-harness reads.
// Paste into the page's console (or inject it with a browser automation tool), demonstrate,
// then read window.__dbrec.take().
(() => {
  if (window.__dbrec) return 'already installed';
  const t0 = performance.now();
  let events = [];
  let down = false;
  const now = () => (performance.now() - t0) / 1000;
  const mods = (e) => ({ shift: e.shiftKey, ctrl: e.ctrlKey, alt: e.altKey, meta: e.metaKey });
  const opts = { capture: true, passive: true };
  addEventListener('mousedown', (e) => {
    down = true;
    events.push({ kind: 'down', t: now(), x: e.clientX, y: e.clientY, button: e.button, count: Math.max(1, e.detail || 1), ...mods(e) });
  }, opts);
  addEventListener('mousemove', (e) => {
    if (down) events.push({ kind: 'drag', t: now(), x: e.clientX, y: e.clientY, button: 0, ...mods(e) });
  }, opts);
  addEventListener('mouseup', (e) => {
    down = false;
    events.push({ kind: 'up', t: now(), x: e.clientX, y: e.clientY, button: e.button, count: Math.max(1, e.detail || 1), ...mods(e) });
  }, opts);
  addEventListener('keydown', (e) => {
    events.push({ kind: 'key', t: now(), key: e.key, code: e.code, ...mods(e) });
  }, opts);
  addEventListener('paste', (e) => {
    const last = [...events].reverse().find((x) => x.kind === 'key');
    if (last) last.paste = e.clipboardData ? e.clipboardData.getData('text') : null;
  }, opts);
  window.__dbrec = {
    take() { const out = events; events = []; return out; },
    clear() { events = []; },
    get count() { return events.length; },
  };
  return 'installed';
})();
