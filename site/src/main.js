(() => {
  const reduce = matchMedia("(prefers-reduced-motion: reduce)").matches;

  // Nav hairline after scrolling
  const nav = document.querySelector(".nav");
  const onScroll = () => nav.classList.toggle("scrolled", scrollY > 8);
  addEventListener("scroll", onScroll, { passive: true });
  onScroll();

  // Menu bar clock
  const clock = document.querySelector("[data-clock]");
  if (clock) {
    const fmt = new Intl.DateTimeFormat(document.documentElement.lang, { hour: "numeric", minute: "2-digit" });
    const tick = () => { clock.textContent = fmt.format(new Date()); };
    tick();
    setInterval(tick, 15000);
  }

  // Timecode at 30 fps, running while recording
  const app = document.querySelector("[data-app]");
  const tcs = document.querySelectorAll("[data-tc]");
  let frames = ((12 * 60 + 48) * 30) + 6;
  let last = performance.now();
  const pad = (n) => String(n).padStart(2, "0");
  const showTC = () => {
    const f = frames % 30, s = Math.floor(frames / 30);
    const text = `${pad(Math.floor(s / 3600))}:${pad(Math.floor(s / 60) % 60)}:${pad(s % 60)}:${pad(f)}`;
    tcs.forEach((el) => { el.textContent = text; });
  };

  // Record button
  const rec = document.querySelector("[data-rec]");
  const recWord = document.querySelector("[data-recword]");
  rec?.addEventListener("click", () => {
    const on = !app.classList.contains("is-rec");
    app.classList.toggle("is-rec", on);
    rec.setAttribute("aria-pressed", String(on));
    recWord.textContent = on ? "REC" : "STBY";
  });

  // Control bar: shows on pointer movement, hides 3 s after it stops
  const bar = document.querySelector("[data-bar]");
  let hideTimer;
  if (app && bar) {
    const show = () => { app.classList.remove("bar-hidden"); };
    app.addEventListener("pointermove", (e) => {
      show();
      clearTimeout(hideTimer);
      if (e.pointerType === "mouse" && !bar.contains(e.target)) {
        hideTimer = setTimeout(() => app.classList.add("bar-hidden"), 3000);
      }
    });
    app.addEventListener("pointerleave", () => { clearTimeout(hideTimer); show(); });

    // Play the hide once, the first time the window is on screen, so the behavior shows without a hover
    if ("IntersectionObserver" in window && !reduce) {
      const once = new IntersectionObserver(([en]) => {
        if (!en.isIntersecting) return;
        once.disconnect();
        setTimeout(() => {
          if (app.matches(":hover")) return;
          app.classList.add("bar-hidden");
          setTimeout(() => { if (!app.matches(":hover")) show(); }, 1600);
        }, 3000);
      }, { threshold: 0.6 });
      once.observe(app);
    }
  }

  // Click the video to focus there
  const video = document.querySelector("[data-video]");
  const reticle = document.querySelector("[data-reticle]");
  let fadeTimer;
  video?.addEventListener("click", (e) => {
    const r = video.getBoundingClientRect();
    reticle.style.left = `${((e.clientX - r.left) / r.width) * 100}%`;
    reticle.style.top = `${((e.clientY - r.top) / r.height) * 100}%`;
    reticle.classList.remove("fade");
    reticle.classList.add("on");
    clearTimeout(fadeTimer);
    fadeTimer = setTimeout(() => { reticle.classList.add("fade"); reticle.classList.remove("on"); }, 1000);
  });

  // Audio meters: Blackmagic scale, compressed below -20 dBFS
  const pos = (db) => (db <= -20 ? Math.max(0, (db + 60) / 40) * 50 : 50 + ((db + 20) / 20) * 50);
  const color = (db) => (db < -20 ? "var(--green)" : db < -9 ? "var(--yellow)" : "var(--rec)");
  const small = [...document.querySelectorAll("[data-meter] i")];
  const big = [...document.querySelectorAll("[data-meter-big] .track")];
  const chans = [{ db: -28, target: -24, peak: -20, held: 0 }, { db: -29, target: -25, peak: -21, held: 0 }];

  const paint = () => {
    chans.forEach((c, i) => {
      [small[i], big[i]].forEach((el) => {
        if (!el) return;
        el.style.setProperty("--l", `${pos(c.db).toFixed(1)}%`);
        el.style.setProperty("--c", color(c.db));
      });
      if (big[i]) big[i].style.setProperty("--p", `${pos(c.peak).toFixed(1)}%`);
    });
  };

  // Speech-like envelope: syllables, short pauses, the odd loud word
  let syllable = 0;
  const step = (dt) => {
    syllable -= dt;
    if (syllable <= 0) {
      const pause = Math.random() < 0.18;
      const loud = Math.random() < 0.08;
      const base = pause ? -46 - Math.random() * 8 : loud ? -10 - Math.random() * 3 : -27 + Math.random() * 12;
      chans[0].target = base;
      chans[1].target = base - 0.5 - Math.random() * 2;
      syllable = pause ? 260 + Math.random() * 300 : 110 + Math.random() * 160;
    }
    chans.forEach((c) => {
      const k = c.target > c.db ? 0.55 : 0.16;
      c.db += (c.target - c.db) * k;
      if (c.db >= c.peak) { c.peak = c.db; c.held = 1000; }
      else if (c.held > 0) c.held -= dt;
      else c.peak = Math.max(c.db, c.peak - (20 / 1700) * dt);
    });
  };

  let visible = true;
  if ("IntersectionObserver" in window) {
    const seen = new Set();
    const io = new IntersectionObserver((entries) => {
      entries.forEach((en) => (en.isIntersecting ? seen.add(en.target) : seen.delete(en.target)));
      visible = seen.size > 0;
    });
    document.querySelectorAll("[data-app], [data-meter-big], .m-status").forEach((el) => io.observe(el));
  }

  paint();
  showTC();
  let acc = 0;
  const loop = (now) => {
    const dt = Math.min(100, now - last);
    last = now;
    if (visible && !document.hidden) {
      if (app?.classList.contains("is-rec")) {
        acc += dt;
        const adv = Math.floor(acc / (1000 / 30));
        if (adv) { frames += adv; acc -= adv * (1000 / 30); showTC(); }
      }
      if (!reduce) { step(dt); paint(); }
    }
    requestAnimationFrame(loop);
  };
  requestAnimationFrame(loop);

  // Feature rail arrows
  const rail = document.querySelector("[data-rail]");
  const prev = document.querySelector("[data-rail-prev]");
  const next = document.querySelector("[data-rail-next]");
  if (rail && prev && next) {
    const by = () => {
      const card = rail.querySelector(".card");
      return card ? card.getBoundingClientRect().width + parseFloat(getComputedStyle(rail).columnGap || 20) : 360;
    };
    const update = () => {
      prev.disabled = rail.scrollLeft < 4;
      next.disabled = rail.scrollLeft + rail.clientWidth >= rail.scrollWidth - 4;
    };
    prev.addEventListener("click", () => rail.scrollBy({ left: -by(), behavior: reduce ? "auto" : "smooth" }));
    next.addEventListener("click", () => rail.scrollBy({ left: by(), behavior: reduce ? "auto" : "smooth" }));
    rail.addEventListener("scroll", update, { passive: true });
    addEventListener("resize", update);
    update();
  }
})();
