// Castor Setup for Windows — the wizard page. Talks to the Swift host over
// WebView2 messages; outside WebView2 a mock host lets the page be previewed.
(() => {
  "use strict";

  const TEXT = {
    ja: {
      tagline: "画像1枚から、動くデスクトップキャラクターを。",
      "step.welcome": "ようこそ", "step.license": "ライセンス", "step.details": "導入の前に", "step.install": "インストール", "step.done": "完了",
      "welcome.title": "Castor へようこそ",
      "welcome.lead": "イラストを1枚読み込むだけで、呼吸やまばたき、視線や口の動きをつけたキャラクターがデスクトップに住みつきます。このセットアップで Windows 用の Castor を取得して導入します。",
      "status.none": "この PC にはまだ Castor が導入されていません。",
      "status.installed": "Castor {v} が導入済みです。",
      "license.title": "ライセンス",
      "license.lead": "Castor のライセンスと、同梱しているモデル・ライブラリのライセンスをご確認ください。",
      "license.app": "Castor", "license.notices": "第三者のライセンス",
      "license.agree": "ライセンスに同意します",
      "details.title": "導入の前に",
      "details.where": "保存先", "details.where.text": "管理者権限は不要です。この PC のあなたのアカウントにだけ導入します。",
      "details.download": "取得と確認", "details.download.text": "GitHub Releases から Windows 版（ML モデルを含めて数百 MB）を取得し、SHA-256 を照合します。照合は配布者の真正性を保証するものではありません。",
      "details.ml": "端末内で処理", "details.ml.text": "顔の推定とキャラクターの切り抜きは、同梱の ML モデルでこの PC の中だけで行います。画像を外部へ送りません。",
      "details.data": "キャラクターと設定は保持", "details.data.text": "作ったキャラクターや設定は更新・修復・削除をしても残ります。",
      "details.smartscreen": "初回の確認", "details.smartscreen.text": "コード署名は未整備のため、初回起動時に SmartScreen の確認が出ることがあります。",
      "details.voice": "音声（任意）", "details.voice.text": "Neural TTS は導入後、このセットアップの管理画面からいつでも追加できます。",
      "install.progress": "Castor を取得・検証・導入しています…",
      "welcome.history": "これまでの更新内容を見る",
      "manage.history": "更新履歴", "manage.history.text": "これまでの版と、それぞれの更新内容を見ます",
      "history.title": "更新履歴", "history.loading": "GitHub から読み込んでいます…",
      "history.error": "更新履歴を読み込めませんでした。インターネット接続を確認してください。",
      "history.lead": "新しい順に並んでいます。", "history.latest": "最新", "history.installed": "使用中",
      "install.note": "OS の安全確認は解除しません。キャラクター・設定・モデルキャッシュは保持します。",
      "done.title": "Castor {v} を導入しました",
      "done.lead": "スタートメニューに「Castor」を追加しました。",
      "done.helper": "Neural TTS helper {v} を導入しました",
      "done.helper.lead": "モデルは helper の画面から任意に取得します。",
      "manage.title": "Castor の管理",
      "manage.update": "更新", "manage.update.text": "最新版を取得して入れ替えます",
      "manage.launch": "起動", "manage.launch.text": "導入済みの Castor を開きます",
      "manage.repair": "修復", "manage.repair.text": "現在の版を入れ直します（旧版は保持）",
      "manage.cleanup": "古い版を整理", "manage.cleanup.text": "確認できた古い版だけをごみ箱へ送ります",
      "manage.remove": "Castor を削除", "manage.remove.text": "アプリだけを削除します（キャラクター・設定は保持）",
      "manage.helper": "Neural TTS helper（任意）",
      "helper.install": "取得・更新", "helper.install.text": "高品質な読み上げの補助アプリ",
      "helper.launch": "起動", "helper.launch.text": "helper の画面を開きます",
      "helper.repair": "修復", "helper.repair.text": "helper を入れ直します",
      "helper.remove": "削除", "helper.remove.text": "helper を削除します（モデルキャッシュは保持）",
      "confirm.remove": "Castor を削除しますか？", "confirm.remove.helper": "Neural TTS helper を削除しますか？",
      "confirm.remove.text": "アプリ本体だけを削除します。作ったキャラクター・設定・モデルキャッシュは残ります。",
      "error.title": "完了できませんでした",
      back: "戻る", next: "次へ", install: "インストール", cancel: "キャンセル", close: "閉じる",
      launch: "Castor を起動", launchHelper: "helper を起動", remove: "削除する", manage: "管理画面へ",
    },
    en: {
      tagline: "A desktop character that moves, from a single image.",
      "step.welcome": "Welcome", "step.license": "License", "step.details": "Before installing", "step.install": "Install", "step.done": "Finish",
      "welcome.title": "Welcome to Castor",
      "welcome.lead": "Import one illustration and a character that breathes, blinks, looks around and talks moves onto your desktop. This setup downloads and installs Castor for Windows.",
      "status.none": "Castor is not installed on this PC yet.",
      "status.installed": "Castor {v} is installed.",
      "license.title": "License",
      "license.lead": "Review Castor's license and the licenses of the bundled models and libraries.",
      "license.app": "Castor", "license.notices": "Third-party licenses",
      "license.agree": "I accept the license",
      "details.title": "Before installing",
      "details.where": "Location", "details.where.text": "No administrator rights needed. Castor is installed for your account on this PC only.",
      "details.download": "Download and check", "details.download.text": "The Windows build (a few hundred MB with the ML models) comes from GitHub Releases and is checked by SHA-256. The check does not prove who published it.",
      "details.ml": "Processed on this PC", "details.ml.text": "Face estimation and cut-out run with the bundled ML models on this PC only. Images are not sent anywhere.",
      "details.data": "Characters and settings are kept", "details.data.text": "Your characters and settings stay through updates, repairs and removal.",
      "details.smartscreen": "First launch", "details.smartscreen.text": "Castor is not code-signed yet, so SmartScreen may ask for confirmation on first launch.",
      "details.voice": "Voice (optional)", "details.voice.text": "Neural TTS can be added at any time from this setup's management page.",
      "install.progress": "Downloading, verifying and installing Castor…",
      "welcome.history": "See what's new",
      "manage.history": "Release history", "manage.history.text": "See past versions and what changed in each",
      "history.title": "Release history", "history.loading": "Loading from GitHub…",
      "history.error": "Could not load the release history. Check your internet connection.",
      "history.lead": "Newest first.", "history.latest": "Latest", "history.installed": "In use",
      "install.note": "OS security checks stay on. Characters, settings and model cache are kept.",
      "done.title": "Castor {v} is installed",
      "done.lead": "“Castor” was added to the Start menu.",
      "done.helper": "Neural TTS helper {v} is installed",
      "done.helper.lead": "Models can be downloaded from the helper's window when you want them.",
      "manage.title": "Manage Castor",
      "manage.update": "Update", "manage.update.text": "Download and switch to the latest version",
      "manage.launch": "Launch", "manage.launch.text": "Open the installed Castor",
      "manage.repair": "Repair", "manage.repair.text": "Reinstall this version (the previous one is kept)",
      "manage.cleanup": "Clean up older versions", "manage.cleanup.text": "Send only verified older versions to the Recycle Bin",
      "manage.remove": "Remove Castor", "manage.remove.text": "Remove the app only (characters and settings are kept)",
      "manage.helper": "Neural TTS helper (optional)",
      "helper.install": "Download / Update", "helper.install.text": "Helper app for high-quality speech",
      "helper.launch": "Launch", "helper.launch.text": "Open the helper's window",
      "helper.repair": "Repair", "helper.repair.text": "Reinstall the helper",
      "helper.remove": "Remove", "helper.remove.text": "Remove the helper (model cache is kept)",
      "confirm.remove": "Remove Castor?", "confirm.remove.helper": "Remove the Neural TTS helper?",
      "confirm.remove.text": "Only the app is removed. Your characters, settings and model cache stay.",
      "error.title": "Could not finish",
      back: "Back", next: "Next", install: "Install", cancel: "Cancel", close: "Close",
      launch: "Launch Castor", launchHelper: "Launch helper", remove: "Remove", manage: "Manage",
    },
  };
  let language = (navigator.language || "ja").startsWith("ja") ? "ja" : "en";
  const t = (key, value) => (TEXT[language][key] || key).replace("{v}", value || "");
  const $ = (id) => document.getElementById(id);

  const host = (window.chrome && window.chrome.webview) ? {
    send: (message) => window.chrome.webview.postMessage(message),
    listen: (handler) => window.chrome.webview.addEventListener("message", (event) => handler(event.data)),
  } : mockHost();

  let state = { installed: null, helper: null, license: "", notices: "", root: "" };
  let page = "welcome";
  let historyReturn = "welcome";
  let busy = false;
  let lastAction = null;

  const STEPS = ["welcome", "license", "details", "install", "done"];
  function show(name) {
    page = name;
    for (const element of document.querySelectorAll(".page")) element.classList.toggle("hidden", element.dataset.page !== name);
    const step = name === "progress" ? "install" : name === "manage" || name === "error" ? null : name;
    document.querySelectorAll("#steps li").forEach((li) => li.classList.toggle("on", li.dataset.step === step));
    renderFooter();
  }

  function button(label, kind, action, disabled) {
    const element = document.createElement("button");
    element.className = "button" + (kind ? " " + kind : "");
    element.textContent = label;
    element.disabled = !!disabled;
    element.addEventListener("click", action);
    return element;
  }

  function renderFooter() {
    const footer = $("footer");
    footer.innerHTML = "";
    const spacer = document.createElement("div");
    spacer.className = "spacer";
    const close = () => host.send({ type: "close" });
    switch (page) {
      case "welcome":
        if (state.installed) {
          footer.append(spacer, button(t("close"), "", close), button(t("manage"), "primary", () => show("manage")));
        } else {
          footer.append(spacer, button(t("cancel"), "", close), button(t("next"), "primary", () => show("license")));
        }
        break;
      case "license":
        footer.append(spacer, button(t("back"), "", () => show("welcome")),
          button(t("next"), "primary", () => show("details"), !$("agree").checked));
        break;
      case "details":
        footer.append(spacer, button(t("back"), "", () => show("license")),
          button(t("install"), "primary", () => run({ type: "install", component: null, repair: false })));
        break;
      case "progress":
        footer.append(spacer, button(t("cancel"), "", () => host.send({ type: "cancel" })));
        break;
      case "done":
        footer.append(spacer, button(t("close"), "", close),
          button(lastAction && lastAction.component ? t("launchHelper") : t("launch"), "primary",
            () => { host.send({ type: "launch", component: lastAction ? lastAction.component : null }); }));
        break;
      case "manage":
        footer.append(spacer, button(t("close"), "primary", close));
        break;
      case "history":
        footer.append(spacer, button(t("back"), "primary", () => show(historyReturn)));
        break;
      case "error":
        footer.append(spacer, button(t("close"), "", close),
          button(t("back"), "primary", () => show(state.installed ? "manage" : "details")));
        break;
    }
  }

  function applyLanguage() {
    document.documentElement.lang = language;
    for (const element of document.querySelectorAll("[data-t]")) element.textContent = t(element.dataset.t);
    renderStatus();
    renderFooter();
  }

  function renderStatus() {
    const status = $("status");
    status.textContent = state.installed ? t("status.installed", state.installed) : t("status.none");
    status.classList.toggle("installed", !!state.installed);
    $("manageStatus").textContent = state.installed ? t("status.installed", state.installed) : t("status.none");
    $("installPath").textContent = state.root;
    $("version").textContent = state.installed ? "Castor " + state.installed : "";
    $("licenseText").textContent = $("licenseTabs").dataset.tab === "notices" ? state.notices : state.license;
    for (const element of document.querySelectorAll("[data-needs-app]")) element.classList.toggle("hidden", !state.installed);
    for (const element of document.querySelectorAll("[data-needs-helper]")) element.classList.toggle("hidden", !state.helper);
  }

  function run(action) {
    if (busy) return;
    lastAction = action;
    if (action.type === "install") {
      busy = true;
      $("progressText").textContent = action.component ? "Neural TTS helper…" : t("install.progress");
      $("progressBar").classList.add("hidden");
      $("progressDetail").textContent = "";
      show("progress");
    }
    if (action.type === "history") {
      busy = false;
      historyReturn = page;
      $("historyStatus").textContent = t("history.loading");
      $("historyList").innerHTML = "";
      show("history");
    }
    host.send(action);
  }

  // Release notes are Markdown; only headings, bullets, bold and code are
  // drawn, everything else stays text (nothing from GitHub becomes HTML).
  function renderNotes(markdown) {
    const box = document.createElement("div");
    box.className = "notes";
    let list = null;
    const inline = (parent, text) => {
      const parts = text.replace(/\[([^\]]+)\]\([^)]*\)/g, "$1").split(/(\*\*[^*]+\*\*|`[^`]+`)/);
      for (const part of parts) {
        if (!part) continue;
        if (part.startsWith("**") && part.endsWith("**")) { const b = document.createElement("b"); b.textContent = part.slice(2, -2); parent.appendChild(b); }
        else if (part.startsWith("`") && part.endsWith("`")) { const c = document.createElement("code"); c.textContent = part.slice(1, -1); parent.appendChild(c); }
        else parent.appendChild(document.createTextNode(part));
      }
    };
    for (const raw of (markdown || "").split(/\r?\n/)) {
      const line = raw.trim();
      if (!line) { list = null; continue; }
      const heading = line.match(/^#{1,6}\s+(.*)$/);
      const bullet = line.match(/^[-*]\s+(.*)$/);
      if (heading) {
        list = null;
        const h = document.createElement("h4"); inline(h, heading[1]); box.appendChild(h);
      } else if (bullet) {
        if (!list) { list = document.createElement("ul"); box.appendChild(list); }
        const li = document.createElement("li"); inline(li, bullet[1]); list.appendChild(li);
      } else if (list && raw.startsWith("  ")) {
        const last = list.lastElementChild;
        if (last) { last.appendChild(document.createTextNode(" ")); inline(last, line); }
      } else {
        list = null;
        const p = document.createElement("p"); inline(p, line); box.appendChild(p);
      }
    }
    return box;
  }

  function renderHistory(message) {
    const list = $("historyList");
    list.innerHTML = "";
    if (message.error) { $("historyStatus").textContent = t("history.error"); return; }
    $("historyStatus").textContent = t("history.lead");
    (message.releases || []).forEach((release, index) => {
      const item = document.createElement("article");
      item.className = "release";
      const header = document.createElement("header");
      const title = document.createElement("b"); title.textContent = release.title;
      const day = document.createElement("span"); day.className = "day"; day.textContent = release.day || "";
      header.append(title, day);
      const badges = [];
      if (index === 0) badges.push(t("history.latest"));
      if (state.installed && release.tag === state.installed) badges.push(t("history.installed"));
      for (const text of badges) { const badge = document.createElement("span"); badge.className = "badge"; badge.textContent = text; header.appendChild(badge); }
      item.append(header, renderNotes(release.body));
      list.appendChild(item);
    });
  }

  function confirmRemove(component) {
    $("confirmTitle").textContent = component ? t("confirm.remove.helper") : t("confirm.remove");
    $("confirm").classList.remove("hidden");
    $("confirmYes").onclick = () => { $("confirm").classList.add("hidden"); run({ type: "remove", component }); };
  }

  let toastTimer = null;
  function toast(text) {
    const element = $("toast");
    element.textContent = text;
    element.classList.remove("hidden");
    clearTimeout(toastTimer);
    toastTimer = setTimeout(() => element.classList.add("hidden"), 6000);
  }

  host.listen((message) => {
    switch (message.type) {
      case "init":
        language = message.language === "en" ? "en" : "ja";
        state = { installed: message.installed, helper: message.helper, license: message.license || "",
                  notices: message.notices || "", root: message.root || "" };
        applyLanguage();
        show(state.installed ? "manage" : "welcome");
        break;
      case "status":
        state.installed = message.installed; state.helper = message.helper;
        renderStatus();
        break;
      case "progress": {
        $("progressText").textContent = message.text;
        const known = typeof message.fraction === "number";
        $("progressBar").classList.toggle("hidden", !known);
        if (known) $("progressFill").style.width = Math.round(Math.min(Math.max(message.fraction, 0), 1) * 100) + "%";
        $("progressDetail").textContent = message.detail || "";
        break;
      }
      case "history":
        renderHistory(message);
        break;
      case "installed":
        busy = false;
        $("doneTitle").textContent = message.component ? t("done.helper", message.version) : t("done.title", message.version);
        $("doneLead").textContent = message.component ? t("done.helper.lead") : t("done.lead");
        $("doneNote").textContent = message.note || "";
        show("done");
        break;
      case "cancelled":
        busy = false;
        show(state.installed ? "manage" : "details");
        break;
      case "message":
        busy = false;
        toast(message.text);
        break;
      case "error":
        busy = false;
        $("errorText").textContent = message.message;
        show("error");
        break;
    }
  });

  // ---- Events ---------------------------------------------------------------
  $("agree").addEventListener("change", renderFooter);
  $("licenseTabs").querySelectorAll("button").forEach((tab) => tab.addEventListener("click", () => {
    $("licenseTabs").dataset.tab = tab.dataset.tab;
    $("licenseTabs").querySelectorAll("button").forEach((b) => b.classList.toggle("on", b === tab));
    $("licenseText").textContent = tab.dataset.tab === "notices" ? state.notices : state.license;
    $("licenseText").scrollTop = 0;
  }));
  for (const card of document.querySelectorAll("[data-action]")) {
    card.addEventListener("click", () => {
      const component = card.dataset.component || null;
      const action = card.dataset.action;
      if (action === "remove") { confirmRemove(component); return; }
      if (action === "install" || action === "repair") { run({ type: "install", component, repair: action === "repair" }); return; }
      run({ type: action, component });
    });
  }
  $("confirmNo").addEventListener("click", () => $("confirm").classList.add("hidden"));
  $("welcomeHistory").addEventListener("click", () => run({ type: "history" }));

  // A few fixed stars on the side panel.
  const stars = $("stars");
  [[18, 12], [70, 22], [40, 48], [82, 58], [12, 74], [58, 86], [30, 30], [88, 36]].forEach(([x, y], i) => {
    const star = document.createElement("i");
    Object.assign(star.style, { left: x + "%", top: y + "%", opacity: 0.25 + (i % 4) * 0.15 });
    stars.appendChild(star);
  });

  applyLanguage();
  show("welcome");
  host.send({ type: "ready" });

  // ---- Mock host for previewing outside Castor Setup ------------------------
  function mockHost() {
    let handler = () => {};
    const reply = (message, delay) => setTimeout(() => handler(message), delay || 0);
    const installed = new URLSearchParams(location.search).get("installed");
    return {
      listen: (h) => { handler = h; },
      send: (message) => {
        if (message.type === "ready") reply({ type: "init", language, installed, helper: null, root: "C:\\Users\\you\\AppData\\Local\\Programs\\Castor",
          license: "MIT License\n\nCopyright (c) …\n\nPermission is hereby granted, free of charge, to any person obtaining a copy…",
          notices: "# Third-Party Notices\n\n## ONNX Runtime\nMIT License…\n\n## Microsoft Edge WebView2 SDK\nBSD 3-Clause License…" });
        if (message.type === "history") reply({ type: "history", releases: [
          { tag: "v1.0.0-d", title: "Castor v1.0.0 (d)", day: "2026-10-17", body: "## 変更\n- 首と肩が頭と一緒に動きます\n- **口**が元の絵のままに\n\n## 確認範囲\nCI のテストが成功しています。" },
          { tag: "v1.0.0-d-beta", title: "Castor v1.0.0 (d-beta)", day: "2026-10-16", body: "- 頭の後ろの空白を修正\n- `Castor Settings` を追加" },
        ] }, 500);
        if (message.type === "install") {
          reply({ type: "progress", text: language === "ja" ? "ダウンロードしています… 42%" : "Downloading… 42%", fraction: 0.42, detail: "164 / 390 MB" }, 700);
          reply({ type: "installed", version: "v1.0.0", component: message.component }, 1800);
          reply({ type: "status", installed: "v1.0.0", helper: null }, 1800);
        }
        if (message.type === "cancel") reply({ type: "cancelled" });
        if (message.type === "remove") reply({ type: "status", installed: null, helper: null });
        if (message.type === "cleanup") reply({ type: "message", text: language === "ja" ? "古い版の整理が完了しました。" : "Cleanup finished." });
      },
    };
  }
})();
