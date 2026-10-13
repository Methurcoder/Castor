# Castor

**自分のイラストを、デスクトップで暮らす小さな相棒に。**

Castor は、画像からキャラクターを作り、呼吸・瞬き・視線・声で反応するデスクトップコンパニオンです。少しためらったり、目を逸らしたりする「不器用な生命感」を目指しています。macOS アプリを中心に開発している、研究・試作段階のプロジェクトです。

Castor は、[Pomegranate](https://github.com/atemoyacode-sudo/Pomegranate) の**許諾済みの後継プロジェクト**です。GitHub アカウント `Methurcoder` の新しい `Castor` リポジトリへ、Pomegranate由来とライセンスを残して新しい履歴で移行する予定です。現在はローカル準備段階で、公開リポジトリとリリース番号は未確定です。アプリ、Xcode プロジェクト、Swift Package、ペットの実行ファイルと新規保存先は `Castor` 名義へ統一しています。既存データの互換性を保つため、macOS の bundle ID `dev.pomegranate.prototype` と `Pomegranate.*` の設定キーを維持し、旧保存ファイルも読み込みます。

## 現在できること

macOS アプリでは、次の機能を使えます。

- 自分の画像を読み込み、**Arils** で自動リギング。正面1枚、または正面と横向きの2枚から動くキャラクターを作り、フローティングペットとして保存・呼び出せます。
- 呼吸、瞬き、視線、口パク、撫でる反応、小さな自発動作。カメラの顔位置や顔ランドマーク、マイクの音量を任意で反映できます。
- **LM Studio / Ollama によるローカル会話**と、macOS 標準音声または任意のローカル Neural TTS による読み上げ。
- **Codex / Claude Code への操作依頼**。コマンド、ファイル変更、追加権限にはアプリ内の承認カードを表示します。
- 読み込んだキャラクターの会話上の性格を編集。今回の後継版は自分の画像を使う構成で、従来の公式キャラクターと図形の Prototype は含みません。
- ペットの上で **Option（⌥）を押している間**、ペットを薄く表示して背後をクリック。
- AI による顔マーカーの位置提案。画像上で確認・修正し、明示的に承認してからリグを作ります。

リギングの品質は元画像によって変わります。自動推定が合わない場合は、顔マーカーを補正してください。従来の矩形ベースの手動リグも `Settings > General > Advanced > Manual rigging` から有効化できます。

## 対応環境と確認状況

| 環境 | 現在の範囲 | 確認の境界 |
| --- | --- | --- |
| macOS | SwiftUI アプリ、自動リギング、ペット、会話・音声、外部エージェント連携 | アプリのビルドとパッケージテストを確認済み。最新変更の GUI 表示、実モデルでの応答、権限付きの各機能は実機確認が必要です。 |
| Windows | `CastorDesktop` のペット再生プレビュー。Mac で作ったリグを読み込み、透過ウインドウで表示 | Win32 のウインドウ・入力・描画は実機確認待ちです。Windows でのリグ作成、会話、音声、カメラは未実装です。 |
| Linux | `CastorCore` の共有ロジック、`ArilsPortable` のモーション・変形・保存形式、ペットの CPU 描画部分 | 改名前の Linux 向けクロスビルド成功は引き継ぎ記録にあります。今回の改名後には未再確認で、デスクトップ UI は未実装です。 |

macOS アプリの Xcode プロジェクトは現在 **macOS 26.5** を deployment target にしています。Swift Package の macOS 14 指定とは別の要件です。`CastorCore` のビルドには Swift 6.2 以降が必要です。

ビルドや単体テストの成功は、すべての画像・実デバイス・長時間運転での品質を保証するものではありません。現在の変更点は [リリースノート下書き](docs/RELEASE_NOTES_DRAFT.md)にも記載しています。

## macOS で始める

リポジトリルートから Xcode プロジェクトを開きます。

```sh
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

## ローカル AI と操作の違い

**内蔵モード（On-device）は会話のみです。** LM Studio / Ollama のモデルには、ファイルを変更したり、コマンドを実行したり、アプリを操作したりする手段を渡しません。操作が必要そうな依頼には Codex / Claude Code への案内を表示し、会話は続けます。

モデルには操作できないことと、実行していないことを実行したと主張しないことを伝えますが、モデルが必ず従う保証はありません。モデル選択欄ではパラメータ数を表示し、API で取得できない場合は名前からの推定と明記します。約7B未満には精度への注意を表示します。サイズは選ぶ目安で、回答品質の保証ではありません。

通常の会話は loopback 接続のローカルサービスへ送ります。操作を任せる場合は外部エージェントを選びます。自動ルーティングでは日常会話をローカルに残し、ファイル・コマンド・アプリ・開発に関する依頼を選択した外部エージェントへ送ります。外部 CLI は、そのアカウントや設定に従ってメッセージや作業フォルダの文脈を OpenAI / Anthropic のサービスへ送る可能性があります。

### Codex

Codex CLI のインストールと認証を済ませ、操作を許す作業フォルダから起動します。

```sh
cd /path/to/your/workspace
codex app-server --listen ws://127.0.0.1:4500
```

アプリの `Settings > Brain`で同じ URL と作業フォルダを指定し、Codex を選びます。接続は localhost のみに制限しています。スレッドは `read-only` sandbox、`on-request` 承認、user reviewer を既定とし、操作前に承認カードを表示します。

CLI 更新時には、App Server の接続と承認の動作を再確認してください。

### Claude Code

Claude Code CLI のインストールと認証を済ませ、リポジトリルートからローカル Bridge を起動します。

```sh
python3 scripts/claude_code_bridge.py --listen http://127.0.0.1:4510
```

`Settings > Brain` で同じ Bridge URL と作業フォルダを指定し、Claude Code を選びます。Bridge はユーザーが起動した CLI を使い、loopback のみで待ち受けます。認証情報は CLI 側で管理し、Bridge は保存しません。

Bridge は `stream-json` と専用の MCP permission prompt を使用し、user / project / local の allow rule を継承しません。未解決のツール操作は承認カードへ戻し、拒否するとその操作を止めます。応答のキャンセル時には保留中の承認を解放して CLI の turn を終了します。

実モデルの応答には利用可能なアカウントが必要です。Antigravity は未接続です。

## Windows プレビュー

Windows 版は、Mac で作った Arils ペットを再生する独立 Swift Package です。Swift と Windows 向けビルド環境の導入手順、ペットのコピー元、操作方法は [CastorDesktop/README.md](CastorDesktop/README.md)を参照してください。

Windows のターミナルで、リポジトリルートから実行します。

```powershell
cd CastorDesktop
swift build -c release --product CastorPet
.build\release\CastorPet.exe C:\path\to\CastorPet.json
```

Arils で保存した `CastorPet.json` または単体の `.arils` アーカイブを渡します。引数を省略した場合は現在のフォルダの `CastorPet.json` を優先し、なければ旧 `PomegranatePet.json` を探します。旧保存ファイルを明示的に指定しても読み込めます。従来の手動リグには対応していません。ドラッグで移動、頭の上のポインタ操作で撫でる反応、Alt を押して背後をクリック、右クリックメニューで終了できます。これらの Win32 動作は実機確認待ちです。

## 任意機能とモデル

以下は必要なときだけ準備します。ローカル AI、TTS、画像処理のモデル重みはソースやアプリへ同梱しません。

### Neural TTS

```sh
scripts/bootstrap-neural-tts.sh
scripts/start-neural-tts.sh
```

Qwen3-TTS / Irodori-TTS / mlx-audio を別途導入するローカル読み上げです。使えない場合は macOS 標準の `AVSpeechSynthesizer` へ戻ります。

### LaMa Underpaint BETA

```sh
scripts/bootstrap-lama-inpainting.sh
scripts/start-lama-inpainting.sh
```

`Settings > General` で有効にして、画像からペットを作り直します。リグ作成時だけ `127.0.0.1:8123` へ画像を送り、首振りで見える頭の背後を補修します。既定はオフで、サービスが使えない場合は非 ML の補修へ戻ります。

### 顔推定・切り抜き用 Core ML モデル

顔ランドマークとアニメキャラクターの切り抜きモデルを手元で書き出して使えます。モデルが無い場合も従来の推定器で動作します。導入・export コマンドは [Arils/README.md](Arils/README.md)を参照してください。

### ペットの退避と広い首振り（ベータ）

- **Pet Evasion**：近づくポインタを避け、元の場所へ戻ります。既定はオフです。
- **Button-aware dodge**：背後の他アプリのボタンなどを検出して避けます。既定はオフで、下記 helper とアクセシビリティ権限が必要です。権限付きの実機動作は確認待ちです。
- **Wider head movement**：`Settings > General > Advanced` で首振りの幅を広げます。Windows プレビューでは起動引数 `--wide-head` を使います。大きく振ると頭の背後の下塗りや継ぎ目が見える場合があります。

```sh
scripts/bootstrap-pointer-target.sh
scripts/start-pointer-target.sh
```

Button-aware dodge の helper は `127.0.0.1:8126` で待ち受けます。macOS の `システム設定 > プライバシーとセキュリティ > アクセシビリティ` で helper の Python を許可します。返す情報はポインタ下のコントロールの種類で、タイトルや本文は返しません。

### Setting with AI

`Rigging` の隣の `Setting with AI` で画像構成とレビュアーを選び、既存のリグ編集画面へ進みます。`Suggest with AI` が提案する頭・目・口の位置はプレビューです。確認・修正し、`Approve AI alignment and build` を押すまで作成しません。外部レビュアーへの画像送信には確認が必要です。詳細は [Arils AI operations](docs/ARILS_AI_OPERATIONS.md)を参照してください。

## Arils とリポジトリの構成

Castor は利用者向けのコンパニオンアプリ、**Arils は独立して再利用できるキャラクターエンジン**です。Arils は自動リギング、モーション、Metal 描画を担当します。2枚画像の Quality は正面と横の視点を組み合わせ、小角度では深度を利用した 2.5D の動きを加えます。完全な3Dモデルの復元ではありません。

| 場所 | 内容 |
| --- | --- |
| `Castor/` | macOS アプリ、Xcode プロジェクト、アプリのテスト |
| `CastorCore/` | 状態、ローカル会話、ルーティング、モーション変換などの共有ロジック |
| [Arils/](Arils/README.md) | リギング・モーション・描画。`ArilsPortable` は Windows / Linux での保存リグの再生に使う部分 |
| [CastorDesktop/](CastorDesktop/README.md) | Windows のペットプレビューと、ウインドウなしで使える CPU 描画 |
| [Arils-ex/](Arils-ex/README.md) | 独立実験：3方向の画像から関節付きキャラクターを作成 |
| [ScreenshotAnswer/](ScreenshotAnswer/README.md) | 独立実験：macOS の画面・音声の質問を LM Studio へ送るメニューバーアプリ |
| `scripts/` / `docs/` | 任意サービスの helper、運用資料、ロードマップ |

ScreenshotAnswer はコンパニオン本体へ未接続です。また Arils API にあるモーションの性格プリセット、会話の態度、ためらい入力、TTS の事前解析タイムラインは、アプリへの接続がまだ完了していません。アプリは現在 `standard` のモーション設定を使います。

## 開発時の確認

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

## 公開・移行の準備

別アカウントの新しいリポジトリへ後継として公開するための判断事項は [Castor 移行準備](docs/CASTOR_MIGRATION.md)、公開時の手順は [公開ガイド](docs/PUBLISHING.md)を参照してください。公開先が確定するまでは、新しいリポジトリの URL や clone コマンドを案内しません。

## ライセンス

本プロジェクトのソースコードは [MIT License](LICENSE) で公開します。Pomegranate から引き継いだ著作権表示とライセンスを保持します。ユーザーが読み込む画像や、別途取得するモデルの利用条件は、それぞれの権利者・配布元に従います。

TTS、LaMa、顔推定・切り抜きモデル、Windows プレビューの `stb_image` などの出典とライセンスは [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)を参照してください。
