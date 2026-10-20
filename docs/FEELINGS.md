# セリフの気持ち判定（任意のモデル）

キャラクターが話す1文ごとに、9種類の気持ちの割合を出す小さなモデルです。入っていれば、
声の演技指示（ニューラル音声）と画面の感情表示がその文の気持ちになります。入っていなければ、
これまでどおり会話AIの返す `tts.emotion` を使います。

気持ち: 普通 neutral / 喜び happy / 悲しみ sad / 怒り angry / 驚き surprised / 考え中 thoughtful /
照れ embarrassed / 悔しさ frustrated / 嫉妬・やきもち jealous

## 中身

| ファイル | 内容 |
|---|---|
| `feelings.json` | 気持ちの並び順・最大トークン数 |
| `tokenizer.json` | Ruri v3 の語彙（Unigram）。Swift の `FeelingTokenizer` が読む |
| `CastorFeelings.mlpackage` | Mac（Core ML、fp16、約134MB）。入力 `input_ids`・`attention_mask`（int32、[1, n]）。初回に `.mlmodelc` へ変換して隣に保存 |
| `CastorFeelings.onnx` | Windows（ONNX Runtime、約267MB）。入力 `input_ids`（float32、[1, n]） |

出力はどちらも `probabilities`（[1, 9]、`feelings.json` の順）。入力文は `キャラ: {返事}` か
`ユーザー: {発言}\nキャラ: {返事}`、`<s> … </s>` で最大128トークン。

## 置き場所

- Mac: `~/Library/Containers/dev.pomegranate.prototype/Data/Library/Application Support/Castor/Models/Feelings/`
  （サンドボックス内の Application Support）
- Windows: `%LOCALAPPDATA%\Castor\Models\Feelings\`（ONNX Runtime は既存の顔モデルと同じ `onnxruntime.dll`）
- 開発時はどちらも `CASTOR_FEELINGS_DIR` で指定できる（Mac アプリはサンドボックス外を読めない）

## コード

- `CastorCore/Sources/CastorCore/Feelings/` … `FeelingTokenizer`（Python の tokenizers と1,026文で一致）、
  `FeelingClassifier`、`FeelingModelFiles`、気持ちごとの英語の演技指示
- Mac: `Castor/Castor/Pet/PetFeelingReader.swift`（Core ML）。`PetSpeechOutput` が1文ずつ判定し、
  ニューラル音声・先読み・システム音声の高さに使う
- Windows: `CastorDesktop/Sources/PetRuntime/DesktopFeelings.swift`（ONNX）。返事全体を判定し、
  設定の声の指示の後ろに演技指示を足す（`VoiceFlow.speak`）

## 精度（ゲームのセリフ・人の確認）

- 作り手が気持ちを決めて書いた188文: 77〜80%（教師役の9Bは87%）
- 人が答えた48文: 62%（教師役の9Bは65%。9種類の気持ちでは人同士でも6〜7割程度しか一致しない）

## 作り方とライセンス

- 生徒: Ruri v3 70m（cl-nagoya、Apache-2.0）。配布するときは THIRD_PARTY_NOTICES に Ruri v3 と
  ModernBERT-Ja の表記を加える
- 教師: Qwen3.5-9B（Apache-2.0）が気持ちの割合を付けた。文は Qwen3.5-9B と Qwen3.8-27B（Apache-2.0）が
  書いたもので、27B が自然さを採点して4以上だけ使った
- Claude が書いた文（気持ち多数決ゲームのセリフ）は学習に使っていない。精度の確認だけに使った
- 学習・書き出しのスクリプトは `~/開発/Castor-3D-lab/emotion/`（`build_corpus.py`、`kaggle/`、
  `train_student.py`、`export_castor.py`）。書き出しは PyTorch と全文で答えが一致することを確かめてから使う
