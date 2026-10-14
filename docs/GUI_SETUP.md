# CastorのGUI導入・更新・修復

2026-10-14。GitHub Releasesを入口にする設計の実装中です。
**配布Releaseはまだなく、公開のGUIインストーラーや完成版アプリは取得できません。**
開発用Mac GUIの起動と「配布Releaseなし」の案内を確認しました。
Windowsの実機確認は、ダウンローダーから導入できる配布候補ができた段階でまとめます。

## 利用者の流れ

ReleaseからOSに合う`CastorSetup-…zip`を取得して展開し、Macは`CastorSetup.app`、
Windowsは`CastorSetup.exe`を開きます。Swift、Xcode、Visual Studio、Pythonの導入や
コマンド入力は、このGUIインストーラーの使用には必要ありません。
初回にOSの安全確認が出る場合があります。署名/公証が整うまでは正式配布しません。

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
