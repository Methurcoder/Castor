# Castor ダウンローダー

OS と CPU を判別し、対応する Castor の配布 ZIP を取得するローカルランチャーです。
**現在は GitHub Release が存在しないため、アプリの取得はまだできません。**
リポジトリのソースからビルドする手順は [README](../README.md)を参照してください。

## 利用者向けの手順

Release が用意された後、対応するランチャーを実行します。

| 環境 | 起動するファイル | 条件 |
| --- | --- | --- |
| macOS | `download/Castor-Download.command` を Finder でダブルクリック | macOS 26.5 以上。CPU に対応する配布物が必要 |
| Windows | `download/Castor-Download.cmd` をダブルクリック | 現在は x64 のみ。`Castor-Download.ps1` を同じフォルダに置く |

ランチャーは OS と CPU を判別し、GitHub の latest Release にある
`castor-downloads.json` を読みます。対応する ZIP だけを取得し、manifest の
SHA-256 と照合してから展開します。対応する配布物がない環境では取得できません。

展開先はユーザーのホームフォルダ内です。`<version>` と `<platform>` は
Release の情報に置き換わります。

| 環境 | 展開後のアプリ |
| --- | --- |
| macOS | `~/Applications/Castor-<version>-<platform>/Castor.app` |
| Windows | `~/Downloads/Castor-<version>-<platform>/CastorPet.exe` |

配布用 `Castor-Downloader.zip` には両OSの小さな起動スクリプトを同梱します。
Mac版・Windows版の大きなアプリを両方ダウンロードすることはありません。

新しいフォルダへ展開し、既存のインストールを上書きしません。取得用の一時 ZIP は
削除します。アプリは自動実行せず、展開したフォルダを表示します。

Windows 版はペットの再生プレビューです。アプリ本体にキャラクターのデータは
含みません。ペットデータがない場合は、Mac の Arils で作成した `CastorPet.json`
または `.arils` を用意し、展開先の `Start-Castor.cmd` から選択してください。自動リギング、会話、音声、カメラは
Windows 版では未実装です。

## 非公開 Release の認証

現在の `Methurcoder/Castor` は非公開です。非公開 Release を取得するには
GitHub CLI (`gh`) を用意し、アクセス権のあるアカウントで手元のターミナルから
ログインします。

```sh
gh auth login
```

認証は GitHub CLI の通常の画面で行います。パスワードやトークンをチャットへ
貼り付ける必要はありません。ダウンローダーはログインやアカウント切り替えを
自動で行いません。アカウントを変える必要がある場合は、ユーザーが手元で行います。
公開 Release の取得には `gh` は不要です。

ログイン済みでも Release が存在しなければ取得できません。

## 配布物を用意する側の手順

`scripts/prepare-castor-release.py` は、ビルド済みの macOS `.app` または
Windows の実行ファイルディレクトリを ZIP にし、SHA-256 を持つ
`castor-downloads.json` を生成するローカルの準備ツールです。
Windows は実行に必要な DLL を含めたディレクトリを入力します。
ライセンスと必要な第三者表記を配布物へ同梱します。

ツール自体は Release 作成、アップロード、公開設定変更を行いません。
引数と入力形式は、次のヘルプで確認します。

```sh
python3 scripts/prepare-castor-release.py --help
```

配布前には次を別途確認します。

- macOS の署名・notarization と、配布先 Mac での起動。
- Windows の DLL が揃っていることと、Swift 開発環境に依存しない起動。
- 実ペットの読み込み、描画、GUI 操作。合成図形の表示やビルド成功だけで完了としない。
- 配布 ZIP にライセンスと必要な第三者表記が含まれること。

SHA-256 の照合は取得ファイルと manifest の一致確認です。署名・notarization、
必要 DLL の正常性、GUI の実機確認を代わりに行うものではありません。

配布物と確認結果を揃えた後、ユーザーに対象を伝えて確認を受けてから Release 作成・
アップロード・再公開を行います。詳細は [公開ガイド](PUBLISHING.md)を参照してください。


### ローカルでの準備例

```sh
python3 scripts/prepare-castor-release.py --version v0.1.0 \
  --macos-arm64 /path/to/Castor.app \
  --windows-x86-64 /path/to/windows-runtime \
  --output /path/to/new-release-folder
```

macOS Intel用は `--macos-x86-64` です。実際にビルドしたCPUの配布物だけを登録します。
Windows入力は `CastorPet.exe` と必要DLLだけを置いた専用ディレクトリです。
`swiftCore.dll` が必要で、保存済みペット、設定、ログ、開発用ファイルは拒否します。
DLLの依存が全て揃うことをこのツールだけでは証明できないため、Swiftを入れていない
Windowsで起動し、Swift/ICU/Visual C++等の再配布条件・必要なライセンスを確認してください。
生成物はOS別ZIP、`castor-downloads.json`、小さな `Castor-Downloader.zip` です。

Mac appは通常のビルドだけではad-hoc署名になります。現在のローカル確認用ZIPも
ad-hoc署名で、公開配布用のDeveloper ID署名・notarizationは未実施です。
ランチャーはGatekeeperの設定やファイルのquarantineを解除しません。
Windowsの `.cmd` は同梱スクリプトをそのPowerShellプロセスだけで実行し、
システムのExecutionPolicyや管理者設定は変更しません。
