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
    "My Pets": "ペット一覧",
    "library.new": "＋ 新しく作る",
    "library.empty": "まだペットがありません。画像を読み込んで作ってみましょう。",
    "library.hint": "選ぶとデスクトップのペットが入れ替わります。削除したペットはごみ箱に移ります。",
    "library.shown": "表示中",
    "library.deleteTitle": "このペットを削除しますか？",
    "library.deleteText": "ペットのファイルをごみ箱に移します。ごみ箱から元に戻せます。",
    "library.delete": "削除する",
  };
  const FALLBACK_EN = {
    "drop.hint": "You can also drop an image here",
    "drop.release": "Release to import",
    "estimator.model": "Anime face model",
    "estimator.heuristic": "Illustration heuristic (model not installed)",
    "estimator.template": "Template (needs review)",
    "saved": "The pet was saved and shown on the desktop.",
    "My Pets": "My Pets",
    "library.new": "+ Create new",
    "library.empty": "No pets yet. Import an image to make one.",
    "library.hint": "Choosing a pet swaps the one on your desktop. Deleted pets go to the Recycle Bin.",
    "library.shown": "On desktop",
    "library.deleteTitle": "Delete this pet?",
    "library.deleteText": "The pet's file moves to the Recycle Bin, where you can restore it.",
    "library.delete": "Delete",
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
  let view = "create";        // "create" | "library"
  let pets = [];              // [{ id, created, selected }]
  const thumbnails = {};      // id -> data URL
  let pendingDelete = null;

  function showView(name) {
    view = name;
    $("libraryState").classList.toggle("hidden", name !== "library");
    $("emptyState").classList.toggle("hidden", name !== "create" || !!prepared);
    $("reviewState").classList.toggle("hidden", name !== "create" || !prepared);
    $("libraryButton").classList.toggle("on", name === "library");
  }

  function openLibrary() {
    showView("library");
    host.send({ type: "library" });
  }

  function renderLibrary() {
    const grid = $("petGrid");
    grid.innerHTML = "";
    $("libraryEmpty").classList.toggle("hidden", pets.length > 0);
    const format = new Intl.DateTimeFormat(language === "ja" ? "ja-JP" : "en-US", { month: "short", day: "numeric", hour: "2-digit", minute: "2-digit" });
    for (const pet of pets) {
      const card = document.createElement("div");
      card.className = "pet-card" + (pet.selected ? " selected" : "");
      card.tabIndex = 0;
      card.setAttribute("role", "button");
      const thumb = document.createElement("div");
      thumb.className = "pet-thumb";
      if (thumbnails[pet.id]) {
        const image = document.createElement("img");
        image.src = thumbnails[pet.id];
        image.alt = "";
        thumb.appendChild(image);
      } else {
        thumb.innerHTML = '<span class="loading"></span>';
      }
      const meta = document.createElement("div");
      meta.className = "pet-meta";
      const date = document.createElement("span");
      date.textContent = pet.created ? format.format(new Date(pet.created)) : "";
      meta.appendChild(date);
      if (pet.selected) {
        const badge = document.createElement("span");
        badge.className = "pet-badge";
        badge.textContent = t("library.shown");
        meta.appendChild(badge);
      }
      const remove = document.createElement("button");
      remove.className = "pet-delete";
      remove.title = t("library.delete");
      remove.innerHTML = '<svg viewBox="0 0 24 24"><path d="M5 7h14M10 7V5h4v2M7 7l1 12h8l1-12"/></svg>';
      remove.addEventListener("click", (event) => {
        event.stopPropagation();
        pendingDelete = pet.id;
        $("confirmDelete").classList.remove("hidden");
      });
      const choose = () => { if (!busy && !pet.selected) host.send({ type: "selectPet", id: pet.id }); };
      card.addEventListener("click", choose);
      card.addEventListener("keydown", (event) => { if (event.key === "Enter" || event.key === " ") { event.preventDefault(); choose(); } });
      card.append(thumb, meta, remove);
      grid.appendChild(card);
    }
  }

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
    if (view !== "create") showView("create");
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
        if (message.view === "library") openLibrary();
        break;
      case "showLibrary": openLibrary(); break;
      case "library":
        pets = message.items || [];
        renderLibrary();
        break;
      case "thumbnail":
        thumbnails[message.id] = message.data;
        if (view === "library") renderLibrary();
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
  const openImage = () => { if (!busy) { showView("create"); host.send({ type: "openImage" }); } };
  $("libraryButton").addEventListener("click", () => (view === "library" ? showView("create") : openLibrary()));
  $("newPetButton").addEventListener("click", () => showView("create"));
  $("deleteNo").addEventListener("click", () => { pendingDelete = null; $("confirmDelete").classList.add("hidden"); });
  $("deleteYes").addEventListener("click", () => {
    $("confirmDelete").classList.add("hidden");
    if (pendingDelete) host.send({ type: "deletePet", id: pendingDelete });
    pendingDelete = null;
  });
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
    .concat(PARTS.map((p) => p.label)).concat(["library.shown"]))] });

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
    let mockPets = ["CastorPet-A.json", "CastorPet-B.json", "CastorPet-C.json"], mockSelected = "CastorPet-A.json";
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
        if (message.type === "library" || message.type === "selectPet" || message.type === "deletePet") {
          const now = Date.now();
          if (message.type === "deletePet") mockPets = mockPets.filter((p) => p !== message.id);
          if (message.type === "selectPet") mockSelected = message.id;
          reply({ type: "library", items: mockPets.map((id, i) => ({ id, created: new Date(now - i * 86400000).toISOString(), selected: id === mockSelected })) });
          mockPets.forEach((id, i) => reply({ type: "thumbnail", id, data: sample() }, 300 + i * 200));
          if (message.type === "selectPet") reply({ type: "toast", message: language === "ja" ? "デスクトップのペットを入れ替えました。" : "Swapped the pet on your desktop." });
        }
      },
    };
  }
})();
