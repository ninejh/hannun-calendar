(() => {
  "use strict";
  const release = window.HANNUN_RELEASE;
  if (release && /^https:\/\/github\.com\/ninejh\/hannun-calendar$/.test(release.repository)) {
    const root = release.repository;
    const tag = encodeURIComponent(release.tag);
    const links = {
      repository: root,
      notes: `${root}/releases/tag/${tag}`,
      issues: `${root}/issues`,
      dmg: `${root}/releases/download/${tag}/${encodeURIComponent(release.dmg)}`,
      zip: `${root}/releases/download/${tag}/${encodeURIComponent(release.zip)}`
    };
    document.querySelectorAll("[data-release-link]").forEach(link => {
      const href = links[link.dataset.releaseLink];
      if (href) link.href = href;
    });
    document.querySelectorAll("[data-release-version]").forEach(node => { node.textContent = release.tag; });
  }

  // Everything is readable before this optional motion enhancement runs.
  if (!("IntersectionObserver" in window) || !("matchMedia" in window)) return;
  const reduced = window.matchMedia("(prefers-reduced-motion: reduce)");
  const desktop = window.matchMedia("(min-width: 761px)");
  const stage = document.querySelector(".board-stage");
  const showcase = document.querySelector(".hero-showcase");
  const story = document.querySelector(".story-layout");
  const storyImage = document.querySelector(".story-image");
  const progressBar = document.querySelector(".story-track span");
  const storyCurrent = document.querySelector(".story-current");
  const storyCount = document.querySelector(".story-count");
  const steps = [...document.querySelectorAll(".story-step")];
  const labels = ["한 달의 흐름", "오늘과 가까워지는 마감", "프로젝트의 작은 진전"];
  let frame = 0;
  let entryTimer = 0;
  let entered = false;
  let lastIndex = -1;
  let listening = false;
  const visible = new Set();
  const clamp = (n, min = 0, max = 1) => Math.min(max, Math.max(min, n));

  const stopEntry = () => {
    clearTimeout(entryTimer);
    stage.classList.remove("board-entering");
  };
  const enterBoard = () => {
    if (entered || reduced.matches || document.hidden) return;
    entered = true;
    stage.classList.add("board-entering");
    entryTimer = setTimeout(stopEntry, 1100);
  };
  const render = () => {
    frame = 0;
    if (reduced.matches || document.hidden) return;
    if (visible.has(showcase) && desktop.matches) {
      const box = showcase.getBoundingClientRect();
      const drift = clamp(-box.top / Math.max(box.height, 1), 0, 1) * 12;
      showcase.style.transform = `translate3d(0, ${drift.toFixed(2)}px, 0)`;
    }
    if (visible.has(story) && desktop.matches) {
      const focusLine = window.innerHeight * .5;
      const first = steps[0].getBoundingClientRect();
      const last = steps[2].getBoundingClientRect();
      const start = first.top + first.height / 2;
      const finish = last.top + last.height / 2;
      const progress = clamp((focusLine - start) / Math.max(finish - start, 1));
      // A modest camera move through the real screenshot, not a simulated app.
      const wave = Math.sin(progress * Math.PI);
      const scale = 1 + .15 * wave;
      const x = -3 * wave;
      const y = -3.5 * progress;
      storyImage.style.transform = `translate3d(${x.toFixed(3)}%, ${y.toFixed(3)}%, 0) scale(${scale.toFixed(4)})`;
      progressBar.style.transform = `scaleX(${(.08 + progress * .92).toFixed(4)})`;
      const index = Math.min(2, Math.round(progress * 2));
      if (index !== lastIndex) {
        storyCurrent.textContent = labels[index];
        storyCount.textContent = `0${index + 1} / 03`;
        lastIndex = index;
      }
    }
  };
  const schedule = () => {
    if (!frame && visible.size && !reduced.matches && !document.hidden) frame = requestAnimationFrame(render);
  };
  const syncListeners = () => {
    const shouldListen = visible.size > 0 && !reduced.matches && !document.hidden && desktop.matches;
    if (shouldListen === listening) return;
    listening = shouldListen;
    if (listening) {
      window.addEventListener("scroll", schedule, { passive: true });
      window.addEventListener("resize", schedule, { passive: true });
      schedule();
    } else {
      window.removeEventListener("scroll", schedule);
      window.removeEventListener("resize", schedule);
      cancelAnimationFrame(frame);
      frame = 0;
    }
  };
  const regionObserver = new IntersectionObserver(entries => {
    entries.forEach(entry => {
      if (entry.isIntersecting) {
        visible.add(entry.target);
        if (entry.target === showcase) enterBoard();
      } else visible.delete(entry.target);
    });
    syncListeners();
    schedule();
  }, { threshold: 0 });
  regionObserver.observe(showcase);
  regionObserver.observe(story);

  const revealObserver = new IntersectionObserver(entries => {
    entries.forEach(entry => {
      if (!entry.isIntersecting) return;
      if (!reduced.matches && !document.hidden) entry.target.classList.add("reveal-in");
      revealObserver.unobserve(entry.target);
    });
  }, { threshold: .12 });
  document.querySelectorAll(".section-heading, .panel-introduction, .details-grid article, .download-layout").forEach(node => revealObserver.observe(node));

  const resetMotion = () => {
    if (reduced.matches || !desktop.matches) {
      stopEntry();
      showcase.style.removeProperty("transform");
      storyImage.style.removeProperty("transform");
      progressBar.style.removeProperty("transform");
      document.querySelectorAll(".reveal-in").forEach(node => node.classList.remove("reveal-in"));
    }
    syncListeners();
    schedule();
  };
  reduced.addEventListener("change", resetMotion);
  desktop.addEventListener("change", resetMotion);
  document.addEventListener("visibilitychange", () => {
    if (document.hidden) stopEntry();
    syncListeners();
    schedule();
  });
  window.addEventListener("pagehide", () => {
    stopEntry();
    cancelAnimationFrame(frame);
    frame = 0;
  });
})();
