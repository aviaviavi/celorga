// Replays the homepage hero: a TODO in a note starts agent work in a new AI
// thread. The markup's default state is the finished scene, so readers who
// prefer reduced motion (or have scripts off) still see the whole story.
(() => {
  const root = document.querySelector("[data-hero-demo]");
  if (!root) return;
  const motion = window.matchMedia("(prefers-reduced-motion: reduce)");
  if (motion.matches) return;

  const win = root.querySelector(".chd-window");
  const cursor = root.querySelector(".chd-cursor");
  const steps = Object.fromEntries(
    [...root.querySelectorAll(".chd-step")].map((node) => [node.dataset.step, node])
  );
  const states = ["is-hover", "is-sheet", "is-press", "is-started", "is-done", "is-cursor", "is-click", "is-fading"];
  let timers = [];
  let running = false;
  let visible = false;

  const at = (ms, fn) => timers.push(setTimeout(fn, ms));
  const on = (...names) => root.classList.add(...names);
  const off = (...names) => root.classList.remove(...names);
  const show = (name) => steps[name]?.classList.add("is-on");

  // Moves the cursor tip to a point inside `selector`, in window coordinates.
  const point = (selector, fx = 0.5, fy = 0.55) => {
    const box = win.getBoundingClientRect();
    const target = root.querySelector(selector)?.getBoundingClientRect();
    if (!target) return;
    const x = target.left - box.left + target.width * fx;
    const y = target.top - box.top + target.height * fy;
    cursor.style.transform = `translate(${x}px, ${y}px)`;
  };
  const click = (offset) => {
    at(offset, () => on("is-click"));
    at(offset + 160, () => off("is-click"));
  };

  const reset = () => {
    timers.forEach(clearTimeout);
    timers = [];
    off(...states);
    Object.values(steps).forEach((node) => node.classList.remove("is-on"));
    const box = win.getBoundingClientRect();
    cursor.style.transition = "none";
    cursor.style.transform = `translate(${box.width * 0.36}px, ${box.height * 0.92}px)`;
    void cursor.offsetWidth;
    cursor.style.transition = "";
  };

  const play = () => {
    reset();
    root.classList.add("chd-live");
    at(500, () => on("is-cursor"));
    at(800, () => point(".chd-target > span:nth-of-type(3)", 0.4));
    at(1700, () => on("is-hover"));
    at(2300, () => point(".chd-start", 0.45));
    click(3200);
    at(3350, () => on("is-sheet"));
    at(4100, () => point(".chd-sheet-go", 0.5));
    click(5100);
    at(5150, () => on("is-press"));
    at(5450, () => {
      off("is-sheet", "is-press", "is-hover", "is-cursor");
      on("is-started");
    });
    at(6000, () => show("user"));
    at(6900, () => show("read1"));
    at(7500, () => show("read2"));
    at(8100, () => show("write"));
    at(8800, () => show("reply0"));
    at(9200, () => show("reply1"));
    at(9800, () => show("reply2"));
    at(10500, () => show("reply3"));
    at(11200, () => show("reply4"));
    at(12100, () => { on("is-done"); show("review"); });
    at(17500, () => on("is-fading"));
    at(18100, () => { if (running) play(); });
  };

  const start = () => {
    if (running || !visible || document.hidden) return;
    running = true;
    play();
  };
  const stop = () => {
    if (!running) return;
    running = false;
    reset();
    root.classList.remove("chd-live");
  };

  new IntersectionObserver((entries) => {
    visible = entries.some((entry) => entry.isIntersecting);
    visible ? start() : stop();
  }, { threshold: 0.35 }).observe(root);
  document.addEventListener("visibilitychange", () => (document.hidden ? stop() : start()));
  motion.addEventListener?.("change", (event) => event.matches && stop());
})();
