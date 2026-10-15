# Castor v1.0.0

これは正式リリース版です。Mac Apple Silicon / Windows x64向けの通常Releaseです。

## 変更点

- Qwen 3 TTSの案内バナーと明示的なロード。設定を開くだけではモデルを取得・ロードしません。
- WindowsへMacと同じ顔・ランドマーク・切り抜きモデルのONNX版とONNX Runtimeを同梱。
- Windowsの新しい作成画面（WebView2、日本語・英語）と導入ウィザード。
- アプリアイコン、Macのドラッグ導入用DMG、GUI Setupの案内を整備。
- Setupの取消メッセージを日英で表示。
- 透明ペットのOS影、GIF共有画面の高さ、Qwen準備済み表示を修正。
- 音声認識の確定結果待ち・マイク解放待ち、定型エラー翻訳、許可表示、診断コードを追加（[修正記録](https://github.com/Methurcoder/Castor/blob/main/docs/BUGFIX_REVIEW_2026-10-15.md)）。

## 導入

- Mac: `Castor-v1.0.0-macos_arm64.dmg`を開いてCastorをApplicationsへドラッグするか、`CastorSetup-v1.0.0-macos_arm64.zip`内のCastorSetup.appを使用します。
- Windows: `CastorSetup-v1.0.0-windows_x86_64.zip`を展開し、DLLやSetupUIを同じフォルダに置いたままCastorSetup.exeを開きます。
- `Castor-Downloader.zip`は.command/.cmdの旧スクリプト版です。通常はOS別のGUIを選んでください。
- Windowsの作成・導入画面はWebView2を利用します。WebView2 Runtimeがない場合はMicrosoft公式ランタイムが必要です。
- Qwen音声は任意。モデルは同梱せず、ロード操作後に取得します。

## 確認範囲と制約

管理者の指示により、新しいWindows UI/ML全体のテストは再実行していません。その後依頼された不具合修正には、録音・モデル取得を伴わない限定ロジック12件とビルド確認を行っています。ビルドと配布に必要な梱包条件を確認して配布します。
先行するMac候補では画像から作成・マーカー補正・保存後の再読込・GIF・ローカル会話・Qwen試聴/停止を確認しました。これは新しいWindows作成画面や今回の共通ML変更全体の実機検証を意味しません。
Windowsの新ML/新UI・権限付き操作・実音声、新規端末での導入、Qwenモデルの新規取得、長時間動作は未確認です。MacとWindowsの機能・品質の完全一致は達成していません。

Macはad-hoc署名のみでDeveloper ID署名・公証は未実施です。初回に止められたら、本人が「システム設定 → プライバシーとセキュリティ → このまま開く」で許可してください。補助アプリも個別に確認が必要です。Windowsコード署名も未整備です。OSの保護設定は無効にしません。
SHA-256は破損検出用です。同じReleaseのmanifestとの照合だけでは配布者の真正性を保証できません。

Pomegranate (https://github.com/atemoyacode-sudo/Pomegranate) の許諾済み後継です。MITライセンスと第三者表記を保持しています。
