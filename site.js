// Castor download page: picks the right file from the latest GitHub Release
// for this computer, and explains the rest. Japanese text lives in the HTML;
// English is below. Without the GitHub API the buttons open the Release page.
(() => {
  "use strict";
  const REPO = "Methurcoder/Castor";
  const RELEASES = `https://github.com/${REPO}/releases/latest`;

  const EN = {
    "nav.download": "Download", "nav.github": "GitHub",
    "hero.tagline": "Turn your own illustration into a little companion on your desktop.",
    "hero.lead": "Drop in one picture. It breathes, follows you with its eyes, and talks back.",
    "hero.cta": "Download free", "hero.github": "View on GitHub",
    "f1.title": "Moves from a single picture", "f1.text": "Cut-out, face position and parts are automatic. If something is off, nudge the face markers by hand.",
    "f2.title": "Watches you, reacts to pets", "f2.text": "Blinking, breathing, gaze and lip movement. Hold ⌥ to see and click through it while you work.",
    "f3.title": "Talks back", "f3.text": "Chat with a local AI (LM Studio / Ollama) only, if you like.",
    "dl.title": "Download", "dl.loading": "Checking the latest version…",
    "dl.release": "Latest: {v}", "dl.failed": "Could not reach GitHub. The buttons open the Release page.",
    "dl.mobile": "Castor is a desktop app. Open this page on a Mac or Windows PC.",
    "mac.req": "macOS 26.5 or later · Apple silicon (M1 or later)", "mac.button": "Download for Mac",
    "mac.s1": "Open the downloaded .dmg and drag Castor into Applications",
    "mac.s1.setup": "Open the downloaded zip, launch CastorSetup and choose Download / Update",
    "mac.s2": "On first launch only, allow it in System Settings › Privacy & Security › Open Anyway",
    "mac.s3": "When Castor opens, drop in a picture",
    "mac.video": "Watch the first-launch steps",
    "win.req": "Windows 10 / 11 (64-bit)", "win.button": "Download for Windows",
    "win.s1": "Extract the downloaded zip and open CastorSetup.exe",
    "win.s2": "If “Windows protected your PC” appears, choose More info › Run anyway",
    "win.s3": "Follow the setup to install, then launch Castor",
    "win.preview": "The Windows version is a public preview.",
    "files.title": "Which file on the Release page is which",
    "files.lead": "The buttons above are all most people need. The Release page lists these files by purpose:",
    "files.name": "File", "files.use": "Purpose",
    "more.title": "Updates, removal and signing",
    "more.update": "Update, repair or remove at any time with the setup (on Mac, open it from Castor's settings). Your pets and settings stay.",
    "more.sign": "Castor is not signed by Apple or Microsoft yet, so the OS asks for confirmation on first launch. Downloads are checked against the publisher's SHA-256 list.",
    "more.help": "If something goes wrong, tell us in GitHub Issues.",
    "safe.title": "Made to be safe to use",
    "safe.free": "Free and open source", "safe.free.text": "All source code is on GitHub (MIT License).",
    "safe.local": "Your art stays on your computer", "safe.local.text": "Cut-out and face estimation run on this device.",
    "safe.ai": "You choose the AI", "safe.ai.text": "A local AI, or Codex / Claude Code. Castor asks every time before sending anything out.",
    "faq.title": "FAQ",
    "faq.q1": "Does any picture work?", "faq.a1": "Front-facing pictures with a clear face move best. If it goes wrong, you can fix the face markers by hand.",
    "faq.q2": "Does it cost anything?", "faq.a2": "No. Only an external AI service you choose may charge you.",
    "faq.q3": "Which pictures can I use?", "faq.a3": "Your own art, or pictures you are allowed to use.",
    "foot.skin": "Change the look", "foot.auto": "Auto",
    "intro.skip": "Skip",
    "foot.license": "License (MIT)", "foot.issues": "Contact (Issues)", "foot.lineage": "Castor is the successor to Pomegranate",
    "badge": "Your computer",
    "star.pill": "Star", "star.you": "Your star",
    "star.title": "Add your star to the night sky.",
    "star.lead": "Castor is the name of a bright star in Gemini. A ★ on GitHub turns straight into energy for the next feature.",
    "star.button": "Star on GitHub", "star.now": "{v} stars so far",
    "star.thanks": "Thank you",
    "thanks.title": "Your download has started",
    "thanks.text": "While you wait, add a star to Gemini. Stars are free and mean the world to an indie project like Castor.",
    "thanks.star": "Star it", "thanks.later": "Later",
  };
  const JA_EXTRA = {
    "mac.s1.setup": "ダウンロードした zip を開き、CastorSetup を起動して「取得・更新」",
    "dl.release": "最新版: {v}", "dl.failed": "GitHub に接続できませんでした。ボタンから Release ページを開けます。",
    "badge": "このパソコン",
    "star.now": "いま ★ {v}",
  };

  // What each Release file is for, by name pattern.
  const FILES = [
    { match: /^Castor-v.+-macos_arm64\.dmg$/, ja: "Mac 版の本体（ディスクイメージ）。開いてアプリケーションへドラッグ", en: "Mac app (disk image). Open it and drag to Applications", rec: "mac" },
    { match: /^CastorSetup-v.+-windows_x86_64\.zip$/, ja: "Windows 版のセットアップ。導入・更新・修復・削除", en: "Windows setup: install, update, repair, remove", rec: "win" },
    { match: /^CastorSetup-v.+-macos_arm64\.zip$/, ja: "Mac 版のセットアップ。導入・更新・修復", en: "Mac setup: install, update, repair" },
    { match: /^Castor-v.+-macos_arm64\.zip$/, ja: "Mac 版の本体そのもの（zip）。セットアップが内部で使います", en: "Mac app itself (zip); the setup downloads this" },
    { match: /^Castor-v.+-windows_x86_64\.zip$/, ja: "Windows 版の本体そのもの（zip）。セットアップが内部で使います", en: "Windows app itself (zip); the setup downloads this" },
    { match: /^CastorNeuralTTS-v.+\.zip$/, ja: "任意の高品質音声（Qwen 3 TTS）の補助アプリ。あとからセットアップで追加できます", en: "Optional high-quality voice helper (Qwen 3 TTS); add it later from the setup" },
    { match: /^Castor-Downloader\.zip$/, ja: "コマンドで取得する人向けのスクリプト（上級者向け）", en: "Command-line download scripts (advanced)" },
    { match: /^castor-downloads\.json$/, ja: "ファイルの指紋（SHA-256）の一覧。アプリが照合に使います", en: "SHA-256 list of the files; used by the apps for checking" },
  ];

  let language = (navigator.language || "ja").toLowerCase().startsWith("ja") ? "ja" : "en";
  try { language = localStorage.getItem("castor.lang") || language; } catch (_) { /* private mode */ }
  const JA = {};
  document.querySelectorAll("[data-t]").forEach((el) => { JA[el.dataset.t] = el.textContent; });
  Object.assign(JA, JA_EXTRA);
  const t = (key, v) => ((language === "en" ? EN : JA)[key] || JA[key] || key).replace("{v}", v || "");

  let release = null;
  let releaseFailed = false;

  function detectOS() {
    const platform = (navigator.userAgentData && navigator.userAgentData.platform) || navigator.platform || "";
    const agent = navigator.userAgent || "";
    if (/android|iphone|ipad|ipod/i.test(agent) || (navigator.userAgentData && navigator.userAgentData.mobile)) return "mobile";
    if (/mac/i.test(platform) || /Macintosh/.test(agent)) return "mac";
    if (/win/i.test(platform) || /Windows/.test(agent)) return "win";
    return "other";
  }

  let render = function () {
    document.documentElement.lang = language;
    document.querySelectorAll("[data-t]").forEach((el) => { el.textContent = t(el.dataset.t); });
    document.getElementById("lang").textContent = language === "ja" ? "English" : "日本語";
    const promo = document.getElementById("promo");
    const promoSource = `assets/promo-${language}.mp4`;
    if (!promo.src.endsWith(promoSource)) { promo.src = promoSource; promo.play().catch(() => {}); }
    document.getElementById("firstLaunch").src = `assets/first-launch-mac-${language}.mp4`;
    document.querySelectorAll(".platform .os").forEach((title) => title.setAttribute("data-badge", t("badge")));

    const line = document.getElementById("releaseLine");
    if (release) line.textContent = t("dl.release", release.tag_name);
    else if (releaseFailed) line.textContent = t("dl.failed");

    const assets = release ? release.assets : [];
    const pick = (re) => assets.find((a) => re.test(a.name));
    const mac = pick(FILES[0].match) || pick(FILES[2].match);
    const win = pick(FILES[1].match);
    setButton("mac", mac);
    // The dmg is dragged to Applications; the setup zip installs by itself.
    const macStep = document.querySelector('[data-t="mac.s1"], [data-t="mac.s1.setup"]');
    macStep.dataset.t = mac && !mac.name.endsWith(".dmg") ? "mac.s1.setup" : "mac.s1";
    macStep.textContent = t(macStep.dataset.t);
    setButton("win", win);

    const table = document.getElementById("fileTable");
    table.innerHTML = "";
    const recommended = [mac, win].filter(Boolean).map((a) => a.name);
    const names = assets.length
      ? assets.map((a) => a.name).sort((a, b) => recommended.includes(b) - recommended.includes(a))
      : FILES.map((f) => f.match.source.replace(/\\|\^|\$/g, "").replace(".+", "<version>"));
    for (const name of names) {
      const info = FILES.find((f) => f.match.test(name));
      const row = document.createElement("tr");
      const file = document.createElement("td");
      const code = document.createElement("code");
      code.textContent = name;
      file.appendChild(code);
      if (recommended.includes(name)) {
        const tag = document.createElement("span");
        tag.className = "tag rec";
        tag.textContent = language === "ja" ? "おすすめ" : "Recommended";
        file.appendChild(tag);
      }
      const use = document.createElement("td");
      use.textContent = info ? info[language] : (language === "ja" ? "その他" : "Other");
      row.append(file, use);
      table.appendChild(row);
    }
  }

  function setButton(os, asset) {
    const button = document.getElementById(`btn-${os}`);
    const label = document.getElementById(`file-${os}`);
    if (asset) {
      button.href = asset.browser_download_url;
      label.textContent = `${asset.name} · ${(asset.size / 1e6).toFixed(0)} MB`;
    } else {
      button.href = RELEASES;
      label.textContent = release ? "" : "GitHub Releases";
    }
  }

  const os = detectOS();
  if (os === "mac" || os === "win") {
    const card = document.getElementById(`card-${os}`);
    card.classList.add("detected");
    card.parentElement.prepend(card);
  } else {
    document.querySelector(".platforms").classList.add("none");
    if (os === "mobile") document.getElementById("mobileNotice").hidden = false;
  }

  document.getElementById("lang").addEventListener("click", () => {
    language = language === "ja" ? "en" : "ja";
    try { localStorage.setItem("castor.lang", language); } catch (_) { /* private mode */ }
    render();
  });

  // Telescope intro: lower left, then upper right to Castor and Pollux, then open.
  (() => {
    const root = document.documentElement;
    if (root.dataset.intro !== "on") return;
    const intro = document.getElementById("intro");
    const style = intro.style;
    const ease = (x) => (x < 0.5 ? 4 * x * x * x : 1 - Math.pow(-2 * x + 2, 3) / 2);
    const vmin = () => Math.min(innerWidth, innerHeight);
    const lens = () => Math.max(110, vmin() * 0.2);
    const cover = () => Math.hypot(innerWidth, innerHeight);
    // [time ms, x %, y %, radius px]
    const keys = () => [
      [0, 15, 80, 0], [500, 15, 80, lens()], [1500, 18, 76, lens()],
      [2900, 78, 26, lens()], [3900, 78, 26, lens() * 1.08], [4800, 78, 26, cover()],
    ];
    let done = false, start = null, frame = 0;
    function set(x, y, r) { style.setProperty("--x", x + "%"); style.setProperty("--y", y + "%"); style.setProperty("--r", r + "px"); }
    function finish() {
      if (done) return;
      done = true;
      cancelAnimationFrame(frame);
      try { localStorage.setItem("castor-intro", "1"); } catch (_) { /* private mode */ }
      intro.classList.add("leaving");
      root.dataset.introOpen = "";
      setTimeout(() => { delete root.dataset.intro; delete root.dataset.introOpen; intro.remove(); }, 560);
    }
    function step(now) {
      if (start === null) start = now;
      const t = now - start, k = keys();
      if (t >= 2700) intro.classList.add("found");
      if (t >= 4000) { intro.classList.add("open"); root.dataset.introOpen = ""; }
      if (t >= k[k.length - 1][0]) { set(78, 26, cover()); finish(); return; }
      let i = 0;
      while (t > k[i + 1][0]) i++;
      const [t0, x0, y0, r0] = k[i], [t1, x1, y1, r1] = k[i + 1];
      const p = ease((t - t0) / (t1 - t0));
      set(x0 + (x1 - x0) * p, y0 + (y1 - y0) * p, r0 + (r1 - r0) * p);
      frame = requestAnimationFrame(step);
    }
    document.getElementById("introSkip").addEventListener("click", finish);
    addEventListener("keydown", (event) => { if (event.key === "Escape") finish(); });
    frame = requestAnimationFrame(step);
  })();

  // The night sky flows: slowly on its own, and further as the page scrolls.
  (() => {
    if (matchMedia("(prefers-reduced-motion: reduce)").matches) return;
    const layers = [["far", 340, 0.05, 3], ["mid", 520, 0.12, 6], ["near", 760, 0.26, 10]].map(([name, tile, scroll, drift]) =>
      ({ el: document.querySelector(`.stars.${name}`), tile, scroll, drift }));
    function frame(now) {
      const y = scrollY, t = now / 1000;
      for (const layer of layers) {
        // Up and a little left, like the sky turning; wrapped by the tile size so it never runs out.
        const dx = layer.tile - ((y * layer.scroll * 0.4 + t * layer.drift) % layer.tile);
        const dy = layer.tile - ((y * layer.scroll + t * layer.drift * 0.35) % layer.tile);
        layer.el.style.transform = `translate3d(${dx.toFixed(1)}px, ${dy.toFixed(1)}px, 0)`;
      }
      requestAnimationFrame(frame);
    }
    requestAnimationFrame(frame);
  })();

  // Sections rise in once as they come into view.
  (() => {
    if (matchMedia("(prefers-reduced-motion: reduce)").matches || !("IntersectionObserver" in window)) return;
    const targets = document.querySelectorAll(".features article, .download > *, .constellation > *, .safety, .faq");
    const observer = new IntersectionObserver((entries) => {
      for (const entry of entries) if (entry.isIntersecting) { entry.target.classList.add("in"); observer.unobserve(entry.target); }
    }, { threshold: 0.12, rootMargin: "0px 0px -6% 0px" });
    targets.forEach((target, i) => {
      target.classList.add("reveal");
      target.style.transitionDelay = `${(i % 3) * 80}ms`;
      observer.observe(target);
    });
  })();

  // Skin switch: Auto follows the device; a choice is remembered.
  const skinInputs = document.querySelectorAll('.seg input[name="ui"]');
  let savedSkin = null;
  try { savedSkin = localStorage.getItem("castor-ui"); } catch (_) { /* private mode */ }
  const hashSkin = ["liquid", "material", "winui"].includes(location.hash.slice(1)) ? location.hash.slice(1) : null;
  skinInputs.forEach((input) => {
    input.checked = input.value === (hashSkin || savedSkin || "auto");
    input.addEventListener("change", () => {
      const skin = input.value === "auto" ? window.__castorDevice : input.value;
      document.documentElement.dataset.ui = skin;
      try { input.value === "auto" ? localStorage.removeItem("castor-ui") : localStorage.setItem("castor-ui", input.value); } catch (_) { /* private mode */ }
    });
  });

  // Stars: shown with the live count, offered once after a download, never required.
  let stars = null;
  function renderStars() {
    // A tiny count reads as "nobody uses this"; show it only once it helps.
    if (stars === null || stars < 10) return;
    document.querySelectorAll(".star-count").forEach((el) => { el.textContent = stars.toLocaleString(); el.hidden = false; });
    document.querySelectorAll(".star-now").forEach((el) => { el.textContent = t("star.now", stars.toLocaleString()); el.hidden = false; });
  }
  const renderPage = render;
  render = () => { renderPage(); renderStars(); };

  const thanks = document.getElementById("thanks");
  const remembered = (key) => { try { return localStorage.getItem(key) === "1"; } catch (_) { return false; } };
  const remember = (key) => { try { localStorage.setItem(key, "1"); } catch (_) { /* private mode */ } };
  const closeThanks = () => { thanks.hidden = true; remember("castor.thanks"); };
  ["btn-mac", "btn-win"].forEach((id) => document.getElementById(id).addEventListener("click", () => {
    if (remembered("castor.thanks") || remembered("castor.starred")) return;
    setTimeout(() => { thanks.hidden = false; }, 1200);
  }));
  document.getElementById("thanksLater").addEventListener("click", closeThanks);
  // Going to star Castor brightens the sky once, then it stays a little brighter.
  const sky = document.querySelector(".sky");
  document.querySelectorAll("[data-star-link]").forEach((link) => link.addEventListener("click", () => {
    remember("castor.starred");
    document.documentElement.dataset.starred = "";
    if (!matchMedia("(prefers-reduced-motion: reduce)").matches) {
      sky.classList.remove("flare");
      void sky.offsetWidth;
      sky.classList.add("flare");
      setTimeout(() => sky.classList.remove("flare"), 2700);
    }
    if (!thanks.hidden) closeThanks();
  }));
  document.addEventListener("keydown", (event) => { if (event.key === "Escape" && !thanks.hidden) closeThanks(); });

  // Touch screens have no hover: light "your star" once the section is in view.
  const starSection = document.getElementById("star");
  if ("IntersectionObserver" in window && !matchMedia("(hover: hover)").matches) {
    new IntersectionObserver((entries, observer) => {
      if (entries.some((e) => e.isIntersecting)) { setTimeout(() => starSection.classList.add("lit"), 700); observer.disconnect(); }
    }, { threshold: 0.6 }).observe(starSection);
  }

  render();
  fetch(`https://api.github.com/repos/${REPO}`, { headers: { Accept: "application/vnd.github+json" } })
    .then((response) => (response.ok ? response.json() : Promise.reject(response.status)))
    .then((data) => { if (typeof data.stargazers_count === "number") { stars = data.stargazers_count; renderStars(); } })
    .catch(() => { /* the links still work without the count */ });
  fetch(`https://api.github.com/repos/${REPO}/releases/latest`, { headers: { Accept: "application/vnd.github+json" } })
    .then((response) => (response.ok ? response.json() : Promise.reject(response.status)))
    .then((data) => { release = data; render(); })
    .catch(() => { releaseFailed = true; render(); });
})();
