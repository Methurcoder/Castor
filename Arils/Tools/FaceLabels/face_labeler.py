#!/usr/bin/env python3
"""A small browser labeller for the Arils face boxes, with the neck.

The external annotator this dataset started with draws only the four original
labels and cannot add a fifth, and it cannot open the detector's drafts. This
tool does both: it opens each image with the best starting point available
(hand-verified label, else detector draft, else nothing), shows the label rules
next to the picture, and writes straight into `arils_manual_annotations.json`
in the same schema, now with an optional `neck` part.

    python3 face_labeler.py                 # opens http://127.0.0.1:8140
    python3 face_labeler.py --no-browser

It binds to 127.0.0.1 only and reads nothing but the dataset folder. Before the
first save of a session the manual file is copied into `backups/`, because it
is the only hand-verified label set the dataset has.

Label rules v2 (the same text the page shows):
    head   top of the hair incl. hat and ornaments; sides to the hair beside the
           face, not hair hanging past the shoulders; bottom edge at the chin
    eyes   the visible eye only, upper lash line to lower lash line, corner to
           corner incl. lash tips, no eyebrow, no margin (the rig adds ~20%)
    mouth  the drawn lips, the inside too when open, no margin (the rig adds
           ~30%); a closed mouth is a quarter of its width tall
    neck   chin to where the neck meets the collar, the neck's width; when hair
           or clothing hides it, draw the best guess and mark it hidden
Entries saved here carry `labelRules: "v2"` so older labels drawn to looser
rules can be told apart when the calibration is re-fitted.
"""

from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import pathlib
import shutil
import sys
import tempfile
import threading
import urllib.parse
import webbrowser
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

DEFAULT_DATASET = pathlib.Path.home() / "開発/Pomegranate/Arils_Dataset"
PARTS = ("head", "eyeLeft", "eyeRight", "mouth", "neck")
REQUIRED = PARTS[:4]
VISIBILITY = ("visible", "occludedEstimated")
LABEL_RULES = "v2"


class Dataset:
    def __init__(self, root: pathlib.Path) -> None:
        self.root = root
        self.manual_path = root / "arils_manual_annotations.json"
        self.draft_path = root / "arils_draft_annotations.json"
        self.lock = threading.Lock()
        self.backed_up = False
        manifest = json.loads((root / "manifest.json").read_text())
        manual = json.loads(self.manual_path.read_text())
        set_aside = {item["image"] for item in manual.get("skipped", [])}
        self.items = []
        for item in manifest["items"]:
            name = pathlib.Path(item["file"]).name
            if name in set_aside or item.get("status", "").startswith("excluded"):
                continue
            if (root / item["file"]).exists():
                self.items.append({"image": name, "id": item["id"], "category": item.get("category", ""),
                                   "file": item["file"]})
        self.by_name = {item["image"]: item for item in self.items}
        # The schema validator lives with the dataset's own tools; use it when
        # present so a save can never produce a file the training side rejects.
        self.schema = None
        tools = root / "tools"
        if (tools / "auto_annotation_schema.py").exists():
            sys.path.insert(0, str(tools))
            try:
                import auto_annotation_schema  # type: ignore
                if "neck" in getattr(auto_annotation_schema, "OPTIONAL_PARTS", ()):
                    self.schema = auto_annotation_schema
            except Exception as error:  # noqa: BLE001 - report and carry on
                print(f"[labeler] schema validator unavailable: {error}")

    def _entries(self, path: pathlib.Path) -> dict[str, dict]:
        if not path.exists():
            return {}
        return {entry["image"]: entry for entry in json.loads(path.read_text()).get("entries", [])}

    def listing(self) -> list[dict]:
        manual, draft = self._entries(self.manual_path), self._entries(self.draft_path)
        out = []
        for item in self.items:
            name = item["image"]
            if name in manual:
                state = "v2" if manual[name].get("labelRules") == LABEL_RULES else "v1"
            elif name in draft:
                state = "draft"
            else:
                state = "none"
            out.append({**{k: item[k] for k in ("image", "id", "category")}, "state": state})
        return out

    def load(self, name: str) -> dict:
        from PIL import Image

        item = self.by_name[name]
        with Image.open(self.root / item["file"]) as image:
            width, height = image.size
        manual, draft = self._entries(self.manual_path), self._entries(self.draft_path)
        source, parts = "none", {}
        for label, entries in (("manual", manual), ("draft", draft)):
            entry = entries.get(name)
            if entry and entry["annotation"].get("faces"):
                source = label
                if label == "manual":
                    source = "manual-v2" if entry.get("labelRules") == LABEL_RULES else "manual-v1"
                for part, value in entry["annotation"]["faces"][0]["parts"].items():
                    if value.get("box"):
                        parts[part] = {"box": value["box"], "visibility": value.get("visibility", "visible")}
                break
        return {"image": name, "width": width, "height": height, "source": source, "parts": parts}

    def save(self, name: str, parts: dict) -> dict:
        item = self.by_name[name]
        clean = {}
        for part in PARTS:
            value = parts.get(part)
            if value is None:
                if part in REQUIRED:
                    raise ValueError(f"{part} is missing")
                continue
            box = {key: float(value["box"][key]) for key in ("x", "y", "width", "height")}
            visibility = value.get("visibility", "visible")
            if visibility not in VISIBILITY:
                raise ValueError(f"{part}: unknown visibility {visibility!r}")
            clean[part] = {"visibility": visibility, "confidence": 1.0,
                           "box": {k: round(v, 6) for k, v in box.items()}}
        annotation = {
            "faceSetConfidence": 1.0, "mediaKind": "2d", "contentRating": "safe", "contentConfidence": 1.0,
            "faces": [{"faceConfidence": 1.0, "faceView": "unknown", "viewConfidence": 0.0,
                       "normalizationWarnings": ["faceViewNotRecordedByManualAnnotator"],
                       "parts": clean}],
        }
        if self.schema is not None:
            annotation = self.schema.validate_model_annotation(annotation)
        else:
            annotation["faces"][0]["faceId"] = "face-001"
        now = dt.datetime.now(dt.timezone.utc).isoformat()
        entry = {
            "image": name,
            "annotation": annotation,
            "category": item["category"],
            "generator": "face-labeler",
            "group": item["id"],
            "labelRules": LABEL_RULES,
            "review": {"state": "humanAccepted", "issues": [],
                       "note": "face_labeler.py で新ルール(v2)に沿って確認・修正。", "reviewedAt": now},
        }
        with self.lock:
            document = json.loads(self.manual_path.read_text())
            if not self.backed_up:
                backups = self.root / "backups"
                backups.mkdir(exist_ok=True)
                stamp = dt.datetime.now().strftime("%Y%m%d-%H%M%S")
                shutil.copy2(self.manual_path, backups / f"arils_manual_annotations.{stamp}.json")
                self.backed_up = True
            entries = document.get("entries", [])
            for index, existing in enumerate(entries):
                if existing["image"] == name:
                    entries[index] = entry
                    break
            else:
                entries.append(entry)
            document["entries"] = entries
            document["updatedAt"] = now
            handle, temporary = tempfile.mkstemp(dir=self.root, suffix=".json.tmp")
            with os.fdopen(handle, "w") as stream:
                stream.write(json.dumps(document, indent=1, ensure_ascii=False) + "\n")
            os.replace(temporary, self.manual_path)
        return {"saved": name, "labelRules": LABEL_RULES}


def make_handler(dataset: Dataset):
    class Handler(BaseHTTPRequestHandler):
        def log_message(self, fmt, *args):  # noqa: A002 - keep the terminal quiet
            pass

        def _send(self, status: int, body: bytes, content_type: str) -> None:
            self.send_response(status)
            self.send_header("Content-Type", content_type)
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            self.wfile.write(body)

        def _json(self, status: int, payload) -> None:
            self._send(status, json.dumps(payload, ensure_ascii=False).encode(), "application/json; charset=utf-8")

        def do_GET(self):
            url = urllib.parse.urlparse(self.path)
            query = urllib.parse.parse_qs(url.query)
            try:
                if url.path == "/":
                    self._send(200, PAGE.encode(), "text/html; charset=utf-8")
                elif url.path == "/api/items":
                    self._json(200, dataset.listing())
                elif url.path == "/api/item":
                    name = query.get("image", [""])[0]
                    if name not in dataset.by_name:
                        return self._json(404, {"error": "unknown image"})
                    self._json(200, dataset.load(name))
                elif url.path == "/image":
                    name = query.get("image", [""])[0]
                    if name not in dataset.by_name:
                        return self._json(404, {"error": "unknown image"})
                    path = dataset.root / dataset.by_name[name]["file"]
                    kind = "image/png" if path.suffix.lower() == ".png" else "image/jpeg"
                    self._send(200, path.read_bytes(), kind)
                else:
                    self._json(404, {"error": "not found"})
            except Exception as error:  # noqa: BLE001 - surface to the page
                self._json(500, {"error": str(error)})

        def do_POST(self):
            if urllib.parse.urlparse(self.path).path != "/api/save":
                return self._json(404, {"error": "not found"})
            try:
                payload = json.loads(self.rfile.read(int(self.headers.get("Content-Length", 0))))
                name = payload.get("image")
                if name not in dataset.by_name:
                    return self._json(404, {"error": "unknown image"})
                self._json(200, dataset.save(name, payload.get("parts", {})))
            except Exception as error:  # noqa: BLE001 - surface to the page
                self._json(400, {"error": str(error)})

    return Handler


PAGE = r"""<!doctype html>
<html lang="ja">
<head>
<meta charset="utf-8">
<title>Face Labeler</title>
<style>
:root { --bg:#16171b; --panel:#202127; --line:#33353d; --text:#e8e8ec; --muted:#9a9ca6;
  --head:#19c8ff; --eyeLeft:#34e84a; --eyeRight:#4f7dff; --mouth:#ff4545; --neck:#ffb020; }
* { box-sizing:border-box; }
body { margin:0; background:var(--bg); color:var(--text); font:14px/1.5 -apple-system,"Hiragino Sans",sans-serif;
  display:grid; grid-template-columns:230px 1fr 340px; height:100vh; overflow:hidden; }
aside, section#side { background:var(--panel); overflow:auto; }
aside { border-right:1px solid var(--line); }
section#side { border-left:1px solid var(--line); padding:14px; }
h1 { font-size:14px; margin:12px 12px 4px; }
#progress { margin:0 12px 10px; color:var(--muted); font-size:12px; }
#list button { display:flex; width:100%; gap:8px; align-items:center; text-align:left; border:0; background:none;
  color:var(--text); padding:6px 12px; cursor:pointer; font-size:12px; }
#list button:hover { background:#2a2c33; }
#list button.current { background:#343844; }
.badge { flex:none; font-size:10px; padding:1px 6px; border-radius:8px; border:1px solid var(--line); color:var(--muted); }
.badge.v2 { color:#7be38a; border-color:#3f7a48; }
.badge.v1 { color:#e3c27b; border-color:#7a6a3f; }
.badge.draft { color:#8fb4ff; border-color:#3f557a; }
main { position:relative; overflow:hidden; }
svg#stage { width:100%; height:100%; display:block; cursor:crosshair; touch-action:none; }
#status { position:absolute; left:12px; top:10px; background:#000a; padding:4px 10px; border-radius:6px; font-size:12px; }
.parts { display:grid; gap:6px; margin-bottom:12px; }
.parts button { display:flex; justify-content:space-between; align-items:center; border:1px solid var(--line); border-radius:6px;
  background:#26282f; color:var(--text); padding:6px 10px; cursor:pointer; font-size:13px; }
.parts button.sel { outline:2px solid var(--text); }
.swatch { width:12px; height:12px; border-radius:3px; display:inline-block; margin-right:8px; vertical-align:-1px; }
.hidden-tag { font-size:11px; color:#ffb020; }
.rules { background:#1a1b20; border:1px solid var(--line); border-radius:8px; padding:10px 12px; margin:10px 0; }
.rules h2 { font-size:13px; margin:0 0 6px; }
.rules ul { margin:0; padding-left:18px; }
.rules li { margin:2px 0; }
.rules svg { width:100%; height:auto; margin-top:8px; background:#f4efe6; border-radius:6px; }
.row { display:flex; gap:6px; flex-wrap:wrap; margin:8px 0; }
.row button, #save { border:1px solid var(--line); border-radius:6px; background:#2b2d35; color:var(--text); padding:6px 10px; cursor:pointer; font-size:12px; }
#save { width:100%; padding:10px; font-size:14px; background:#2f6b3a; border-color:#3f8a4c; margin-top:6px; }
#warnings { color:#ffb020; font-size:12px; margin:6px 0; }
.keys { color:var(--muted); font-size:11px; margin-top:12px; }
</style>
</head>
<body>
<aside>
  <h1>画像</h1>
  <div id="progress"></div>
  <div id="list"></div>
</aside>
<main>
  <svg id="stage"></svg>
  <div id="status"></div>
</main>
<section id="side">
  <div class="parts" id="parts"></div>
  <div class="row">
    <button id="toggleHidden">隠れている（推測で描いた）: 切替 [H]</button>
  </div>
  <div class="row" id="helpers"></div>
  <div class="rules" id="rules"></div>
  <div id="warnings"></div>
  <button id="save">保存して次へ [Enter]</button>
  <div class="row">
    <button id="viewFace">顔まわり [F]</button>
    <button id="viewAll">全体 [A]</button>
  </div>
  <div class="keys">
    1〜5 部位を選ぶ ／ 箱の中をドラッグで移動、角や辺で大きさ変更 ／ 空いている所をドラッグで選択中の部位を描き直し ／
    矢印キーで1px移動（Shiftで10px）／ ホイールで拡大縮小
  </div>
</section>
<script>
const PARTS = [
  {key:"head", name:"頭"}, {key:"eyeLeft", name:"目（向かって左）"}, {key:"eyeRight", name:"目（向かって右）"},
  {key:"mouth", name:"口"}, {key:"neck", name:"首"}];
const COLOR = k => getComputedStyle(document.documentElement).getPropertyValue("--" + k).trim();
const EYE_SVG = `<svg viewBox="0 0 300 120"><g font-size="12" fill="#333">
  <text x="10" y="16">良い</text><text x="160" y="16">悪い（眉まで入れている）</text></g>
  <g transform="translate(20,20)"><path d="M10 24 q40 -26 90 -4" stroke="#333" stroke-width="4" fill="none"/>
  <path d="M8 58 q48 -34 98 -6" stroke="#222" stroke-width="5" fill="none"/><ellipse cx="56" cy="68" rx="18" ry="20" fill="#7a5130"/>
  <path d="M18 86 q38 14 80 -4" stroke="#444" stroke-width="2" fill="none"/>
  <rect x="6" y="40" width="104" height="54" fill="none" stroke="#1faa34" stroke-width="3"/></g>
  <g transform="translate(170,20)"><path d="M10 24 q40 -26 90 -4" stroke="#333" stroke-width="4" fill="none"/>
  <path d="M8 58 q48 -34 98 -6" stroke="#222" stroke-width="5" fill="none"/><ellipse cx="56" cy="68" rx="18" ry="20" fill="#7a5130"/>
  <path d="M18 86 q38 14 80 -4" stroke="#444" stroke-width="2" fill="none"/>
  <rect x="2" y="4" width="112" height="94" fill="none" stroke="#e02020" stroke-width="3" stroke-dasharray="6 4"/></g></svg>`;
const MOUTH_SVG = `<svg viewBox="0 0 300 90"><g font-size="12" fill="#333">
  <text x="10" y="16">良い（閉じた口: 高さ＝幅の1/4）</text><text x="176" y="16">悪い（余白が多い）</text></g>
  <path d="M30 52 q40 12 80 0" stroke="#8a3a3a" stroke-width="4" fill="none"/>
  <rect x="28" y="40" width="84" height="21" fill="none" stroke="#1faa34" stroke-width="3"/>
  <path d="M190 52 q40 12 80 0" stroke="#8a3a3a" stroke-width="4" fill="none"/>
  <rect x="172" y="26" width="116" height="56" fill="none" stroke="#e02020" stroke-width="3" stroke-dasharray="6 4"/></svg>`;
const HEAD_SVG = `<svg viewBox="0 0 300 190"><g font-size="12" fill="#333"><text x="200" y="40">頭の箱</text>
  <text x="200" y="120">あご先＝境目</text><text x="200" y="165">首の箱</text></g>
  <path d="M60 60 q60 -70 120 0 l6 60 q-66 40 -132 0 z" fill="#6b4a2f"/>
  <path d="M78 70 q42 -30 84 0 l-4 44 q-38 34 -76 0 z" fill="#f6d8c2"/>
  <rect x="104" y="128" width="32" height="46" fill="#f0cdb5"/>
  <rect x="48" y="12" width="144" height="120" fill="none" stroke="#19a8e0" stroke-width="3"/>
  <rect x="100" y="132" width="40" height="44" fill="none" stroke="#e59a10" stroke-width="3"/>
  <line x1="40" y1="132" x2="196" y2="132" stroke="#333" stroke-dasharray="3 3"/></svg>`;
const RULES = {
  head: {title:"頭", items:["上: 髪のてっぺん。帽子や頭の飾りも含める","左右: 顔の横にある髪まで。肩より下に垂れる髪は含めない",
    "下: <b>あご先</b>。首の箱の上の辺とそろえる"], svg:HEAD_SVG},
  eyeLeft: {title:"目", items:["見えている目だけを<b>ぴったり</b>囲む","上まつ毛の一番上 〜 下まつ毛の一番下",
    "目頭 〜 目尻。はね上がったまつ毛の先も含める","<b>眉は入れない</b>","余白は付けない（アプリが約2割足す）",
    "閉じた目: 線を端から端まで。高さは線の太さだけ","隠れていたら推測で描き「隠れている」にする"], svg:EYE_SVG},
  mouth: {title:"口", items:["描かれている唇の線を<b>ぴったり</b>囲む。開いていれば口の中も",
    "余白は付けない（アプリが約3割足す）","閉じた口（線が1本）: 高さ＝幅の1/4（下のボタン）"], svg:MOUTH_SVG},
  neck: {title:"首", items:["上: <b>あご先</b>（頭の箱の下の辺と同じ高さ）","下: 首の付け根（鎖骨や襟と接する線）",
    "左右: 首の幅","髪や服で隠れていても<b>推測で描き</b>「隠れている」にする"], svg:HEAD_SVG},
};
RULES.eyeRight = RULES.eyeLeft;

let items = [], current = null, data = null, boxes = {}, selected = "head", dirty = false, view = null, drag = null;
const svg = document.getElementById("stage");
const NS = "http://www.w3.org/2000/svg";

async function api(path, body) {
  const r = await fetch(path, body ? {method:"POST", headers:{"Content-Type":"application/json"}, body:JSON.stringify(body)} : {});
  const j = await r.json(); if (!r.ok) throw new Error(j.error || r.status); return j;
}
function badge(s) { return {v2:"新ルール済", v1:"旧ルール", draft:"下書き", none:"未着手"}[s]; }
function renderList() {
  const list = document.getElementById("list"); list.innerHTML = "";
  for (const it of items) {
    const b = document.createElement("button"); if (current === it.image) b.className = "current";
    b.innerHTML = `<span class="badge ${it.state}">${badge(it.state)}</span><span>${it.image}</span>`;
    b.onclick = () => open(it.image); list.appendChild(b);
  }
  const done = items.filter(i => i.state === "v2").length;
  document.getElementById("progress").textContent = `新ルールで確認済み ${done} / ${items.length}`;
}
// Boxes are kept in image pixels, top-left; the file stores normalized centres.
function fromFile(b) { return {x:(b.x - b.width/2)*data.width, y:(b.y - b.height/2)*data.height, w:b.width*data.width, h:b.height*data.height}; }
function toFile(b) { return {x:(b.x + b.w/2)/data.width, y:(b.y + b.h/2)/data.height, width:b.w/data.width, height:b.h/data.height}; }
function clampBox(b) {
  const W = data.width, H = data.height;
  b.w = Math.max(2, Math.min(b.w, W)); b.h = Math.max(2, Math.min(b.h, H));
  b.x = Math.max(0, Math.min(b.x, W - b.w)); b.y = Math.max(0, Math.min(b.y, H - b.h)); return b;
}
async function open(name) {
  if (dirty && !confirm("保存していない変更があります。移動しますか？")) return;
  current = name; data = await api("/api/item?image=" + encodeURIComponent(name));
  boxes = {}; neckGuessed = false;
  for (const p of PARTS) if (data.parts[p.key]) boxes[p.key] = {...fromFile(data.parts[p.key].box), vis:data.parts[p.key].visibility};
  if (!boxes.head) { const W = data.width, H = data.height; boxes.head = {x:W*0.35, y:H*0.03, w:W*0.3, h:H*0.15, vis:"visible"}; }
  for (const k of ["eyeLeft","eyeRight","mouth"]) if (!boxes[k]) {
    const h = boxes.head, off = {eyeLeft:0.28, eyeRight:0.58, mouth:0.43}[k];
    boxes[k] = {x:h.x + h.w*off, y:h.y + h.h*(k === "mouth" ? 0.8 : 0.6), w:h.w*0.15, h:h.h*0.07, vis:"visible"};
  }
  if (!boxes.neck) { // A placeholder under the chin; always needs a look.
    const h = boxes.head; boxes.neck = {x:h.x + h.w*0.33, y:h.y + h.h, w:h.w*0.34, h:h.h*0.32, vis:"visible"}; neckGuessed = true;
  }
  dirty = false; selected = "head"; fitView("face"); renderList(); renderSide(); draw();
  const src = {"manual-v2":"新ルールで確認済みのラベル","manual-v1":"旧ルールのラベル（新ルールに合わせて直してください）",
    "draft":"検出器の下書き（全部の箱を確認してください）","none":"下書きなし（仮の箱）"}[data.source];
  document.getElementById("status").textContent = `${name} ／ 読み込み元: ${src}` + (neckGuessed ? " ／ 首は仮置き" : "");
}
let neckGuessed = false;
function fitView(mode) {
  if (mode === "all") { view = {x:0, y:0, w:data.width, h:data.height}; }
  else {
    const all = Object.values(boxes); const x0 = Math.min(...all.map(b => b.x)), y0 = Math.min(...all.map(b => b.y));
    const x1 = Math.max(...all.map(b => b.x + b.w)), y1 = Math.max(...all.map(b => b.y + b.h));
    const pw = (x1 - x0) * 0.35, ph = (y1 - y0) * 0.25;
    view = {x:x0 - pw, y:y0 - ph, w:(x1 - x0) + pw*2, h:(y1 - y0) + ph*2};
  }
  draw();
}
function pxPerScreen() { const r = svg.getBoundingClientRect(); return Math.max(view.w / r.width, view.h / r.height); }
function draw() {
  if (!data) return;
  svg.setAttribute("viewBox", `${view.x} ${view.y} ${view.w} ${view.h}`); svg.innerHTML = "";
  const img = document.createElementNS(NS, "image");
  img.setAttribute("href", "/image?image=" + encodeURIComponent(current)); img.setAttribute("width", data.width); img.setAttribute("height", data.height);
  svg.appendChild(img);
  const s = pxPerScreen();
  for (const p of PARTS) {
    const b = boxes[p.key]; if (!b) continue; const sel = p.key === selected;
    const r = document.createElementNS(NS, "rect");
    Object.entries({x:b.x, y:b.y, width:b.w, height:b.h, fill: sel ? "rgba(255,255,255,0.06)" : "transparent",
      stroke:COLOR(p.key), "stroke-width":(sel ? 2.5 : 1.6) * s, "stroke-dasharray": b.vis === "occludedEstimated" ? `${6*s} ${4*s}` : "none"})
      .forEach(([k, v]) => r.setAttribute(k, v));
    r.dataset.part = p.key; r.dataset.handle = "move"; r.style.cursor = "move"; svg.appendChild(r);
  }
  const b = boxes[selected]; const hs = 9 * s;
  const handles = {nw:[b.x,b.y], n:[b.x+b.w/2,b.y], ne:[b.x+b.w,b.y], e:[b.x+b.w,b.y+b.h/2], se:[b.x+b.w,b.y+b.h],
    s:[b.x+b.w/2,b.y+b.h], sw:[b.x,b.y+b.h], w:[b.x,b.y+b.h/2]};
  for (const [name, [hx, hy]] of Object.entries(handles)) {
    const h = document.createElementNS(NS, "rect");
    Object.entries({x:hx - hs/2, y:hy - hs/2, width:hs, height:hs, fill:"#fff", stroke:"#000", "stroke-width":s})
      .forEach(([k, v]) => h.setAttribute(k, v));
    h.dataset.part = selected; h.dataset.handle = name; h.style.cursor = name + "-resize"; svg.appendChild(h);
  }
  renderWarnings();
}
function point(ev) { const pt = svg.createSVGPoint(); pt.x = ev.clientX; pt.y = ev.clientY; return pt.matrixTransform(svg.getScreenCTM().inverse()); }
svg.addEventListener("pointerdown", ev => {
  if (!data) return; const p = point(ev); const t = ev.target;
  if (t.dataset && t.dataset.part) {
    if (t.dataset.handle === "move" && t.dataset.part !== selected) { selected = t.dataset.part; renderSide(); }
    drag = {mode:t.dataset.handle, start:p, orig:{...boxes[selected]}};
  } else {
    drag = {mode:"new", start:p, orig:{...boxes[selected]}};
  }
  svg.setPointerCapture(ev.pointerId);
});
svg.addEventListener("pointermove", ev => {
  if (!drag) return; const p = point(ev); const dx = p.x - drag.start.x, dy = p.y - drag.start.y; const o = drag.orig; let b = {...o};
  if (drag.mode === "move") { b.x = o.x + dx; b.y = o.y + dy; }
  else if (drag.mode === "new") { b.x = Math.min(drag.start.x, p.x); b.y = Math.min(drag.start.y, p.y); b.w = Math.abs(dx); b.h = Math.abs(dy); }
  else {
    if (drag.mode.includes("w")) { b.x = Math.min(o.x + dx, o.x + o.w - 2); b.w = o.w - (b.x - o.x); }
    if (drag.mode.includes("e")) { b.w = Math.max(2, o.w + dx); }
    if (drag.mode.includes("n")) { b.y = Math.min(o.y + dy, o.y + o.h - 2); b.h = o.h - (b.y - o.y); }
    if (drag.mode.startsWith("s") || drag.mode === "se" || drag.mode === "sw") { b.h = Math.max(2, o.h + dy); }
  }
  if (drag.mode === "new" && (b.w < 3 || b.h < 3)) return;
  boxes[selected] = clampBox({...b, vis:o.vis}); if (selected === "neck") neckGuessed = false; dirty = true; draw();
});
svg.addEventListener("pointerup", () => { drag = null; });
svg.addEventListener("wheel", ev => {
  if (!data) return; ev.preventDefault(); const p = point(ev); const f = ev.deltaY > 0 ? 1.15 : 1 / 1.15;
  view = {x:p.x - (p.x - view.x) * f, y:p.y - (p.y - view.y) * f, w:view.w * f, h:view.h * f}; draw();
}, {passive:false});
function renderSide() {
  const el = document.getElementById("parts"); el.innerHTML = "";
  PARTS.forEach((p, i) => {
    const b = document.createElement("button"); if (p.key === selected) b.className = "sel";
    const hidden = boxes[p.key] && boxes[p.key].vis === "occludedEstimated";
    b.innerHTML = `<span><span class="swatch" style="background:${COLOR(p.key)}"></span>${i + 1}. ${p.name}</span>` +
      (hidden ? `<span class="hidden-tag">隠れている</span>` : "");
    b.onclick = () => { selected = p.key; renderSide(); draw(); }; el.appendChild(b);
  });
  const r = RULES[selected];
  document.getElementById("rules").innerHTML = `<h2>${r.title}のルール</h2><ul>${r.items.map(i => `<li>${i}</li>`).join("")}</ul>${r.svg}`;
  const helpers = document.getElementById("helpers"); helpers.innerHTML = "";
  const add = (label, fn) => { const b = document.createElement("button"); b.textContent = label; b.onclick = () => { fn(); dirty = true; renderSide(); draw(); }; helpers.appendChild(b); };
  if (selected === "mouth") add("閉じた口: 高さ＝幅の1/4", () => { const m = boxes.mouth, cy = m.y + m.h/2; m.h = m.w / 4; m.y = cy - m.h/2; });
  if (selected === "neck") add("上の辺をあご先（頭の下の辺）にそろえる", () => { const n = boxes.neck, bottom = n.y + n.h, top = boxes.head.y + boxes.head.h; n.y = top; n.h = Math.max(2, bottom - top); });
  if (selected === "head") add("下の辺を首の上の辺にそろえる", () => { const h = boxes.head; h.h = Math.max(2, boxes.neck.y - h.y); });
}
function overlap(a, b) { return Math.max(0, Math.min(a.x + a.w, b.x + b.w) - Math.max(a.x, b.x)) * Math.max(0, Math.min(a.y + a.h, b.y + b.h) - Math.max(a.y, b.y)); }
function renderWarnings() {
  const w = [], h = boxes.head, n = boxes.neck;
  if (overlap(boxes.eyeLeft, boxes.eyeRight) > 0) w.push("左右の目の箱が重なっています");
  if (boxes.eyeLeft.x + boxes.eyeLeft.w/2 > boxes.eyeRight.x + boxes.eyeRight.w/2) w.push("「向かって左の目」が右側にあります");
  if (Math.abs((h.y + h.h) - n.y) > h.h * 0.04) w.push("頭の下の辺と首の上の辺がずれています（どちらも「あご先」）");
  const m = boxes.mouth; if (m.h > m.w * 0.9) w.push("口の箱が縦に長すぎないか確認してください");
  if (neckGuessed) w.push("首はまだ仮置きです");
  document.getElementById("warnings").innerHTML = w.map(x => "⚠ " + x).join("<br>");
}
async function save() {
  const parts = {};
  for (const p of PARTS) parts[p.key] = {box:toFile(boxes[p.key]), visibility:boxes[p.key].vis};
  try {
    await api("/api/save", {image:current, parts}); dirty = false;
    items = await api("/api/items"); renderList();
    const i = items.findIndex(x => x.image === current);
    const next = items.slice(i + 1).concat(items.slice(0, i)).find(x => x.state !== "v2");
    if (next) open(next.image); else document.getElementById("status").textContent = "すべて新ルールで確認済みです";
  } catch (e) { alert("保存できませんでした: " + e.message); }
}
document.getElementById("save").onclick = save;
document.getElementById("toggleHidden").onclick = () => { const b = boxes[selected]; b.vis = b.vis === "occludedEstimated" ? "visible" : "occludedEstimated"; dirty = true; renderSide(); draw(); };
document.getElementById("viewFace").onclick = () => fitView("face");
document.getElementById("viewAll").onclick = () => fitView("all");
window.addEventListener("resize", draw);
window.addEventListener("beforeunload", e => { if (dirty) { e.preventDefault(); e.returnValue = ""; } });
document.addEventListener("keydown", ev => {
  if (!data) return;
  if (ev.key >= "1" && ev.key <= "5") { selected = PARTS[+ev.key - 1].key; renderSide(); draw(); return; }
  if (ev.key === "Enter") { ev.preventDefault(); save(); return; }
  if (ev.key === "h" || ev.key === "H") { document.getElementById("toggleHidden").click(); return; }
  if (ev.key === "f" || ev.key === "F") { fitView("face"); return; }
  if (ev.key === "a" || ev.key === "A") { fitView("all"); return; }
  const step = ev.shiftKey ? 10 : 1; const b = boxes[selected];
  const moves = {ArrowLeft:[-step, 0], ArrowRight:[step, 0], ArrowUp:[0, -step], ArrowDown:[0, step]};
  if (moves[ev.key]) { ev.preventDefault(); b.x += moves[ev.key][0]; b.y += moves[ev.key][1]; clampBox(b); dirty = true; draw(); }
});
(async () => {
  items = await api("/api/items"); renderList();
  const first = items.find(x => x.state !== "v2") || items[0]; if (first) open(first.image);
})();
</script>
</body>
</html>
"""


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--dataset", type=pathlib.Path, default=DEFAULT_DATASET)
    parser.add_argument("--port", type=int, default=8140)
    parser.add_argument("--no-browser", action="store_true")
    args = parser.parse_args()

    dataset = Dataset(args.dataset.expanduser())
    server = ThreadingHTTPServer(("127.0.0.1", args.port), make_handler(dataset))
    url = f"http://127.0.0.1:{args.port}/"
    print(f"[labeler] {len(dataset.items)} images, writing to {dataset.manual_path}")
    print(f"[labeler] schema validation: {'on' if dataset.schema else 'OFF (dataset tools not found)'}")
    print(f"[labeler] open {url}   (Ctrl-C to stop)")
    if not args.no_browser:
        webbrowser.open(url)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    return 0


if __name__ == "__main__":
    sys.exit(main())
