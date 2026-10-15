// Castor for Windows — the creation window. Talks to the Swift host over
// WebView2 messages; outside WebView2 a mock host lets the page be previewed.
(() => {
  "use strict";

  // Strings: English source keys shared with the Mac catalog (CastorAppStrings).
  // The host returns its translations; these fill keys the catalog lacks.
  const FALLBACK_JA = {
    "Setting with AI": "AIで設定",
    "Rigging": "リギング",
    "Voice": "声",
    "Settings": "設定",
    "drop.hint": "ここに画像をドラッグしても読み込めます",
    "drop.release": "ここで離すと読み込みます",
    "estimator.model": "アニメ顔モデルで推定",
    "estimator.heuristic": "イラスト推定（モデル未導入）",
    "estimator.template": "テンプレート（要補正）",
    "saved": "ペットを保存して、デスクトップに表示しました。",
    "Head": "頭", "Left Eye": "左目", "Right Eye": "右目", "Mouth": "口",
    "Image Rigging": "画像からペットを作成",
    "Import an illustration to create a starter rig.": "イラストを読み込んで基本リグを作成してください。",
    "Import Image": "画像を読み込む",
    "Adjust Face": "顔を調整",
    "Save Pet": "ペットを保存",
    "Add Quality View": "Quality用の画像を追加",
    "Check the face markers before rigging.": "リギングの前に顔マーカーを確認してください。",
    "Cancel": "キャンセル",
  };
  const FALLBACK_EN = {
    "drop.hint": "You can also drop an image here",
    "drop.release": "Release to import",
    "estimator.model": "Anime face model",
    "estimator.heuristic": "Illustration heuristic (model not installed)",
    "estimator.template": "Template (needs review)",
    "saved": "The pet was saved and shown on the desktop.",
  };
  let language = (navigator.language || "ja").startsWith("ja") ? "ja" : "en";
  let catalog = {};
  const t = (key) => catalog[key] || (language === "ja" ? FALLBACK_JA[key] : FALLBACK_EN[key]) || key;

  const $ = (id) => document.getElementById(id);
  const PARTS = [
    { key: "head", label: "Head", color: "var(--head)" },
    { key: "eyeLeft", label: "Left Eye", color: "var(--eye-left)" },
    { key: "eyeRight", label: "Right Eye", color: "var(--eye-right)" },
    { key: "mouth", label: "Mouth", color: "var(--mouth)" },
  ];

  // ---- Host bridge -------------------------------------------------------
  const host = (window.chrome && window.chrome.webview) ? {
    send: (message) => window.chrome.webview.postMessage(message),
    listen: (handler) => window.chrome.webview.addEventListener("message", (event) => handler(event.data)),
  } : mockHost();

  // ---- State ---------------------------------------------------------------
  let prepared = null;        // { width, height, markers }
  let busy = false;

  function applyLanguage() {
    document.documentElement.lang = language;
    for (const element of document.querySelectorAll("[data-t]")) element.textContent = t(element.dataset.t);
    for (const element of document.querySelectorAll("[data-title]")) element.title = t(element.dataset.title);
    if (prepared) renderReview();
  }

  function showBusy(text) {
    busy = true;
    $("busyText").textContent = text || "";
    $("busy").classList.remove("hidden");
  }
  function hideBusy() {
    busy = false;
    $("busy").classList.add("hidden");
  }

  let toastTimer = null;
  function toast(text, isError) {
    const element = $("toast");
    element.textContent = text;
    element.classList.toggle("error", !!isError);
    element.classList.remove("hidden");
    clearTimeout(toastTimer);
    toastTimer = setTimeout(() => element.classList.add("hidden"), isError ? 7000 : 4000);
  }

  // ---- Review ---------------------------------------------------------------
  function renderReview() {
    $("emptyState").classList.add("hidden");
    $("reviewState").classList.remove("hidden");
    $("adjustButton").disabled = false;
    $("saveButton").disabled = false;
    $("saveButton").classList.add("primary");

    const chip = $("estimatorChip");
    chip.textContent = t("estimator." + prepared.estimator);
    chip.classList.toggle("model", prepared.estimator === "model");

    $("legend").innerHTML = "";
    for (const part of PARTS) {
      const item = document.createElement("li");
      item.innerHTML = `<i style="--c:${part.color}"></i>${t(part.label)}`;
      $("legend").appendChild(item);
    }
    $("warnings").innerHTML = "";
    for (const warning of prepared.warnings || []) {
      const item = document.createElement("li");
      item.textContent = warning;
      $("warnings").appendChild(item);
    }
    layoutMarkers();
  }

  function layoutMarkers() {
    const image = $("preview");
    if (!prepared || !image.complete || !image.clientWidth) return;
    const figure = $("figure").getBoundingClientRect();
    const box = image.getBoundingClientRect();
    const layer = $("markers");
    layer.style.left = (box.left - figure.left) + "px";
    layer.style.top = (box.top - figure.top) + "px";
    layer.style.width = box.width + "px";
    layer.style.height = box.height + "px";
    const scale = box.width / prepared.width;
    layer.innerHTML = "";
    for (const part of PARTS) {
      const [x, y, w, h] = prepared.markers[part.key];
      const marker = document.createElement("div");
      marker.className = "marker " + part.key;
      marker.style.setProperty("--c", part.color);
      Object.assign(marker.style, { left: x * scale + "px", top: y * scale + "px", width: w * scale + "px", height: h * scale + "px" });
      marker.innerHTML = `<span class="tag">${t(part.label)}</span><span class="handle"></span>`;
      enableDrag(marker, part.key, scale);
      layer.appendChild(marker);
    }
  }

  function enableDrag(marker, key, scale) {
    marker.addEventListener("pointerdown", (event) => {
      if (busy) return;
      event.preventDefault();
      const resizing = event.target.classList.contains("handle");
      const start = [...prepared.markers[key]];
      const origin = [event.clientX, event.clientY];
      marker.setPointerCapture(event.pointerId);
      const move = (moveEvent) => {
        const dx = (moveEvent.clientX - origin[0]) / scale, dy = (moveEvent.clientY - origin[1]) / scale;
        let [x, y, w, h] = start;
        if (resizing) { w = Math.max(4, w + dx); h = Math.max(2, h + dy); }
        else { x += dx; y += dy; }
        x = Math.min(Math.max(0, x), prepared.width - w);
        y = Math.min(Math.max(0, y), prepared.height - h);
        w = Math.min(w, prepared.width - x); h = Math.min(h, prepared.height - y);
        prepared.markers[key] = [x, y, w, h];
        Object.assign(marker.style, { left: x * scale + "px", top: y * scale + "px", width: w * scale + "px", height: h * scale + "px" });
      };
      const up = () => { marker.removeEventListener("pointermove", move); marker.removeEventListener("pointerup", up); };
      marker.addEventListener("pointermove", move);
      marker.addEventListener("pointerup", up);
    });
  }

  // ---- Host messages --------------------------------------------------------
  host.listen((message) => {
    switch (message.type) {
      case "init":
        language = message.language === "en" ? "en" : "ja";
        catalog = message.strings || {};
        applyLanguage();
        break;
      case "busy": showBusy(message.text); break;
      case "idle": hideBusy(); break;
      case "prepared":
        hideBusy();
        prepared = { width: message.width, height: message.height, markers: message.markers,
                     estimator: message.estimator, warnings: message.warnings };
        $("preview").onload = () => renderReview();
        $("preview").src = message.image;
        break;
      case "saved": hideBusy(); toast(message.message || t("saved")); break;
      case "error": hideBusy(); toast(message.message, true); break;
      case "toast": toast(message.message); break;
      case "markers":
        // An AI proposal: shown for review, never saved without the user.
        if (!prepared) break;
        prepared.markers = message.markers;
        layoutMarkers();
        if (message.note) toast(message.note);
        break;
    }
  });

  // ---- UI events ------------------------------------------------------------
  const openImage = () => { if (!busy) host.send({ type: "openImage" }); };
  $("importButton").addEventListener("click", openImage);
  $("emptyState").addEventListener("click", openImage);
  $("adjustButton").addEventListener("click", () => layoutMarkers());
  $("saveButton").addEventListener("click", () => {
    if (!prepared || busy) return;
    host.send({ type: "save", markers: prepared.markers });
  });
  $("cancelButton").addEventListener("click", () => host.send({ type: "cancel" }));
  $("voiceButton").addEventListener("click", () => host.send({ type: "voice" }));
  $("settingsButton").addEventListener("click", () => host.send({ type: "settings" }));
  for (const button of $("modeSwitch").querySelectorAll("button")) {
    button.addEventListener("click", () => {
      if (button.dataset.mode === "ai") { host.send({ type: "aiSetup" }); return; }
      $("modeSwitch").querySelectorAll("button").forEach((b) => b.classList.toggle("on", b === button));
    });
  }
  window.addEventListener("resize", layoutMarkers);

  // Drag and drop an image file from Explorer.
  let dragDepth = 0;
  document.addEventListener("dragenter", (event) => { event.preventDefault(); dragDepth++; $("dropOverlay").classList.remove("hidden"); });
  document.addEventListener("dragleave", () => { if (--dragDepth <= 0) { dragDepth = 0; $("dropOverlay").classList.add("hidden"); } });
  document.addEventListener("dragover", (event) => event.preventDefault());
  document.addEventListener("drop", (event) => {
    event.preventDefault();
    dragDepth = 0;
    $("dropOverlay").classList.add("hidden");
    const file = event.dataTransfer && event.dataTransfer.files[0];
    if (!file || busy) return;
    const reader = new FileReader();
    reader.onload = () => host.send({ type: "openImageData", name: file.name, data: String(reader.result) });
    reader.readAsDataURL(file);
  });

  applyLanguage();
  host.send({ type: "ready", sources: [...new Set([...document.querySelectorAll("[data-t]")].map((e) => e.dataset.t)
    .concat(PARTS.map((p) => p.label)))] });

  // ---- Mock host for previewing outside Castor ----------------------------
  function mockHost() {
    let handler = () => {};
    const reply = (message, delay) => setTimeout(() => handler(message), delay || 0);
    const sample = () => {
      const canvas = document.createElement("canvas");
      canvas.width = 600; canvas.height = 900;
      const g = canvas.getContext("2d");
      g.fillStyle = "#e9e4ef"; g.beginPath(); g.ellipse(300, 210, 150, 165, 0, 0, Math.PI * 2); g.fill();
      g.fillStyle = "#f7e2d8"; g.beginPath(); g.ellipse(300, 235, 105, 120, 0, 0, Math.PI * 2); g.fill();
      g.fillStyle = "#3b3550"; g.fillRect(150, 380, 300, 470);
      g.fillStyle = "#4a6fd0"; g.beginPath(); g.arc(258, 238, 16, 0, 7); g.arc(342, 238, 16, 0, 7); g.fill();
      return canvas.toDataURL("image/png");
    };
    return {
      listen: (h) => { handler = h; },
      send: (message) => {
        if (message.type === "ready") reply({ type: "init", language, strings: {} });
        if (message.type === "openImage" || message.type === "openImageData") {
          reply({ type: "busy", text: language === "ja" ? "キャラクターを切り抜いて、顔の位置を推定しています…" : "Cutting out the character and finding the face…" });
          reply({ type: "prepared", image: sample(), width: 600, height: 900, estimator: "model",
                  warnings: [language === "ja" ? "顔の推定結果は自動承認しません。頭・目・口の範囲を確認してください。" : "Face estimates are never approved automatically. Check the head, eyes and mouth."],
                  markers: { head: [150, 60, 300, 330], eyeLeft: [222, 205, 70, 60], eyeRight: [306, 205, 70, 60], mouth: [270, 300, 60, 22] } }, 1200);
        }
        if (message.type === "save") { reply({ type: "busy", text: "…" }); reply({ type: "saved" }, 700); }
        if (message.type === "cancel") reply({ type: "idle" });
      },
    };
  }
})();
