# 2026-10-15 夜の不具合修正

ユーザー提供の引き継ぎにある6項目をソースから調査。v1.0.0はDraftのまま保持し、修正前の配布物を公開しない。

| 項目 | Macの調査・修正 | Windowsの調査・修正 |
| --- | --- | --- |
| 透明ペットの謎の枠 | NSPanel.hasShadowを無効化。吹き出しのSwiftUIの影は保持 | ペットはlayered popup、WNDCLASSEXWのstyleは0。OSのCS_DROPSHADOWを使わず、同じ影のキャッシュ設定はない |
| GIF画面がタイトルバーだけになる | hostingの自動windowサイズ変更を無効化。content size 490×650、最小490×600、リサイズ可能に | GIFはCreateWindowExWに755×465を直接指定。NSHostingControllerの自動縮小経路はない。高DPI実機は未確認 |
| Qwen準備後もロード案内が残る | 本体とnative helperでGET-onlyの実モデル状態を確認し、準備済み表示へ変更。停止・切断で戻す | Tk helperにも同じ問題があり修正。backendのready状態を読むだけで自動ロードしない |
| 音が届くのに空の文字起こし | 終了処理が結果consumerを先にcancelし得る。結果streamをdrainしてからcleanup。asset状態確認、古いsessionの起動抑止、認識言語選択、30秒上限と確定待ち8秒、buffer/peak等の診断を追加 | SAPIではMacのmodern→legacy分岐はない。一方、周囲音のcaptureをoffにするだけで解放完了を待っていなかったため、両OSへcapture解放待ちを追加。SAPIのHRESULT・段階・イベント・無結果timeoutを区別 |
| 定型エラーが英語のまま | アプリ由来エラーにだけ翻訳を適用。会話本文・外部providerエラーは保持 | 音声認識のエラーと進行文を設定言語に合わせて日英化 |
| 音声認識の許可状態が見えない | InputへSFSpeechRecognizerの許可、認識言語、OS設定リンク、最後の診断を追加 | 認識エンジン一覧、最後のSAPI診断、Windowsのマイク設定を開く入口を追加。マイク許可はAPIから判定できないため不明と明記 |

## 音声認識の根拠と境界

Appleは、finalizeで確定結果がpublishされてもconsumerがまだ受け取っていない場合があると説明している。
[finalize(through:)の仕様](https://developer.apple.com/documentation/speech/speechanalyzer/finalize(through:))、
[SpeechAnalyzerの終了とresult stream](https://developer.apple.com/documentation/speech/speechanalyzer)。
このためfinalizeだけを待ってすぐresult taskをcancelする順序を変更した。実際のユーザー環境での空認識の唯一の原因と断定したものではない。

診断はMacのSI1とWindowsのSAPI1。録音・認識文章・デバイス名・個人パスを記録しない。
Macの設定 → 入力、Windowsの設定 → 音声認識の状態とマイク設定から確認できる。
現時点ではマイクを使った実発話、実機Windows、修正後GIFの保存/X画面までのGUI通し操作は未実施。

## 限定確認

全体テストは再実行しない。今回の修正を対象に、Coreの診断・翻訳・capture解放順序とGET-onlyモデル状態11件、
Python helperのready表示判定1件が成功。モデル取得や録音なし。Mac本体とnative音声helperのRelease buildが成功。
Windowsの修正後ビルドと配布物の更新は別途記録する。

さらに別ブランチのdf9946eにあるSetupUIのresource宣言修正を取り込み、ページはビルドスクリプトで配置する。
