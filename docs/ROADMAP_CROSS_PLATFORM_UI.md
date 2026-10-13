# クロスプラットフォーム化と UI 刷新ロードマップ

2026-10-02 時点の計画。基準は `Pomegranate-release-v1.1`(1e7223f)。
Castor を Windows / Linux でも動かし、同時に UI を「キャラが主役の没入型」へ作り直すための計画書。

## 実装状況

2026-10-13 にアプリと共通 Package の名称を Castor / CastorCore / CastorDesktop に揃えた。以下の2026-10-02の記録中にあるテスト件数は当時のもの。Windows は Win32 + CPU 描画のペット再生プレビューがあり、WinUI / wgpu や Linux UI は今後の計画である。Linux クロスビルド成功は改名前の引き継ぎ記録で、今回の改名後には未再確認。

- A1〜A3 完了(2026-10-02)。
- C1 前半完了: `CastorCore` パッケージを新設し、Hesitate Core、Cherry Connection、Agent、`TrilobiteInputSnapshot`、`SpeechInputSupport`、Pet Evasion の判定部、文分割と発話エネルギー、`VoiceLatencyTracker` を移した。`os.Logger` は `CastorLog` に置き換えた。テストは 97 件をパッケージへ移し(`swift test --package-path CastorCore`)、アプリ側には 37 件が残る。
- CI(`castor-core-check.yml`)を追加した。macOS / Linux / Windows で `swift test` を回すが、まだ push しておらず実行していない。
- C1 の残り: `NeuralSpeechClient` と `PetVoiceProfile` / `PetVoicePreset`(NaturalLanguage の切り離しが必要)、`PetSpeechLanguageContext`。

## 決定事項

| 項目 | 決定 |
| --- | --- |
| 技術方針 | Swift のコアを全 OS で共有し、UI だけを OS ごとに書く |
| 進め方 | macOS の UI を先に刷新し、その画面仕様に Windows(WinUI)を合わせる。Linux は同じ Swift コアを使い、UI は GTK4 で Windows の仕様に追従する |
| 描画 | Arils の描画を Renderer protocol の裏に隠す。Windows / Linux は wgpu-native(WGSL 1本で D3D12 / Vulkan)を使い、macOS は当面 Metal のまま |
| 削除 | 公式キャラ4体、Prototype(図形キャラ) |
| 格納 | 手動 Image Rigging。Arils の精度が安定するまで、Settings › General › Advanced の奥に残す |
| 残す | Arils(2D / Quality / 2.5D)、Arils-ex、AI Setup、LM Studio、LaMa、ScreenshotAnswer、Codex / Claude Code 連携 |
| 改良 | Pet Evasion(要件は別途詰める) |
| 機能方針 | 削除対象以外の機能は、なるべく全 OS で同等に保つ |

キャラクターの作成経路は **Arils だけ**になる。公式キャラを削除する理由は、精度が公式として出せる水準にないため。

## フェーズ A — 整理(macOS)

公式キャラと Prototype を削除し、手動リグを既定の導線から外す。移植対象のコード量と、アセット約 36MB が減る。

### A1. 公式キャラ削除

- `Official Characters/` の6ファイルと、`Assets.xcassets/Official*.imageset`(基準4 + baked 132)を削除する。
- `ContentView` の `ExperienceMode.official` を削除する。
- `PetCharacterStore`: `officialCharacterID` / `officialExpression` を削除する。旧保存データで公式 ID だけを持つ pet は「未登録」として扱い、デコード失敗にはしない。
- `PetEvasionStyleResolver`: 公式 ID の固定対応を削除し、読み込みキャラの style だけを使う。
- `PetVoiceProfile` / `PetVoiceSelectionStore` / `PetPersonalityStore` / `VoiceSelectionView` / `PetVoiceConversation`: `officialCharacterID` 引数を削除し、単一プロファイルにする。UserDefaults の保存キーは既存の `"imported"` のままにして、ユーザー設定を引き継ぐ。
- テスト: 公式カタログと sprite timeline のテストを削除し、旧データ移行のテストを追加する。

### A2. Prototype 削除

- `Awkward Engine/CharacterRenderer.swift` と `ExperienceMode.prototype` を削除する。
- `CherryConnection` / `MotionParameters` / `MotionContext` は Arils pet が使っているので残す。

### A3. 手動 Image Rigging を詳細へ格納

手動リグは、Arils が失敗した画像の逃げ道になっているため、精度が安定するまでは削除しない(2026-10-02 決定)。

- `ManualRiggingSettingsStore`(既定オフ)と Settings › General › Advanced のトグルを追加する。
- オフのとき: 画像を読み込むと Arils を自動で開始する。パーツ編集、Rig JSON、Apply Rig は表示しない。Save Pet には Arils のリグが必要。失敗時は Adjust Face と手動リグの有効化を案内する。
- オンのとき: 従来どおり手動リグを使え、Arils のリグがなくても pet を保存できる。
- 手動リグだけで保存済みの pet は、設定にかかわらず今までどおり表示する。
- 将来の削除候補: `RigDocument` / `RigPart` / `LayerExtractor` / `PartSelectionOverlay` / `RiggedCharacterRenderer`。移植対象からは外す(Windows / Linux には持っていかない)。

完了条件: macOS でビルドとテストが通り、Arils キャラの作成、pet の呼び出し、会話が今まで通り動く。

## フェーズ B — UI 刷新(macOS)

### 方向性

- メインウインドウは**キャラのステージ**にする。上部のモード切替は廃止する。
- キャラ未登録のときは、画像をドロップすると作成フローに入る。登録済みのときはキャラだけが映る。
- 操作(話しかける、マイク、pet として呼ぶ、設定)は hover / フォーカスしたときだけ現れる。
- デバッグパネルは通常 UI から外し、ショートカットまたは隠し設定から開く。
- 設定は最小限にする。よく使うものだけを前面に出し、Agent / LaMa / Neural TTS などは「詳細」に畳む。

### タスク

- B1. 画面仕様書 `docs/UI_SPEC.md` を作る。画面、状態遷移、コンポーネント、文言を OS 非依存で記述し、WinUI / GTK 実装の基準にする。
- B2. ステージ画面と空状態を作る(`ContentView` の置き換え)。
- B3. キャラ作成フローを sheet / overlay で一本化する(`ImageRiggingView` の Arils 部分と `ArilsAISetupView` を統合し、手動リグは詳細側に分離)。
- B4. Settings を再構成する。
- B5. Pet UI(`PetFloatingView` / `PetResponseReader`)を新しい見た目に揃える。
- B6. Pet Evasion の改良(要件定義から)。
- B7. Visual Language の刷新(配色、質感、タイポグラフィ)。`glassEffect` のような macOS 専用の表現は、他 OS での代替が決まっているものに限る。

## フェーズ C — コア分離(SwiftPM)

フェーズ B と並行できる。macOS アプリの挙動は変えない。

### C1. `CastorCore` パッケージ(リポジトリ直下に新設)

移す対象:

- Hesitate Core: `HesitateCore`、`MotionState`、`Ollama*`、`LMStudioClient`、`OllamaStreamingSentenceExtractor`
- Agent: `CastorAgentSettings`、`CodexAppServerSession`、`ClaudeCodeBridgeSession`
- Cherry Connection: `CherryConnection`、`MotionParameters`、`MotionContext`
- 純粋ロジック: `SpeechInputSupport`、文分割(`PetSpeechSegmenter`)、`VoiceLatencyReport`、Pet Evasion の判定部、`NeuralSpeechClient`

置き換え:

- `os.Logger` → 薄いログ抽象 `CastorLog`
- `UserDefaults` 直参照 → `SettingsStore` protocol
- `NaturalLanguage`(文分割など)→ protocol に切り出し、他 OS は単純な実装にする
- Linux の `URLSessionWebSocketTask`(swift-corelibs-foundation)が Codex 連携で実用になるかを検証する。ダメなら WebSocket 実装を差し替える

### C2. Arils の移植性

- `CGImage` / `CGContext` / ImageIO → 自前のピクセルバッファと画像 codec protocol。`Bitmap.swift` を起点にする。`CGRect` / `CGPoint` は corelibs Foundation にあるので、そのままでよい
- `simd` → 標準ライブラリの `SIMD` 型と小さな数学ヘルパー
- `Accelerate`(`LipSyncAnalyzer`)→ 素の実装。mac では Accelerate を使ってもよい
- `Vision`(`SubjectMask`、`VisionFaceEstimator`、`JointProposalEngine`)→ `FaceDetector` / `SubjectSegmenter` protocol。他 OS は ONNX Runtime または MediaPipe
- `Metal`(`ArilsRender`)→ `AvatarRenderer` protocol。`ShaderSource` を WGSL へ移植し、wgpu backend を作る

### C3. OS 依存部の protocol 化(アプリ側)

`FaceTracker`、`AudioCapture`、`SpeechRecognizer`、`SpeechSynthesizer`、`PetWindowHost`、`GlobalPointerMonitor`

### C4. CI

GitHub Actions で macOS / ubuntu / windows の matrix を組み、`CastorCore` と Arils の非 GPU target で `swift test` を回す。

完了条件: `CastorCore` と Arils のコア部が、3 OS で `swift build` と `swift test` を通る。

## フェーズ D — Windows

- D0. **PoC を最優先にする。** 透過・最前面ウインドウに、wgpu で Arils キャラを1体描画し、WinUI のコントロールを1つ重ねる。Swift から WinUI をどう呼ぶか(swift-winrt 系のバインディング、または C ABI を挟んで C# で UI を書く)をここで決める。
- D1. カメラ: Media Foundation。顔: ONNX Runtime / MediaPipe。
- D2. 音声認識: whisper.cpp(3 OS 共通の実装候補)。読み上げ: `Windows.Media.SpeechSynthesis` をフォールバックにする。
- D3. UI_SPEC に沿った画面実装。pet ウインドウ、トレイ、全 Space 相当の表示。
- D4. 配布: MSIX。

## フェーズ E — Linux

- UI は GTK4 で UI_SPEC に追従する(Swift から GTK を呼ぶ)。
- カメラ: PipeWire portal / V4L2。音声: PipeWire / PulseAudio。読み上げ: speech-dispatcher をフォールバックにする。
- X11 では全機能を対象にする。Wayland では次の制約がある。
  - 全画面のポインタ位置が取れない → Pet Evasion と画面端ダブルクリックは制限付き。代替はトレイとホットキー
  - 常時最前面の透過ウインドウ → wlroots / KDE では layer-shell、GNOME は制限付き
- 配布: Flatpak / AppImage。

## 既知のリスク

- **Neural TTS は MLX(Apple Silicon 専用)。** Windows / Linux では同じ HTTP API(`/v1/audio/speech`)を保ったまま、PyTorch など別 backend のサーバーが必要になる。
- **Swift から WinUI / GTK を呼ぶ方法の成熟度。** D0 の PoC で判断し、ダメなら UI 層だけ C# / C の薄い殻にする。
- **顔検出・被写体抽出の品質差。** Vision から ONNX / MediaPipe に代えると、Arils の自動リグ精度が変わる。回帰テスト(`FaceEstimatorRegressionTests` など)で比較する。
- **ScreenshotAnswer は macOS 専用のまま**とし、移植対象外にする。

## 進める順番

1. フェーズ A(A1 → A2 → A3)
2. フェーズ B とフェーズ C を並行
3. D0 PoC → フェーズ D
4. フェーズ E

## 未決事項

- Pet Evasion で何を改良するか
- 新しい見た目の具体像(参考アプリや雰囲気)
- Windows UI のバインディング方式(D0 で決める)
