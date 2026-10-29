// Homepage motion: rotating words, the tilted product window, the agents
// marquee, looping feature scenes, and scroll reveals. Everything is
// progressive: the markup already shows each scene's finished state, and this
// script only animates when the reader has not asked for reduced motion
// (index.org adds .celorga-motion to <html> before first paint).
(() => {
  const root = document.documentElement;
  const motion = root.classList.contains("celorga-motion");

  // Copy buttons work regardless of motion preference.
  for (const button of document.querySelectorAll("[data-copy]")) {
    button.addEventListener("click", () => {
      const label = button.querySelector("[data-copy-label]");
      navigator.clipboard?.writeText(button.dataset.copy).then(() => {
        if (!label) return;
        label.textContent = "Copied";
        setTimeout(() => (label.textContent = "Copy"), 1600);
      });
    });
  }

  if (!motion) return;

  const whenVisible = (node, onShow, onHide, threshold = 0.3) => {
    new IntersectionObserver((entries) => {
      for (const entry of entries) (entry.isIntersecting ? onShow : onHide)?.();
    }, { threshold }).observe(node);
  };

  // Rotating words: each child takes a turn; the box eases to the new width.
  for (const rotator of document.querySelectorAll("[data-rotator]")) {
    const words = [...rotator.children];
    if (words.length < 2) continue;
    const interval = Number(rotator.dataset.interval) || 2300;
    let index = Math.max(0, words.findIndex((w) => w.classList.contains("is-on")));
    let timer = null;
    const fit = () => (rotator.style.width = `${words[index].scrollWidth}px`);
    const step = () => {
      const previous = words[index];
      index = (index + 1) % words.length;
      previous.classList.remove("is-on");
      previous.classList.add("is-out");
      setTimeout(() => previous.classList.remove("is-out"), 600);
      words[index].classList.add("is-on");
      fit();
    };
    document.fonts?.ready.then(fit);
    fit();
    whenVisible(rotator, () => (timer ??= setInterval(step, interval)), () => {
      clearInterval(timer);
      timer = null;
    }, 0);
  }

  // Product window: starts tilted back and settles flat as it scrolls up.
  const stage = document.querySelector("[data-tilt]");
  const tiltTarget = stage?.querySelector(".celorga-hero2-window");
  if (stage && tiltTarget && window.matchMedia("(min-width: 760px)").matches) {
    let queued = false;
    const update = () => {
      queued = false;
      const rect = stage.getBoundingClientRect();
      const vh = window.innerHeight;
      const progress = Math.min(1, Math.max(0, (rect.top - vh * 0.12) / (vh * 0.6)));
      tiltTarget.style.setProperty("--tilt", `${(progress * 16).toFixed(2)}deg`);
      tiltTarget.style.setProperty("--tilt-scale", (1 - progress * 0.05).toFixed(3));
    };
    update();
    window.addEventListener("scroll", () => {
      if (!queued) {
        queued = true;
        requestAnimationFrame(update);
      }
    }, { passive: true });
    window.addEventListener("resize", update);
  }

  // Agents marquee: duplicate the list once so the loop is seamless.
  for (const marquee of document.querySelectorAll(".celorga-marquee")) {
    const track = marquee.querySelector(".celorga-marquee-track");
    if (!track) continue;
    for (const item of [...track.children]) {
      const clone = item.cloneNode(true);
      clone.setAttribute("aria-hidden", "true");
      track.append(clone);
    }
    marquee.classList.add("is-ready");
  }

  // Timeline scenes: [data-at] parts appear at that millisecond, [data-off]
  // parts leave. Each scene loops while it is on screen.
  const extras = {
    publish: [[900, (s) => s.classList.add("is-redacting")]],
    prose: [[3800, (s) => s.classList.add("is-selecting")]],
  };
  for (const scene of document.querySelectorAll('[data-demo="timeline"]')) {
    const loop = Number(scene.dataset.loop) || 9000;
    const parts = [...scene.querySelectorAll("[data-at], [data-off]")];
    const kind = [...scene.classList].find((c) => c.startsWith("celorga-demo-"))?.slice(13);
    let timers = [];
    const clear = () => {
      timers.forEach(clearTimeout);
      timers = [];
    };
    const reset = () => {
      scene.classList.remove("is-redacting", "is-selecting");
      for (const part of parts) part.classList.remove("is-on", "is-off");
    };
    const play = () => {
      clear();
      reset();
      for (const part of parts) {
        if (part.dataset.at) timers.push(setTimeout(() => part.classList.add("is-on"), Number(part.dataset.at)));
        if (part.dataset.off) timers.push(setTimeout(() => part.classList.add("is-off"), Number(part.dataset.off)));
      }
      for (const [ms, fn] of extras[kind] || []) timers.push(setTimeout(() => fn(scene), ms));
      timers.push(setTimeout(() => {
        reset();
        timers.push(setTimeout(play, 700));
      }, loop));
    };
    reset();
    whenVisible(scene, () => timers.length || play(), () => {
      clear();
      reset();
    }, 0.35);
  }

  // Encryption scene: the same heading as each agent sees it.
  const glyphs = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/=";
  const cipherFor = (text, seed) => {
    let out = "";
    let x = seed;
    for (let i = 0; i < text.length; i += 1) {
      x = (x * 9301 + 49297) % 233280;
      out += glyphs[Math.floor((x / 233280) * glyphs.length)];
    }
    return out;
  };
  for (const scene of document.querySelectorAll('[data-demo="crypt"]')) {
    const file = scene.querySelector(".celorga-crypt-file");
    const lock = scene.querySelector(".celorga-crypt-lock use");
    const tabs = [...scene.querySelectorAll("[data-viewer]")];
    const lines = [...scene.querySelectorAll(".celorga-crypt-line")].map((node, i) => ({
      node,
      plain: node.dataset.plain,
      cipher: cipherFor(node.dataset.plain, 17 + i * 31),
    }));
    const order = ["you", "codex", "claude"];
    let index = 0;
    let timer = null;
    let frame = null;
    const morph = (toCipher) => {
      cancelAnimationFrame(frame);
      const start = performance.now();
      const duration = 750;
      const tick = (now) => {
        const p = Math.min(1, (now - start) / duration);
        for (const line of lines) {
          const target = toCipher ? line.cipher : line.plain;
          const cut = Math.floor(p * target.length);
          let text = target.slice(0, cut);
          for (let i = cut; i < target.length; i += 1) {
            text += target[i] === " " && !toCipher ? " " : glyphs[Math.floor(Math.random() * glyphs.length)];
          }
          line.node.textContent = text;
        }
        if (p < 1) frame = requestAnimationFrame(tick);
      };
      frame = requestAnimationFrame(tick);
    };
    const view = (name) => {
      scene.dataset.viewer = name;
      for (const tab of tabs) tab.classList.toggle("is-on", tab.dataset.viewer === name);
      const sealed = name === "codex";
      const wasSealed = file.classList.contains("is-sealed");
      file.classList.toggle("is-sealed", sealed);
      lock?.setAttribute("href", sealed ? "#glyph-lock" : "#glyph-unlock");
      if (sealed !== wasSealed) morph(sealed);
    };
    const step = () => {
      index = (index + 1) % order.length;
      view(order[index]);
    };
    whenVisible(scene, () => (timer ??= setInterval(step, 2600)), () => {
      clearInterval(timer);
      timer = null;
    });
  }

  // Bento spotlight follows the pointer.
  for (const card of document.querySelectorAll(".celorga-bento-card")) {
    card.addEventListener("pointermove", (event) => {
      const rect = card.getBoundingClientRect();
      card.style.setProperty("--mx", `${event.clientX - rect.left}px`);
      card.style.setProperty("--my", `${event.clientY - rect.top}px`);
    });
  }

  // Scroll reveals below the hero. Siblings in a grid arrive in a short stagger.
  const groups = [
    [".celorga-harness2 .celorga-home-harnesses-copy", ".celorga-harness2 .celorga-marquee", ".celorga-harness2 .celorga-home-harness-mcp"],
    [".celorga-bento-head"],
    [".celorga-bento-card", 3],
    [".celorga-home-story-copy"],
    [".celorga-home-story-media"],
    ["main > .celorga-home-anywhere .celorga-sample-intro, .celorga-home-both .celorga-sample-intro, .celorga-home-uses .celorga-sample-intro, .celorga-home-own .celorga-sample-intro, .celorga-home-platforms .celorga-sample-intro, .celorga-sample .celorga-sample-intro, .celorga-home-start .celorga-sample-intro"],
    [".celorga-topology"],
    [".celorga-home-both-grid article", 2],
    [".celorga-home-uses-grid article", 3],
    [".celorga-home-own .celorga-feature-card-grid article", 3],
    [".celorga-home-platform-grid a", 3],
    [".celorga-lineage-note"],
    [".celorga-sample-layout"],
    [".celorga-cta2"],
    [".celorga-home-start-links a", 4],
  ];
  const revealer = new IntersectionObserver((entries) => {
    for (const entry of entries) {
      if (!entry.isIntersecting) continue;
      entry.target.classList.add("is-in");
      revealer.unobserve(entry.target);
    }
  }, { threshold: 0.12, rootMargin: "0px 0px -6% 0px" });
  for (const group of groups) {
    const selectors = group.filter((s) => typeof s === "string");
    const columns = group.find((s) => typeof s === "number") || 0;
    const nodes = selectors.flatMap((s) => [...document.querySelectorAll(`#content ${s.split(",").join(", #content ")}`)]);
    nodes.forEach((node, i) => {
      if (node.closest(".celorga-hero2")) return;
      node.classList.add("celorga-reveal");
      if (columns) node.style.setProperty("--reveal-i", String(i % columns));
      revealer.observe(node);
    });
  }
})();
