// Replays the homepage hero from real Celorga frames: Start work on a TODO
// opens a new agent thread beside the note. The markup shows the finished
// frame, so readers who prefer reduced motion (or have scripts off) still see
// the outcome, and only animating readers download the other frames.
(() => {
  const root = document.querySelector("[data-hero-demo]");
  if (!root) return;
  const motion = window.matchMedia("(prefers-reduced-motion: reduce)");
  if (motion.matches) return;

  const frames = Object.fromEntries(
    [...root.querySelectorAll("img[data-frame]")].map((img) => [img.dataset.frame, img])
  );
  const pointer = root.querySelector(".celorga-hero-demo-pointer");
  // Control positions in the 1240x800 capture, as fractions of the frame.
  const spots = {
    rest: [0.56, 0.93],
    heading: [0.76, 0.49],
    startWork: [0.912, 0.49],
    sheetStart: [0.636, 0.47],
  };
  let timers = [];
  let running = false;
  let visible = false;
  let loaded = null;

  const at = (ms, fn) => timers.push(setTimeout(fn, ms));
  const show = (name) => {
    for (const [key, img] of Object.entries(frames)) img.classList.toggle("is-on", key === name);
  };
  const move = ([x, y]) => {
    pointer.style.left = `${x * 100}%`;
    pointer.style.top = `${y * 100}%`;
  };
  const click = (ms) => {
    at(ms, () => root.classList.add("is-click"));
    at(ms + 140, () => root.classList.remove("is-click"));
  };
  const load = () => loaded ??= Promise.all(Object.values(frames).map((img) => {
    if (img.dataset.src && !img.src) img.src = img.dataset.src;
    return img.decode().catch(() => {});
  }));

  const reset = () => {
    timers.forEach(clearTimeout);
    timers = [];
    root.classList.remove("is-pointer", "is-click");
    pointer.style.transition = "none";
    move(spots.rest);
    void pointer.offsetWidth;
    pointer.style.transition = "";
  };

  const play = () => {
    reset();
    show("before");
    at(400, () => root.classList.add("is-pointer"));
    at(600, () => move(spots.heading));
    at(1500, () => show("hover"));
    at(2100, () => move(spots.startWork));
    click(3000);
    at(3150, () => show("sheet"));
    at(3800, () => move(spots.sheetStart));
    click(4700);
    at(4850, () => { show("working"); root.classList.remove("is-pointer"); });
    at(7000, () => show("streaming"));
    at(9200, () => show("done"));
    at(15000, () => { if (running) play(); });
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
