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
    },
    en: {
      "page.general": "General", "page.voice": "Voice", "page.ai": "AI", "page.advanced": "Advanced",
      save: "Save", revert: "Revert", saved: "Settings saved.", unsaved: "You have unsaved changes.",
      language: "Language", scale: "Pet size", opacity: "Pet opacity",
      automaticTurn: "Turn toward the cursor", widerHeadMovement: "Wider head movement (beta)",
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
    },
  };
  const t = (key) => (TEXT[ui.language()] || TEXT.ja)[key] || TEXT.ja[key] || key;

  let saved = null;     // last stored preferences
  let draft = null;     // the copy being edited
  let voices = [];      // [{ id, name }]
  let models = [];      // [{ name, label }]
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
      { key: "evasionEnabled", type: "toggle" },
      { key: "evasionStyle", type: "select", options: () => ["cute", "calm", "cool", "proud", "robot"].map((v) => ({ value: v, label: t("evasion." + v) })), when: () => draft.evasionEnabled },
      { key: "buttonDodgeEnabled", type: "toggle" },
      { key: "microphoneEnabled", type: "toggle" },
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
    displayLanguage: "ja", scale: 1, petOpacity: 1, automaticTurn: true, widerHeadMovement: false,
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
    if (message.type === "settingsLoad") reply({ type: "settings", prefs: mockStore, voices: [{ id: "haruka", name: "Microsoft Haruka" }, { id: "zira", name: "Microsoft Zira" }] });
    if (message.type === "settingsSave") { mockStore = JSON.parse(JSON.stringify(message.prefs)); reply({ type: "settingsSaved", prefs: mockStore }, 200); }
    if (message.type === "loadModels") reply({ type: "models", items: [{ name: "qwen3-8b", label: "qwen3-8b (8B)" }, { name: "gemma-3-1b", label: "gemma-3-1b (1B) — 小さいモデル: 操作の依頼には向きません" }] }, 400);
    if (message.type === "voiceAction" && message.action === "recognition") reply({ type: "recognition", text: "Microsoft Speech Recognizer 8.0 (ja-JP)" });
  }
})();
