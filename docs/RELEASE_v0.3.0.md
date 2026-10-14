# Castor v0.3.0

**これは正式リリース版です。**

宣伝前の実行レビュー用として、配布を先行します。Windows版は公開プレビューです。
Castorは[Pomegranate](https://github.com/atemoyacode-sudo/Pomegranate)の許諾済み後継です。

## ダウンロード

- Mac: **CastorSetup-v0.3.0-macos_arm64.zip** → 展開してCastorSetup.appを開く。
- Windows: **CastorSetup-v0.3.0-windows_x86_64.zip** → 展開してCastorSetup.exeを開く。
- GUIの「取得・更新」から本体を取得し、「起動」で開きます。
- MacはmacOS 26.5以上・Apple Silicon、Windowsはx64向け。Intel Mac/Linuxのアプリは今回含みません。

基本アプリと必要なruntimeをビルド済みで配布します。利用者によるSwift/Xcode/Visual Studio/Pythonの手動導入やコマンド入力は不要です。
会話用LM Studio/Ollama、外部エージェントの導入・本人認証は任意の別途準備です。

## 変更点

- Qwen 3 TTSのGUI起動・停止・明示的なモデル準備・取消。モデルweightは同梱しません。
- Mac本体へ顔・ランドマーク・切り抜き用の4つのCore MLモデルを同梱。配布時の欠落を拒否します。
- 日英の導入GUI、対象別の削除確認、旧版保持、修復・取消・破損時の既存データ保護。
- Mac/Windowsの共有リギング・Quality再生・会話・承認・GIFの実装を追加。
- GIFは保存してXを開く方式です。**GIFは手動で添付し、本人が投稿します。**
- 図入りREADMEとOS別導入案内。

## 確認したこと

- Mac Voice画面から起動→既存cacheからモデル準備→日本語試聴→停止→再起動を確認。
  27文字/3区間すべてをQwenで生成し、アプリ内再生完了。標準音声fallbackなし。
- 本体終了時に所有するhelper/runtime/子processが終了し、制御用recordを整理することを確認。
- Coreローカル135件、Python speech9件、配布検査20件（5件OS条件skip）成功。
- Windows/Mac Desktop CI、Windows app/Setup/helper梱包、開発用PATHを除いた依存読込成功。
- helper license inventory: Mac46件、Windows95件、本文の欠落なし。これは包括的な権利監査ではありません。
- ZIPの容量/SHA-256/CRC検査成功。Mac候補内の4モデルのCPU読込成功。

## 署名と最初の起動

**Macはad-hoc署名でDeveloper ID署名・公証なし。Windowsのコード署名も未整備です。**

- Macで初回に止められたら「システム設定 → プライバシーとセキュリティ → このまま開く」を本人が選びます。
  導入GUI、本体、Qwen補助アプリそれぞれが対象です。
- WindowsでSmartScreenが出た場合は[導入ガイド](https://github.com/Methurcoder/Castor/blob/main/docs/GUI_SETUP.md)をご覧ください。
- OSの保護を自動で解除しません。同じRelease内のSHA-256照合は破損検出であり、配布者の真正性の保証ではありません。

## 残っている確認・機能差

- Windows実機での初回導入、描画品質、実モデル生成、音声出力、カメラ・マイク・権限付き機能。
- Macでの新規Qwenモデル取得、開発環境のない端末での初回導入、実際のOS警告。
- 全画像/長文/多言語/長時間動作の品質。
- Windowsの追加ML・カメラ・全Advancedと、Macとの全機能/品質共通化。

保存データと旧Pomegranateの設定/保存先の読み込み互換性を維持します。旧公式キャラクターは同梱しません。
詳しい[導入ガイド](https://github.com/Methurcoder/Castor/blob/main/docs/GUI_SETUP.md)と[機能差の計画](https://github.com/Methurcoder/Castor/blob/main/docs/CROSS_PLATFORM_PARITY.md)をご覧ください。
