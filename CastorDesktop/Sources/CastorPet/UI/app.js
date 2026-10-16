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
    "tab.create": "作成",
    "ai.suggest": "AIで目印を提案",
    "library.new": "＋ 新しく作る",
    "library.empty": "まだペットがありません。画像を読み込んで作ってみましょう。",
    "library.hint": "選ぶとデスクトップのペットが入れ替わります。削除したペットはごみ箱に移ります。",
    "library.shown": "表示中",
    "library.deleteTitle": "このペットを削除しますか？",
    "library.deleteText": "ペットのファイルをごみ箱に移します。ごみ箱から元に戻せます。",
    "library.delete": "削除する",
    "library.unnamed": "名前なし",
    "library.rename": "名前を変更",
    "library.renameTitle": "ペットの名前",
    "library.renameSave": "保存",
    "quality.hint": "ペットを保存したあと、デスクトップのペットを右クリックして「2枚からQualityを作る」を選ぶと、2枚の画像から作成できます。",
  };
  const FALLBACK_EN = {
    "drop.hint": "You can also drop an image here",
    "drop.release": "Release to import",
    "estimator.model": "Anime face model",
    "estimator.heuristic": "Illustration heuristic (model not installed)",
    "estimator.template": "Template (needs review)",
    "saved": "The pet was saved and shown on the desktop.",
    "My Pets": "My Pets",
    "tab.create": "Create",
    "ai.suggest": "Suggest markers with AI",
    "library.new": "+ Create new",
    "library.empty": "No pets yet. Import an image to make one.",
    "library.hint": "Choosing a pet swaps the one on your desktop. Deleted pets go to the Recycle Bin.",
    "library.shown": "On desktop",
    "library.deleteTitle": "Delete this pet?",
    "library.deleteText": "The pet's file moves to the Recycle Bin, where you can restore it.",
    "library.delete": "Delete",
    "library.unnamed": "Unnamed",
    "library.rename": "Rename",
    "library.renameTitle": "Pet name",
    "library.renameSave": "Save",
    "quality.hint": "After saving a pet, right-click it on the desktop and choose “Create Quality from two images” to use two images.",
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
  let pendingRename = null;

  function openRename(pet) {
    pendingRename = pet.id;
    $("renameInput").value = pet.name || "";
    $("renameDialog").showModal();
    $("renameInput").focus();
    $("renameInput").select();
  }
  function closeRename(save) {
    if (save && pendingRename) host.send({ type: "renamePet", id: pendingRename, name: $("renameInput").value });
    const id = pendingRename;
    pendingRename = null;
    $("renameDialog").close();
    const card = [...$("petGrid").children].find((item) => item.dataset.petId === id);
    const rename = card && card.querySelector(".pet-rename");
    (rename || libraryTab()).focus();
  }

  const libraryTab = () => document.querySelector('#tabs [data-view="library"]');

  function updateEditingActions() {
    const canEdit = view === "create" && !!prepared && !busy;
    $("adjustButton").disabled = !canEdit;
    $("aiButton").disabled = !canEdit;
    $("saveButton").disabled = !canEdit;
    $("saveButton").classList.toggle("primary", canEdit);
    $("importButton").disabled = busy;
    $("newPetButton").disabled = busy;
  }

  function showView(name) {
    view = name;
    $("libraryState").classList.toggle("hidden", name !== "library");
    $("settingsState").classList.toggle("hidden", name !== "settings");
    $("emptyState").classList.toggle("hidden", name !== "create" || !!prepared);
    $("reviewState").classList.toggle("hidden", name !== "create" || !prepared);
    document.querySelectorAll("#tabs button").forEach((b) => b.classList.toggle("on", b.dataset.view === name));
    updateEditingActions();
  }

  function startNewPet() {
    if (busy) return;
    prepared = null;
    $("preview").onload = null;
    $("preview").removeAttribute("src");
    $("markers").replaceChildren();
    $("legend").replaceChildren();
    $("warnings").replaceChildren();
    clearTimeout(toastTimer);
    $("toast").classList.add("hidden");
    host.send({ type: "newPet" });
    showView("create");
    $("importButton").focus();
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
      card.dataset.petId = pet.id;
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
      const title = document.createElement("div");
      title.className = "pet-title";
      const name = document.createElement("span");
      name.className = "pet-name" + (pet.name ? "" : " unnamed");
      name.textContent = pet.name || t("library.unnamed");
      const rename = document.createElement("button");
      rename.className = "pet-rename";
      rename.title = t("library.rename");
      rename.setAttribute("aria-label", t("library.rename"));
      rename.innerHTML = '<svg viewBox="0 0 24 24"><path d="M4 20h4L19 9l-4-4L4 16v4z"/></svg>';
      rename.addEventListener("click", (event) => { event.stopPropagation(); openRename(pet); });
      rename.addEventListener("keydown", (event) => event.stopPropagation());
      title.append(name, rename);
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
      remove.setAttribute("aria-label", t("library.delete") + " — " + date.textContent);
      remove.innerHTML = '<svg viewBox="0 0 24 24"><path d="M5 7h14M10 7V5h4v2M7 7l1 12h8l1-12"/></svg>';
      remove.addEventListener("click", (event) => {
        event.stopPropagation();
        if (busy || pet.selected) return;
        pendingDelete = pet.id;
        renderDeleteDetails();
        $("confirmDelete").showModal();
        $("deleteNo").focus();
      });
      const choose = () => { if (!busy && !pet.selected) host.send({ type: "selectPet", id: pet.id }); };
      card.addEventListener("click", choose);
      card.addEventListener("keydown", (event) => { if (event.target === card && (event.key === "Enter" || event.key === " ")) { event.preventDefault(); choose(); } });
      card.append(thumb, title, meta, remove);
      grid.appendChild(card);
    }
  }

  function renderDeleteDetails() {
    const pet = pets.find((item) => item.id === pendingDelete);
    if (!pet) return;
    const image = $("deletePreview");
    const thumbnail = thumbnails[pet.id];
    image.classList.toggle("hidden", !thumbnail);
    if (thumbnail) image.src = thumbnail;
    else image.removeAttribute("src");
    const date = $("deleteDate");
    date.dateTime = pet.created || "";
    date.textContent = pet.created ? new Intl.DateTimeFormat(language === "ja" ? "ja-JP" : "en-US", {
      year: "numeric", month: "short", day: "numeric", hour: "2-digit", minute: "2-digit",
    }).format(new Date(pet.created)) : "";
  }

  function closeDeleteDialog() {
    const id = pendingDelete;
    pendingDelete = null;
    $("confirmDelete").close();
    const card = [...$("petGrid").children].find((item) => item.dataset.petId === id);
    const remove = card && card.querySelector(".pet-delete");
    (remove || libraryTab()).focus();
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
    updateEditingActions();
  }
  function hideBusy() {
    busy = false;
    $("busy").classList.add("hidden");
    updateEditingActions();
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
    if (!prepared) return;
    if (view !== "create") showView("create");
    $("emptyState").classList.add("hidden");
    $("reviewState").classList.remove("hidden");
    updateEditingActions();

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
        if (message.view === "settings" || message.view === "voice") window.castorSettings.open(message.view === "voice" ? "voice" : null);
        if (window.castorSettings) window.castorSettings.rerender();
        break;
      case "showSettings": window.castorSettings.open(message.page || null); break;
      case "showLibrary": openLibrary(); break;
      case "library":
        pets = message.items || [];
        renderLibrary();
        break;
      case "thumbnail":
        thumbnails[message.id] = message.data;
        if (view === "library") renderLibrary();
        if (pendingDelete === message.id) renderDeleteDetails();
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
      default: if (window.castorSettings) window.castorSettings.receive(message);
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
  document.querySelectorAll("#tabs button").forEach((tab) => tab.addEventListener("click", () => {
    if (tab.dataset.view === "library") openLibrary();
    else if (tab.dataset.view === "settings") window.castorSettings.open();
    else showView("create");
  }));
  $("aiButton").addEventListener("click", () => { if (view === "create" && !busy && prepared) host.send({ type: "aiSetup" }); });
  $("newPetButton").addEventListener("click", startNewPet);
  $("renameNo").addEventListener("click", () => closeRename(false));
  $("renameYes").addEventListener("click", () => closeRename(true));
  $("renameInput").addEventListener("keydown", (event) => {
    if (event.key === "Enter") { event.preventDefault(); closeRename(true); }
  });
  $("renameDialog").addEventListener("cancel", (event) => { event.preventDefault(); closeRename(false); });
  $("deleteNo").addEventListener("click", closeDeleteDialog);
  $("confirmDelete").addEventListener("cancel", (event) => { event.preventDefault(); closeDeleteDialog(); });
  $("deleteYes").addEventListener("click", () => {
    const id = pendingDelete;
    closeDeleteDialog();
    libraryTab().focus();
    if (id && !busy) host.send({ type: "deletePet", id });
  });
  $("importButton").addEventListener("click", openImage);
  $("emptyState").addEventListener("click", openImage);
  $("adjustButton").addEventListener("click", () => { if (view === "create" && prepared && !busy) layoutMarkers(); });
  $("saveButton").addEventListener("click", () => {
    if (view !== "create" || !prepared || busy) return;
    host.send({ type: "save", markers: prepared.markers });
  });
  $("cancelButton").addEventListener("click", () => host.send({ type: "cancel" }));
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

  // A small surface for settings.js (loaded after this file).
  window.castorUI = { send: (message) => host.send(message), showView, toast, language: () => language };

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
    const mockNames = { "CastorPet-A.json": "しろちゃん" };
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
        if (message.type === "renamePet") { mockNames[message.id] = message.name.trim().slice(0, 40); message = { type: "library" }; }
        if (message.type === "library" || message.type === "selectPet" || message.type === "deletePet") {
          const now = Date.now();
          if (message.type === "deletePet") mockPets = mockPets.filter((p) => p !== message.id);
          if (message.type === "selectPet") mockSelected = message.id;
          reply({ type: "library", items: mockPets.map((id, i) => ({ id, created: new Date(now - i * 86400000).toISOString(), selected: id === mockSelected, name: mockNames[id] || null })) });
          mockPets.forEach((id, i) => reply({ type: "thumbnail", id, data: sample() }, 300 + i * 200));
          if (message.type === "selectPet") reply({ type: "toast", message: language === "ja" ? "デスクトップのペットを入れ替えました。" : "Swapped the pet on your desktop." });
        }
      },
    };
  }
})();

// ---------------------------------------------------------------------------
// Settings page. Kept in this file: installers since v1.0.0 (b) accept exactly
// index.html, app.css and app.js in UI/, so a new file would block updating.
// ---------------------------------------------------------------------------
// Castor for Windows — the settings page (General, Voice, AI, Advanced).
// The host sends the saved DesktopPreferences as JSON; the page edits a copy
// and sends it back whole, so the host's own decoding and validation decide
// what is stored. Outside WebView2 a small mock keeps the page previewable.
(() => {
  "use strict";
  const ui = window.castorUI;
  if (!ui) return;
  const $ = (id) => document.getElementById(id);
  const mock = !(window.chrome && window.chrome.webview);

  const TEXT = {
    ja: {
      "page.general": "一般", "page.voice": "音声", "page.ai": "AI", "page.advanced": "詳細",
      save: "保存", revert: "元に戻す", saved: "設定を保存しました。", unsaved: "保存していない変更があります。",
      language: "表示言語", scale: "ペットの大きさ", opacity: "ペットの不透明度",
      automaticTurn: "カーソルの方へ自動で向く", widerHeadMovement: "頭をより大きく動かす（ベータ）",
      naturalFaceMotion: "顔をより自然に動かす（ベータ）",
      "naturalFace.note": "頭の横の髪やリボンも根元から一緒に動きます。絵によっては髪以外のもの（上げた腕など）も動くことがあります。",
      evasionEnabled: "カーソルから逃げる", evasionStyle: "逃げ方", buttonDodgeEnabled: "押そうとしたボタンの上からどく",
      microphoneEnabled: "周囲の音に反応する（マイク）",
      "evasion.cute": "かわいく", "evasion.calm": "落ち着いて", "evasion.cool": "クールに", "evasion.proud": "堂々と", "evasion.robot": "ロボット風",
      systemTTSEnabled: "返事を読み上げる（Windows の標準音声）", systemVoice: "声", "voice.default": "Windows の既定の声",
      neuralTTSEnabled: "Neural TTS を使う（使えないときは標準音声）", neuralEndpoint: "接続先（この PC 内）", neuralModel: "モデル ID",
      neuralVoice: "声 ID", neuralInstruction: "声の指示", neuralLanguage: "言語（auto / ja / en など）", neuralSpeed: "話す速さ（0.5〜2）",
      "neural.title": "Neural TTS（任意）", prepare: "モデルを準備", openSetup: "導入 GUI を開く", openHelper: "Qwen 音声 helper を開く",
      "recognition.title": "音声認識", recognition: "認識エンジンと診断を表示", micPrivacy: "Windows のマイク設定を開く",
      provider: "会話に使う AI", endpoint: "接続先（この PC 内）", model: "モデル", loadModels: "モデル一覧を読み込む",
      "model.none": "（未選択）", personality: "性格・話し方",
      selectedBrain: "操作を頼むときの AI", automaticRouting: "依頼の内容で AI を自動で切り替える", externalBrain: "自動で切り替える先",
      "brain.local": "この PC の AI（会話のみ）",
      codexEndpoint: "Codex の接続先", claudeEndpoint: "Claude Code の接続先", workspacePath: "作業フォルダ（フルパス）",
      "advanced.note": "Codex / Claude Code に操作を頼むときの接続先です。外部へ送る前には毎回確認します。",
      "ai.note": "会話はこの PC で動く LM Studio / Ollama を使います。",
      "update.title": "アップデート", "update.note": "新しい版の確認と入れ替えは、ダウンローダーで行います。ペットと設定はそのまま残ります。",
      "update.version": "使っている版", openUpdater: "ダウンローダーを開く",
    },
    en: {
      "page.general": "General", "page.voice": "Voice", "page.ai": "AI", "page.advanced": "Advanced",
      save: "Save", revert: "Revert", saved: "Settings saved.", unsaved: "You have unsaved changes.",
      language: "Language", scale: "Pet size", opacity: "Pet opacity",
      automaticTurn: "Turn toward the cursor", widerHeadMovement: "Wider head movement (beta)",
      naturalFaceMotion: "More natural face motion (beta)",
      "naturalFace.note": "Hair and ribbons beside the head move with it from the roots. In some pictures other things next to the head (such as raised arms) may move too.",
      evasionEnabled: "Run away from the cursor", evasionStyle: "Style", buttonDodgeEnabled: "Move off buttons you are about to press",
      microphoneEnabled: "React to sounds around (microphone)",
      "evasion.cute": "Cute", "evasion.calm": "Calm", "evasion.cool": "Cool", "evasion.proud": "Proud", "evasion.robot": "Robot",
      systemTTSEnabled: "Read replies aloud (Windows voice)", systemVoice: "Voice", "voice.default": "Windows default voice",
      neuralTTSEnabled: "Use Neural TTS (falls back to the Windows voice)", neuralEndpoint: "Endpoint (this PC)", neuralModel: "Model ID",
      neuralVoice: "Voice ID", neuralInstruction: "Voice instruction", neuralLanguage: "Language (auto / ja / en …)", neuralSpeed: "Speed (0.5–2)",
      "neural.title": "Neural TTS (optional)", prepare: "Prepare model", openSetup: "Open setup", openHelper: "Open Qwen speech helper",
      "recognition.title": "Speech recognition", recognition: "Show recognizers and diagnostics", micPrivacy: "Open Windows microphone settings",
      provider: "AI for chat", endpoint: "Endpoint (this PC)", model: "Model", loadModels: "Load models",
      "model.none": "(none)", personality: "Personality",
      selectedBrain: "AI for actions", automaticRouting: "Pick the AI by request", externalBrain: "Switch to",
      "brain.local": "This PC's AI (chat only)",
      codexEndpoint: "Codex endpoint", claudeEndpoint: "Claude Code endpoint", workspacePath: "Workspace folder (full path)",
      "advanced.note": "Endpoints for asking Codex / Claude Code to act. Castor asks every time before sending anything out.",
      "ai.note": "Chat uses LM Studio / Ollama running on this PC.",
      "update.title": "Updates", "update.note": "The downloader checks for and installs new versions. Your pets and settings stay.",
      "update.version": "Version in use", openUpdater: "Open the downloader",
    },
  };
  const t = (key) => (TEXT[ui.language()] || TEXT.ja)[key] || TEXT.ja[key] || key;

  let saved = null;     // last stored preferences
  let draft = null;     // the copy being edited
  let voices = [];      // [{ id, name }]
  let models = [];      // [{ name, label }]
  let version = "";     // installed version, when known
  let page = "general";

  const percent = (values) => values.map((v) => ({ value: v, label: Math.round(v * 100) + "%" }));
  // Each field: key in DesktopPreferences, control, options.
  const PAGES = {
    general: [
      { key: "displayLanguage", type: "select", options: () => [{ value: "ja", label: "日本語" }, { value: "en", label: "English" }], label: "language" },
      { key: "scale", type: "select", number: true, options: () => percent([0.5, 0.75, 1, 1.25, 1.5, 2]) },
      { key: "petOpacity", type: "select", number: true, options: () => percent([1, 0.8, 0.6, 0.4, 0.2]), label: "opacity" },
      { key: "automaticTurn", type: "toggle" },
      { key: "widerHeadMovement", type: "toggle" },
      { key: "naturalFaceMotion", type: "toggle" },
      { note: "naturalFace.note", when: () => draft.naturalFaceMotion },
      { key: "evasionEnabled", type: "toggle" },
      { key: "evasionStyle", type: "select", options: () => ["cute", "calm", "cool", "proud", "robot"].map((v) => ({ value: v, label: t("evasion." + v) })), when: () => draft.evasionEnabled },
      { key: "buttonDodgeEnabled", type: "toggle" },
      { key: "microphoneEnabled", type: "toggle" },
      { heading: "update.title" },
      { note: "update.note" },
      { info: () => version ? t("update.version") + ": " + version : "" },
      { actions: ["openUpdater"] },
    ],
    voice: [
      { key: "systemTTSEnabled", type: "toggle" },
      { key: "systemVoice", type: "select", options: () => [{ value: "", label: t("voice.default") }].concat(voices.map((v) => ({ value: v.id, label: v.name }))) },
      { heading: "neural.title" },
      { key: "neuralTTSEnabled", type: "toggle" },
      { key: "neuralEndpoint", type: "text", when: () => draft.neuralTTSEnabled },
      { key: "neuralModel", type: "text", when: () => draft.neuralTTSEnabled },
      { key: "neuralVoice", type: "text", when: () => draft.neuralTTSEnabled },
      { key: "neuralInstruction", type: "text", when: () => draft.neuralTTSEnabled },
      { key: "neuralLanguage", type: "text", when: () => draft.neuralTTSEnabled },
      { key: "neuralSpeed", type: "number", min: 0.5, max: 2, step: 0.1, when: () => draft.neuralTTSEnabled },
      { actions: ["prepare", "openSetup", "openHelper"] },
      { heading: "recognition.title" },
      { actions: ["recognition", "micPrivacy"] },
    ],
    ai: [
      { note: "ai.note" },
      { key: "provider", type: "select", options: () => [{ value: "lmStudio", label: "LM Studio" }, { value: "ollama", label: "Ollama" }] },
      { key: "endpoint", type: "endpoint" },
      { key: "model", type: "model" },
      { key: "personality", type: "textarea" },
      { key: "selectedBrain", type: "select", options: () => [{ value: "local", label: t("brain.local") }, { value: "codex", label: "Codex" }, { value: "claudeCode", label: "Claude Code" }] },
      { key: "automaticRouting", type: "toggle" },
      { key: "externalBrain", type: "select", options: () => [{ value: "codex", label: "Codex" }, { value: "claudeCode", label: "Claude Code" }], when: () => draft.automaticRouting },
    ],
    advanced: [
      { note: "advanced.note" },
      { key: "codexEndpoint", type: "text" },
      { key: "claudeEndpoint", type: "text" },
      { key: "workspacePath", type: "text" },
    ],
  };

  // The chat endpoint and model are stored per provider.
  function read(key) {
    if (key === "endpoint") return draft.provider === "ollama" ? draft.ollamaEndpoint : draft.lmStudioEndpoint;
    if (key === "model") return draft.provider === "ollama" ? draft.ollamaModel : draft.lmStudioModel;
    return draft[key];
  }
  function write(key, value) {
    if (key === "endpoint") draft[draft.provider === "ollama" ? "ollamaEndpoint" : "lmStudioEndpoint"] = value;
    else if (key === "model") draft[draft.provider === "ollama" ? "ollamaModel" : "lmStudioModel"] = value;
    else draft[key] = value;
    if (key === "provider") models = [];
    if (key === "neuralTTSEnabled" && value) draft.systemTTSEnabled = true;
    if (key === "microphoneEnabled") draft.microphoneSetupCompleted = true;
    render();
  }
  const dirty = () => JSON.stringify(draft) !== JSON.stringify(saved);

  function control(field) {
    const id = "setting-" + field.key;
    const value = read(field.key);
    if (field.type === "toggle") {
      const label = document.createElement("label");
      label.className = "switch";
      const input = document.createElement("input");
      input.type = "checkbox"; input.id = id; input.checked = !!value;
      input.addEventListener("change", () => write(field.key, input.checked));
      const knob = document.createElement("span");
      label.append(input, knob);
      return label;
    }
    if (field.type === "select") {
      const select = document.createElement("select");
      select.id = id; select.className = "field";
      for (const option of field.options()) {
        const item = document.createElement("option");
        item.value = String(option.value); item.textContent = option.label;
        select.appendChild(item);
      }
      select.value = String(value);
      if (select.value !== String(value)) {   // a stored value that is not offered stays visible
        const item = document.createElement("option");
        item.value = String(value); item.textContent = String(value);
        select.appendChild(item); select.value = String(value);
      }
      select.addEventListener("change", () => write(field.key, field.number ? Number(select.value) : select.value));
      return select;
    }
    if (field.type === "model") {
      const box = document.createElement("div");
      box.className = "field-row";
      const select = document.createElement("select");
      select.id = id; select.className = "field";
      const options = [{ name: "", label: t("model.none") }].concat(models);
      if (value && !models.some((m) => m.name === value)) options.push({ name: value, label: value });
      for (const option of options) {
        const item = document.createElement("option");
        item.value = option.name; item.textContent = option.label;
        select.appendChild(item);
      }
      select.value = value || "";
      select.addEventListener("change", () => write("model", select.value));
      const load = document.createElement("button");
      load.className = "ghost"; load.textContent = t("loadModels");
      load.addEventListener("click", () => send({ type: "loadModels", prefs: draft }));
      box.append(select, load);
      return box;
    }
    if (field.type === "textarea") {
      const area = document.createElement("textarea");
      area.id = id; area.className = "field"; area.rows = 3; area.value = value || "";
      area.addEventListener("change", () => write(field.key, area.value));
      return area;
    }
    const input = document.createElement("input");
    input.id = id; input.className = "field";
    input.type = field.type === "number" ? "number" : "text";
    if (field.type === "number") { input.min = field.min; input.max = field.max; input.step = field.step; }
    input.value = value == null ? "" : String(value);
    input.addEventListener("change", () => write(field.key, field.type === "number" ? Number(input.value) : input.value));
    return input;
  }

  function render() {
    if (!draft) return;
    document.querySelectorAll("#settingsNav button").forEach((b) => {
      b.textContent = t("page." + b.dataset.page);
      b.classList.toggle("on", b.dataset.page === page);
    });
    const form = $("settingsForm");
    form.innerHTML = "";
    for (const field of PAGES[page]) {
      if (field.when && !field.when()) continue;
      if (field.heading) {
        const heading = document.createElement("h3");
        heading.className = "settings-heading"; heading.textContent = t(field.heading);
        form.appendChild(heading); continue;
      }
      if (field.info) {
        const text = field.info();
        if (!text) continue;
        const info = document.createElement("p");
        info.className = "settings-note"; info.textContent = text;
        form.appendChild(info); continue;
      }
      if (field.note) {
        const note = document.createElement("p");
        note.className = "settings-note"; note.textContent = t(field.note);
        form.appendChild(note); continue;
      }
      if (field.actions) {
        const row = document.createElement("div");
        row.className = "settings-actions";
        for (const action of field.actions) {
          const button = document.createElement("button");
          button.className = "ghost"; button.textContent = t(action);
          button.addEventListener("click", () => send({ type: "voiceAction", action, prefs: draft }));
          row.appendChild(button);
        }
        form.appendChild(row); continue;
      }
      const row = document.createElement("div");
      row.className = "settings-row" + (field.type === "toggle" ? " toggle-row" : "");
      const label = document.createElement("label");
      label.htmlFor = "setting-" + field.key;
      label.textContent = t(field.label || field.key);
      row.append(label, control(field));
      form.appendChild(row);
    }
    $("settingsSave").textContent = t("save");
    $("settingsRevert").textContent = t("revert");
    $("settingsSave").disabled = !dirty();
    $("settingsRevert").disabled = !dirty();
    $("settingsStatus").textContent = dirty() ? t("unsaved") : "";
  }

  function send(message) {
    if (mock) { mockReply(message); return; }
    ui.send(message);
  }

  window.castorSettings = {
    open(initialPage) {
      if (initialPage) page = initialPage;
      ui.showView("settings");
      send({ type: "settingsLoad" });
    },
    // Messages from the host; returns true when handled.
    receive(message) {
      switch (message.type) {
        case "settings":
          saved = message.prefs; draft = JSON.parse(JSON.stringify(saved));
          voices = message.voices || [];
          version = message.version || "";
          render(); return true;
        case "settingsSaved":
          saved = message.prefs; draft = JSON.parse(JSON.stringify(saved));
          render(); ui.toast(t("saved")); return true;
        case "models":
          models = message.items || [];
          render(); return true;
        case "recognition":
          ui.toast(message.text); return true;
      }
      return false;
    },
    rerender: render,
    hasUnsavedChanges: () => !!draft && dirty(),
  };

  document.querySelectorAll("#settingsNav button").forEach((button) => button.addEventListener("click", () => {
    page = button.dataset.page; render();
  }));
  $("settingsSave").addEventListener("click", () => { if (draft && dirty()) send({ type: "settingsSave", prefs: draft }); });
  $("settingsRevert").addEventListener("click", () => { draft = JSON.parse(JSON.stringify(saved)); render(); });

  // ---- Preview mock ----------------------------------------------------------
  let mockStore = {
    displayLanguage: "ja", scale: 1, petOpacity: 1, automaticTurn: true, widerHeadMovement: false, naturalFaceMotion: false,
    evasionEnabled: false, evasionStyle: "calm", buttonDodgeEnabled: false, microphoneEnabled: false, microphoneSetupCompleted: true,
    systemTTSEnabled: false, systemVoice: "", neuralTTSEnabled: false, neuralEndpoint: "http://127.0.0.1:8000/v1/audio/speech",
    neuralModel: "mlx-community/Qwen3-TTS-12Hz-0.6B-CustomVoice-8bit", neuralVoice: "Ryan", neuralInstruction: "Speak gently.",
    neuralLanguage: "auto", neuralSpeed: 1, provider: "lmStudio", lmStudioEndpoint: "http://127.0.0.1:1234",
    ollamaEndpoint: "http://127.0.0.1:11434", lmStudioModel: "", ollamaModel: "", personality: "穏やかで少し不器用なデスクトップの相棒。",
    selectedBrain: "local", automaticRouting: false, externalBrain: "codex", codexEndpoint: "ws://127.0.0.1:4500",
    claudeEndpoint: "http://127.0.0.1:4510", workspacePath: "",
  };
  function mockReply(message) {
    const reply = (m, delay) => setTimeout(() => window.castorSettings.receive(m), delay || 0);
    if (message.type === "settingsLoad") reply({ type: "settings", prefs: mockStore, version: "v1.0.0-d", voices: [{ id: "haruka", name: "Microsoft Haruka" }, { id: "zira", name: "Microsoft Zira" }] });
    if (message.type === "settingsSave") { mockStore = JSON.parse(JSON.stringify(message.prefs)); reply({ type: "settingsSaved", prefs: mockStore }, 200); }
    if (message.type === "loadModels") reply({ type: "models", items: [{ name: "qwen3-8b", label: "qwen3-8b (8B)" }, { name: "gemma-3-1b", label: "gemma-3-1b (1B) — 小さいモデル: 操作の依頼には向きません" }] }, 400);
    if (message.type === "voiceAction" && message.action === "recognition") reply({ type: "recognition", text: "Microsoft Speech Recognizer 8.0 (ja-JP)" });
  }
})();
