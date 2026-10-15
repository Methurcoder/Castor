<p align="center"><img src="docs/images/castor-banner.svg" alt="Castor：自分のイラストから、顔マーカーを確認してデスクトップの相棒へ" width="100%"></p>

# Castor

**自分のイラストを、デスクトップで暮らす小さな相棒に。**

**これは正式リリース版です。** — `v1.0.0`

呼吸、瞬き、視線、声。少しためらったり目を逸らしたりする、そんな相棒を自分の画像から作れます。

[ダウンロード](https://github.com/Methurcoder/Castor/releases/tag/v1.0.0) · [導入ガイド](docs/GUI_SETUP.md) · [変更点・確認記録](docs/RELEASE_v1.0.0.md) · [機能差と今後の計画](docs/CROSS_PLATFORM_PARITY.md)

Castor は [Pomegranate](https://github.com/atemoyacode-sudo/Pomegranate) の**許諾済みの後継プロジェクト**です。Pomegranate由来の著作権表示とMITライセンスを保持し、Methurcoderが開発を続けています。

## ダウンロード・導入

| お使いの環境 | ダウンロード | 展開後に開くもの |
| --- | --- | --- |
| Mac / Apple Silicon | [Mac用の導入GUI](https://github.com/Methurcoder/Castor/releases/download/v1.0.0/CastorSetup-v1.0.0-macos_arm64.zip) | `CastorSetup.app` |
| Windows / x64 | [Windows用の導入GUI](https://github.com/Methurcoder/Castor/releases/download/v1.0.0/CastorSetup-v1.0.0-windows_x86_64.zip) | `CastorSetup.exe` |

**`Castor-Downloader.zip`は`.command` / `.cmd`を使うスクリプト版です。GUIで導入する場合は、上のOS別`CastorSetup-…zip`を選んでください。**

Macは**macOS 26.5以上・Apple Silicon**、Windowsは**x64**が対象です。今回の配布にはIntel Mac版を含めません。

導入GUIで「取得・更新」を選び、取得後に「起動」を押してください。アプリ本体と必要なランタイムを配布するため、基本アプリの導入にXcode・Swift・Visual Studio・Pythonの手動導入やコマンド入力は必要ありません。会話には任意のLM Studio / Ollama、外部操作には各エージェントの導入・本人認証が別途必要です。

### 最初の起動

- **Mac**：現在は開発用ad-hoc署名で、Developer ID署名・公証は未実施です。初回に止められたら、**システム設定 → プライバシーとセキュリティ → このまま開く**で本人が許可します。導入GUI・本体・Qwen補助アプリそれぞれで確認が必要です。
- **Windows**：コード署名は未整備です。SmartScreenに止められた場合の手順は[導入ガイド](docs/GUI_SETUP.md)を確認してください。
- SHA-256は取得ファイルの破損を検出する照合です。配布者の真正性は保証しません。[保護と限界](docs/DOWNLOADER.md#アプリ取得時の保護と限界)

## はじめの3ステップ

![導入GUIで取得 → 自分の画像と顔マーカーから作成 → 動き・会話・GIFを楽しむ](docs/images/castor-quick-start.svg)

1. **イラストを読み込む**：リギングで正面1枚、または正面と横向きの2枚を選びます。
2. **顔の位置を確認する**：頭・両目・口のマーカーを直して、ペットを作成・保存します。推定の品質は元画像によって変わります。
3. **デスクトップへ表示する**：声や会話上の性格を選び、呼吸・瞬き・視線・撫でる反応を楽しめます。

図は利用の流れを表す概念図です。Mac / Windowsの実装範囲と確認状況は下記をご覧ください。

## できること・確認状況

| 機能 | Mac | Windows |
| --- | --- | --- |
| 画像から作成・顔マーカー補正・保存・読み込み | Arilsで1枚 / 2枚Qualityを作成 | Mac風の作成画面（日本語・英語）でStandardを作成。Macと同じ顔推定・切り抜きモデル（ONNX）を同梱。Qualityは従来の画面。実機確認待ち |
| 呼吸・瞬き・視線・口パク・撫でる反応 | 実装済み | 共通モーション・CPU描画を実装。実機GUI確認待ち |
| LM Studio / Ollamaとの会話・性格編集 | 実装済み | 実装済み。実機の会話確認待ち |
| OS標準音声・任意Qwen 3 TTS | Qwen GUI起動・モデル準備・アプリ内試聴・停止を実機確認 | CPU用helperを梱包。実モデル生成・音声出力の実機確認待ち |
| Codex / Claude Code・操作ごとの承認 | 実装済み。外部送信は本人の確認後 | 共有接続・承認UIを実装。実アカウント接続の確認待ち |
| GIF作成・保存・Xへの案内 | 実装済み | 実装済み。実機確認待ち |
| カメラ・追加ML・全Advanced設定 | 任意の権限 / helperを使用 | 未対応部分あり。今後はML移植と品質改善を優先 |

**v1.0.0を通常の正式Releaseとして配布します。** Windowsの新しい作成画面・ML・導入ウィザードを含む最新修正は、管理者の希望により追加テストを省いて公開しています。全機能が両OSで同じ品質で動作すると確認した版ではありません。Macの既存候補では画像作成・保存後の読み込み・GIF・Qwen試聴を確認しましたが、今回の最新修正全体の再検証、新規Qwenモデル取得、開発環境のない端末での初回導入、長時間動作は未確認です。

### 今後の対応予定

- **Linux**：デスクトップアプリとしてのネイティブ対応。現在は共有ロジックとCPU描画のみが開発対象で、今回の配布には含めません。
- **Windows（WinUI 3）**：作成画面をWinUI 3のネイティブUIへ移行します。現在はWebView2でMac版に近い画面を表示しています。
- **共通エンジンの拡大**：OSごとの実装を減らし、Mac / Windows / Linuxで共有する処理を増やしていきます。

## Qwen 3 TTSを使う

1. Macでは **設定 → 音声 → ロード**を押します。WindowsではVoiceから補助アプリの導入GUIを開き、補助アプリの **ロード / Load**を押します。
2. 設定を開くだけではモデルを取得・ロードしません。初回のモデル取得には時間と空き容量が必要です。
3. 声の選択画面で音声サンプルを再生します。

起動だけではモデルを取得しません。準備できるまではOS標準音声を使えます。MacはMLXのQwen 0.6B CustomVoice、WindowsはローカルPyTorchのCustomVoiceを使用します。音声をこの端末で生成し、マイクの録音や声の複製は行いません。詳細な話し方の指定には制限があります。

Macでは本体の「停止」または補助アプリの画面で停止できます。本体を終了すると、本体が起動した補助アプリも終了します。既に別途起動されていたサービスは、その起動元で停止してください。

## ペットのGIFをXで共有

**「GIFを作ってXで共有」 → プレビュー → 保存 → Xの投稿画面**と進みます。

**GIFは自動添付されません。保存したGIFを、Xで手動で添付して投稿してください。**

ペットと選んだ背景だけをローカルで描画します。画面・カメラ・会話をGIFへ取り込まず、Xへの自動アップロード・自動投稿・認証情報の保存も行いません。

## ローカルAIと操作依頼

LM Studio / Ollamaによる通常の会話は、localhostのサービスへ送ります。ファイル・コマンド・アプリの操作を頼む場合はCodex / Claude Codeを選び、操作ごとの承認カードで承認・拒否・キャンセルします。

外部エージェントは、そのアカウント・設定に従ってメッセージや作業フォルダの文脈を外部サービスへ送る可能性があります。AIの顔マーカー提案も、画像を確認し、明示的に承認してから採用します。

- [AIによる顔マーカーの確認](docs/ARILS_AI_OPERATIONS.md)
- [GUI導入・更新・修復・削除](docs/GUI_SETUP.md)
- [任意の追加helperと配布の保護](docs/DOWNLOADER.md)

## 更新・修復とデータ

導入GUIから更新・修復できます。既存アプリを直接上書きせず、新しい版を取得して切り替えます。取得失敗・取消・破損の場合は既存アプリとデータを保持します。

現在版と1つ前の管理済み版を残し、それ以前の指紋が一致する版だけをごみ箱へ整理します。変更されたフォルダ、個人ファイルを追加したフォルダ、指紋のない旧版は自動整理しません。

Pomegranate由来の保存ファイルを読み込めるよう、旧bundle ID・設定キー・旧保存先の読み込み互換性を維持しています。旧公式キャラクターは同梱しません。

## 開発者向け

<details>
<summary>ソースからのビルド・テスト</summary>

### macOSでビルドする

公開リポジトリを取得し、Xcode プロジェクトを開きます。

```sh
git clone https://github.com/Methurcoder/Castor.git
cd Castor
open Castor/Castor.xcodeproj
```

Xcode で `Castor` scheme と Mac の実行先を選び、必要に応じて自分の署名設定を指定して Run してください。ターミナルからビルドする場合は、次のコマンドを使います。

```sh
xcodebuild -project Castor/Castor.xcodeproj \
  -scheme Castor \
  -destination 'platform=macOS' build
```

1. アプリの `Rigging` から自分の画像を読み込みます。
2. 頭・両目・口の位置を確認し、必要なら補正してリグを作ります。
3. `Save Pet` で保存し、デスクトップへ表示します。既存の Pomegranate のペットは読み込み用 fallback で引き継ぎます。
4. 会話を使う場合は LM Studio または Ollama を自分で起動し、`Settings` で接続先とモデルを選びます。
5. カメラ、マイク、音声認識を使う場合は、macOS の権限確認に従って許可します。

### テスト

macOS アプリのテスト（UI テストを除く）:

```sh
xcodebuild test \
  -project Castor/Castor.xcodeproj \
  -scheme Castor \
  -destination 'platform=macOS' \
  -skip-testing:CastorUITests
```

macOS での各 Swift Package のテスト:

```sh
swift test --package-path CastorCore
swift test --package-path Arils
swift test --package-path CastorDesktop
```

保存済みペットをウインドウなしで描画するには:

```sh
swift run --package-path CastorDesktop -c release \
  pet-snapshot /path/to/CastorPet.json /path/to/frame 260 340
```

`frame-0.ppm` などの画像を書き出します。カメラ・マイク・アクセシビリティ・署名・実モデルとの接続は、パッケージのテストとは別に確認してください。


</details>

| フォルダ | 内容 |
| --- | --- |
| `Castor/` | macOSアプリ・Xcodeプロジェクト |
| `CastorCore/` | 会話・状態・ルーティング・音声の共有ロジック |
| [Arils/](Arils/README.md) | 画像リギング・モーション・描画エンジン |
| [CastorDesktop/](CastorDesktop/README.md) | Windowsアプリ・CPU描画・GUI Setup |
| [Arils-ex/](Arils-ex/README.md) / [ScreenshotAnswer/](ScreenshotAnswer/README.md) | 独立した実験パッケージ |

Mac配布には顔・ランドマーク・切り抜きに使う4つのCore MLモデルを同梱します。LLM / Neural TTS / LaMaの追加モデル重みは別途取得します。Arils APIの性格プリセット・会話態度・TTS事前解析の一部は、アプリへの接続を継続中です。

## ライセンス

ソースコードは [MIT License](LICENSE)。Pomegranateから引き継いだ著作権表示とライセンスを保持しています。画像や追加モデルは、それぞれの権利者・配布元の条件に従います。

各ライブラリ・モデルの出典と表記は [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)、配布物内のライセンス一覧をご覧ください。
