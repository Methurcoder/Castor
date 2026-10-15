# CastorのGUI導入・更新・修復

2026-10-15。GitHub Releasesを入口とするGUI導入方式を実装しています。
**[正式リリース v1.0.0](https://github.com/Methurcoder/Castor/releases/tag/v1.0.0)からGUI導入パッケージを取得できます。**
開発用Mac GUIの起動と「配布Releaseなし」の案内を確認しました。
Windowsの実機確認は、ダウンローダーから導入できる配布候補ができた段階でまとめます。

## どのZIPを選ぶ？

| ZIP | 中に入っている起動ファイル | 用途 |
| --- | --- | --- |
| `CastorSetup-v1.0.0-macos_arm64.zip` | `CastorSetup.app` | MacのGUI導入 |
| `CastorSetup-v1.0.0-windows_x86_64.zip` | `CastorSetup.exe`と必要DLL | WindowsのGUI導入。フォルダごと展開 |
| `Castor-Downloader.zip` | `.command` / `.cmd` / `.ps1` | スクリプト版。GUIを使う場合は上のSetupを選ぶ |

`Castor-Downloader.zip`に`.app`や`.exe`が無いのは仕様です。通常はOS別の**CastorSetup**を使ってください。

## 利用者の流れ

ReleaseからOSに合う`CastorSetup-…zip`を取得して展開し、Macは`CastorSetup.app`、
Windowsは`CastorSetup.exe`を開きます。Swift、Xcode、Visual Studio、Pythonの導入や
コマンド入力は、このGUIインストーラーの使用には必要ありません。
Macでは現在ad-hoc署名のため、初回は「システム設定 → プライバシーとセキュリティ → このまま開く」の本人操作が必要です。
Windowsのコード署名、MacのDeveloper ID署名・公証は未整備です。管理者は実行レビューのため
正式公開を先行する方針を指定しました。確認範囲と制約を掲載し、宣伝は後にします。

- **取得・更新**: 対応OS/CPUの完成したアプリだけを取得、検証して配置します。
- **起動**: 選択中のアプリをOSの通常の起動経路で開きます。
- **修復**: 同じ版を別フォルダへ取得し直します。旧版を残して切り替えます。
- **アプリを削除**: 選択中の管理対象アプリだけを削除します。旧版、ペット、設定は残ります。

Macの配置先は`~/Applications/Castor-<version>-<platform>/Castor.app`、Windowsは
`%LOCALAPPDATA%\Programs\Castor\Castor-<version>-windows_x86_64\CastorPet.exe`です。
Windowsペット・設定は`%LOCALAPPDATA%\Castor`にあり、アプリのversionフォルダとは分けます。
Macの既存保存先と旧Pomegranate設定キーを変更しません。

## 失敗時と安全確認

ZIPと同じReleaseのmanifestから容量/SHA-256を照合します。破損の検出であり、配布元の真正性を
証明するものではありません。アカウント保護・不変Release・正式署名と合わせて運用します。

ZIP内の相対パス・重複・暗号化・symlink・容量・必要ファイルを検証し、配置先と同じvolumeの
作業フォルダで展開します。OS管理lockで同時処理を防ぎ、クラッシュすればlockはOSが解放します。
新しいappが完成してから選択記録をatomic更新します。更新失敗・取消・破損では旧選択とデータを
保持します。取消では展開プロセスの終了を待ってから作業フォルダを除去します。

Macのappへquarantine、Windowsのexe/DLLへMark of the Webを設定し、OSの通常の起動経路を使います。
Gatekeeper/SmartScreenの設定やquarantineを解除しません。Windowsの展開は内蔵PowerShellの
`Expand-Archive`を使い、ExecutionPolicyを変更しません。パスはliteralで渡します。

## 開発者の梱包

`scripts/build-castor-setup.py`はGUIをReleaseビルドし、Macは`.app`、Windowsはexeと必要なSwift/C++
DLLをローカルへまとめます。WindowsはPE importsを再帰走査し、System32のDLLを配布へコピーしません。
追加runtimeは正式な再配布フォルダから取得します。再配布権・LICENSEの最終確認も必要です。

`scripts/prepare-castor-release.py`の既存app引数に`--setup-macos-arm64`、`--setup-macos-x86-64`、
`--setup-windows-x86-64`を足すと、それぞれのGUI ZIPと容量/SHA-256をmanifestに追加します。
どちらのscriptもReleaseの作成・uploadを行いません。

## 検証境界

共有処理の自動検査: SHA-256の既知ベクトル/stream、ZIP拒否、取得後の更新・修復・削除、
展開/取消/stamp/破損での旧選択保持、同時導入の拒否と取消直後の再試行。
native展開はCIで空白・日本語・apostrophe入りのパスを確認する経路を追加しています。

Windowsの初回GUI、実機のOS警告・マイク、開発環境のないPCでのDLL集合、正式署名、Macの公証、
全機能の両OS実機確認は未完了です。外部agent/追加ML/helperの自動導入も継続中です。

## 通常のアプリ起動入口

導入後はMacの`~/Applications/Castor.app`、Windowsのスタートメニュー「Castor」から
選択中の版を起動する入口を作ります。バージョン付き実体とユーザーデータは別に保持します。
同名の無関係なファイル/ショートカットがある場合は上書きせず、その旨を表示します。
この場合もGUIの「起動」から実体を開けます。削除時は自分の管理対象への入口だけを除去します。
配布後の新規端末での実機の直接起動は未検証です。

## 任意のNeural TTS helper

導入GUIでNeural TTS helperの取得/更新・起動・修復・削除を選べます。本体とは別の
`CastorHelpers/NeuralTTS`領域へ導入し、失敗・取消でも旧本体/旧helper/ペット/設定を保持します。
配布manifestの`components.NeuralTTS`にそのOS/CPU用のassetがある場合だけ取得します。
helperを消してもモデルcacheは削除しません。v1.0.0にOS別のhelper assetを用意しています。

Voice設定から導入GUIを開きます。`build-castor-app.py`の候補はMac ResourcesへCastorSetup.app、
WindowsはCastorPet.exeの隣へCastorSetup.exeを同梱します。開発用ビルドにはGUIが無いことがあり、
その場合は配布ページを案内します。Windows/Swift runtimeは再帰収集します。

`build-castor-neural-helper.py`は開発者が用意した環境からPython/Tk/Qwen/PyTorchをGUIにまとめ、
license inventoryを保存します。利用者にPythonの手動導入を求める方式ではありません。
モデルは同梱せず、helper画面で本人が確認して取得します。起動だけではモデルを取りません。
WindowsはCPUでも動く構成を基準とし、CUDAは別途検証する構成です。

Macの既存MLX helperは維持します。新しいQwen backendの0.6Bは指示による声質制御を
保証しません。1.7B CustomVoiceを選んだ場合のみ声の指示を渡します。音声をファイル保存せず、
loopbackのWAVを検査してWindows標準の音声deviceへ再生し、取消で停止します。
Qwen backendの実モデル生成・速度・声の品質・依存DLL/license・開発環境なしのGUI起動は未検証です。
GUI/helper builderと固定データ検査だけで、全機能parityを完成したとは扱いません。


## Qwen GUI起動の配布候補 (2026-10-15)

今回の公開準備ではUI刷新を保留し、Qwen 3 TTSを優先します。
Mac Voiceに起動・停止・明示的なモデル取得/準備・取消を追加しました。
設定を開く、Qwenを選ぶ、通常の発話を始めるだけではモデルを取りません。
準備できない場合は既存のOS標準音声へ戻します。

Apple Siliconではnative SwiftUI GUIから、同梱Python runtimeのMLX 0.6B CustomVoiceを使います。
WindowsのGUI/CPU backendとHTTP・取消・サイズ制限を共有し、既存Macの言語名とstatus endpointも保持します。
Mac配布候補はhelperをResourcesへ同梱可能です。別途導入したhelperはApplicationsの
CastorNeuralTTS.app入口を作り、VoiceからLaunch Services経由で開きます。
同名の無関係なappは上書きせず、OSのquarantine・安全確認は解除しません。

モデル取得の取消は取得/読込の処理が返るまで停止完了しない場合があります。
音声生成は短いchunk間で取消を確認し、音声はWAVをメモリで渡します。
MLX版の速度変更は再生速度変更であり、音程を維持する声質加工とは扱いません。
モデルの実読み上げ・GUI・梱包後の依存ロード結果は検査後に追記します。
現在、正式なDeveloper ID署名・公証用の証明書は未確認で、ローカル候補は開発署名です。


## 配布監査への対応 (2026-10-15)

Mac本体のビルドとZIP梱包は、AnimeFaceFeatures / AnimeFaceBoxHead / AnimeFaceLandmarks /
AnimeSegmentationの4つのcompiled modelを必須にします。無い、空、必要なweight/MILファイルが欠ける候補は停止します。
開発用ビルドのfallbackと配布の条件を分けます。モデルの存在検査だけを顔マーカーの精度保証とは扱いません。
Windows向けCore ML代替の品質検証は別途未完了です。

導入GUIはOSの優先言語から日本語/Englishを選び、確認・状態・完了・失敗を両言語で表示します。
helper削除は補助アプリだけを対象とし、モデルcache・ペット・会話設定を保持します。
未署名/開発署名のMac候補はquarantineが付くため初回にブロックされます。
導入GUI自身、本体、helperそれぞれを開いた後、システム設定 → プライバシーとセキュリティ →
このまま開く（System Settings → Privacy & Security → Open Anyway）で本人が許可します。
ランチャーが安全確認を解除する方式ではありません。正式署名/公証は未完了です。

管理メタデータは配置先の隠しフォルダ .CastorInstaller に保存します。旧selection recordは読込互換を持ち、
更新成功時だけ隠しfolderへ移します。旧lockは同時操作防止を保ったままFinderで非表示にします。
旧版整理は現在版と1つ前を保持し、receiptとファイル指紋が一致するそれ以前だけをOSごみ箱へ送ります。
指紋のない旧版、変更されたfolder、未知のfolder、Macで起動中の版は保持します。
整理に失敗しても新しい導入とペット・設定は保持します。OSのごみ箱動作の実機確認は継続中です。

Mac Apple Siliconで梱包後の音声helperのGUI起動・停止画面、モデル準備と実モデルの日本語音声を確認しました。
Ono_Anna / Japaneseで24kHz・3.12秒・無音でないPCM WAVを生成し、OS音声出力で再生しました。
これは一文の生成/再生確認であり、音声の品質全般、長文・多言語・初回ネット取得・Windowsの実発声を保証しません。

## Mac本体Voiceの確認（2026-10-15）

同梱helperを本体から起動し、既存cacheからのQwen準備、27文字/3区間の日本語音声生成、
アプリ内再生、停止・再起動・本体終了時の後片付けを確認しました。標準音声fallbackはありません。
停止要求は起動ごとのcontainer control/ownerを使い、別途起動したhelperや任意PIDを停止しません。
frozen Pythonのresource trackerを正しく分岐し、試聴後の停止で子processが残らないことも確認しました。

Mac helper inventory46件にlicense本文欠落なし。4つのCore MLモデルを本体へ同梱し、
候補のad-hoc署名と既知home path検査も成功。新規model取得/最初のOS警告/Windows実発声は未確認です。

## 音声モデルをロードするタイミング

v1.0.0では、設定を開く・音声エンジンを選ぶだけではモデルをロードしません。
Macの音声設定には「音声はQwen 3 TTSでよりリアルになります。ロードしますか？」のバナーがあります。
「ロード」から補助アプリ起動→応答待ち→モデル取得・ロードを順に実行します。
Windowsの補助アプリ側も「ロード / Load」で明示的に開始します。未準備の場合は標準音声へ戻ります。

## v1.0.0の最新修正

Windowsの作成画面と導入ウィザードはWebView2を使います。配布ZIPはDLL・UI/SetupUIを含めて展開し、exeだけを移動しないでください。
WebView2 RuntimeがないWindowsではMicrosoftの公式ランタイムの導入が必要です。
Macはドラッグ導入用DMGも用意します。
最新のWindows ML同梱・作成画面・ウィザードと共通ML変更は、管理者の指示により追加テストを省いて正式Releaseへ含めています。
上記の先行候補の確認記録は、今回の全修正の再検証を意味しません。
