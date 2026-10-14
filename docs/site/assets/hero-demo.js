// Replays the homepage hero from real Celorga frames: Start work on a TODO
// opens a new agent thread beside the note. The markup shows the finished
// frame, so readers who prefer reduced motion (or have scripts off) still see
// the outcome, and only animating readers download the other frames. The
// script crossfades frames, moves a pointer between real controls, and zooms
// toward whatever is happening; it never draws app UI.
(() => {
  const root = document.querySelector("[data-hero-demo]");
  if (!root) return;
  const motion = window.matchMedia("(prefers-reduced-motion: reduce)");
  if (motion.matches) return;

  const stage = root.querySelector(".celorga-hero-demo-stage");
  const frames = Object.fromEntries(
    [...root.querySelectorAll("img[data-frame]")].map((img) => [img.dataset.frame, img])
  );
  const pointer = root.querySelector(".celorga-hero-demo-pointer");
  // Control positions in the 883x734 capture, as fractions of the frame.
  const spots = {
    rest: [0.34, 0.92],
    heading: [0.74, 0.484],
    startWork: [0.905, 0.484],
    sheetStart: [0.523, 0.462],
  };
  // Where the camera looks, and how close.
  const views = {
    all: [[0.5, 0.5], 1],
    heading: [[0.72, 0.48], 1.3],
    sheet: [[0.33, 0.27], 1.3],
    chat: [[0.2, 0.3], 1.35],
  };
  let timers = [];
  let running = false;
  let visible = false;
  let loaded = null;

  const at = (ms, fn) => timers.push(setTimeout(fn, ms));
  // Fade the next frame in above the current one, which stays opaque until it
  // is covered, so the page never shows through mid-fade.
  let layer = 1;
  let settle = null;
  const show = (name) => {
    const next = frames[name];
    if (next.classList.contains("is-on") && next.style.zIndex == layer) return;
    next.style.zIndex = ++layer;
    next.classList.add("is-on");
    clearTimeout(settle);
    settle = setTimeout(() => {
      for (const img of Object.values(frames)) if (img !== next) img.classList.remove("is-on");
    }, 400);
  };
  const move = ([x, y]) => {
    pointer.style.left = `${x * 100}%`;
    pointer.style.top = `${y * 100}%`;
  };
  // Centers the focus point when it can, without uncovering the frame edges.
  const look = (name) => {
    const [[fx, fy], scale] = views[name];
    const shift = (f) => Math.min(0, Math.max(100 - 100 * scale, 50 - scale * f * 100));
    stage.style.transform = `translate(${shift(fx)}%, ${shift(fy)}%) scale(${scale})`;
  };
  const click = (ms) => {
    at(ms, () => root.classList.add("is-click"));
    at(ms + 140, () => root.classList.remove("is-click"));
  };
  const load = () => loaded ??= Promise.all(Object.values(frames).map((img) => {
    if (img.dataset.src && !img.src) img.src = img.dataset.src;
    return img.decode().catch(() => {});
  }));

  const jump = (fn) => {
    for (const node of [pointer, stage]) node.style.transition = "none";
    fn();
    void stage.offsetWidth;
    for (const node of [pointer, stage]) node.style.transition = "";
  };
  const reset = () => {
    clearTimeout(settle);
    timers.forEach(clearTimeout);
    timers = [];
    root.classList.remove("is-pointer", "is-click");
    jump(() => { move(spots.rest); look("all"); });
  };

  const play = () => {
    reset();
    show("before");
    at(500, () => { root.classList.add("is-pointer"); move(spots.heading); look("heading"); });
    at(1700, () => show("hover"));
    at(2300, () => move(spots.startWork));
    click(3200);
    at(3350, () => { show("sheet"); look("sheet"); });
    at(4200, () => move(spots.sheetStart));
    click(5100);
    at(5250, () => { show("working"); root.classList.remove("is-pointer"); look("chat"); });
    at(7400, () => show("streaming"));
    at(9600, () => show("done"));
    at(11200, () => look("all"));
    at(17000, () => { if (running) play(); });
  };

  const start = () => {
    if (running || !visible || document.hidden) return;
    running = true;
    load().then(() => { if (running) play(); });
  };
  const stop = () => {
    if (!running) return;
    running = false;
    reset();
    show("done");
  };

  new IntersectionObserver((entries) => {
    visible = entries.some((entry) => entry.isIntersecting);
    visible ? start() : stop();
  }, { threshold: 0.35 }).observe(root);
  document.addEventListener("visibilitychange", () => (document.hidden ? stop() : start()));
  motion.addEventListener?.("change", (event) => event.matches && stop());
})();
