# Castor ダウンローダー

OS と CPU を判別し、対応する Castor の配布 ZIP を取得するローカルランチャーです。
**[正式リリース v0.3.0](https://github.com/Methurcoder/Castor/releases/tag/v0.3.0)のGUI導入パッケージを使ってください。**
リポジトリのソースからビルドする手順は [README](../README.ja.md)を参照してください。

## GUI版とスクリプト版の違い

通常の導入にはOS別の`CastorSetup-…zip`を使ってください。展開後はMacなら`CastorSetup.app`、
Windowsなら`CastorSetup.exe`を開きます。[ZIPの選び方](GUI_SETUP.md#どのzipを選ぶ)もご覧ください。

`Castor-Downloader.zip`はスクリプト版です。中身が`.command` / `.cmd` / `.ps1`なのは仕様で、
`.app` / `.exe`のGUIインストーラーとは別ファイルです。

## スクリプト版の手順

スクリプト版を使う場合は、対応するランチャーを実行します。

| 環境 | 起動するファイル | 条件 |
| --- | --- | --- |
| macOS | `download/Castor-Download.command` を Finder でダブルクリック | macOS 26.5 以上。CPU に対応する配布物が必要 |
| Windows | `download/Castor-Download.cmd` をダブルクリック | 現在は x64 のみ。`Castor-Download.ps1` を同じフォルダに置く |

ランチャーは OS と CPU を判別し、GitHub の latest Release にある
`castor-downloads.json` を読みます。対応する ZIP だけを取得し、manifest の
SHA-256 と照合してから展開します。対応する配布物がない環境では取得できません。

展開先はユーザー専用のフォルダです。`<version>` と `<platform>` は
Release の情報に置き換わります。

| 環境 | 展開後のアプリ |
| --- | --- |
| macOS | `~/Applications/Castor-<version>-<platform>/Castor.app` |
| Windows | `%LOCALAPPDATA%\Programs\Castor\Castor-<version>-<platform>\CastorPet.exe` |

配布用 `Castor-Downloader.zip` には両OSの小さな起動スクリプトを同梱します。
Mac版・Windows版の大きなアプリを両方ダウンロードすることはありません。

新しいフォルダへ展開し、既存のインストールを上書きしません。取得用の一時 ZIP は
削除します。アプリは自動実行せず、展開したフォルダを表示します。

Windows は OS の LocalApplicationData フォルダを使い、配置先と同じ場所に作業用
フォルダを作ります。TEMP が別ドライブでもフォルダ移動で失敗しない構成です。
古い Downloads 内のインストールは移動・削除しません。

### ダウンローダーを初めて開くとき

ブラウザで取得した `Castor-Downloader.zip` は、展開したスクリプトにもインターネット
由来の印が引き継がれる場合があります。表示は OS の版、ブラウザ、展開方法、管理ポリシー
によって異なります。警告が出た場合、配布元が `Methurcoder/Castor` であることと、
このスクリプトが実行する内容を確認してから、必要な場合に限り次の操作を行います。

- **Mac:** Finder で `Castor-Download.command` を開こうとして止まったら、
  「システム設定 → プライバシーとセキュリティ」のセキュリティ欄で、そのファイル名を
  確認して「このまま開く」を選び、再度の確認に従います。
  [Apple の案内](https://support.apple.com/en-us/102445)も参照してください。
- **Windows:** SmartScreen の「Windows によって PC が保護されました」が出た場合は、
  「詳細情報」で対象ファイルを確認し、実行を選ぶ場合は「実行」を押します。
  管理ポリシーなどにより実行ボタンが出ない場合は、保護を無効化せず管理者へ確認してください。

この手順は、表示された特定のファイルをユーザーが判断して開くためのものです。
ウイルス対策や Gatekeeper / SmartScreen の全体設定を無効化する手順ではありません。

### アプリ取得時の保護と限界

最初にブラウザから取得するダウンローダーと、スクリプトが後から取得するアプリでは、
インターネット由来の印の扱いが異なります。`curl`、`gh`、`Invoke-WebRequest` による取得では、
Mac の `com.apple.quarantine` や Windows の `Zone.Identifier`（Mark of the Web）が
自動で付くことを前提にできません。このランチャーも、その印を新たに付けていません。
したがって、展開したアプリをユーザーが開く際に、**Gatekeeper や SmartScreen の
ダウンロード由来の警告が表示されない場合があります。警告がないことは安全性の証明ではありません。**
OS のその他の保護まで無効になるという意味でもありません。

ランチャーは既存の quarantine / Mark of the Web を削除せず、OS 全体の保護設定も
変更しませんが、これだけでダウンロード由来の確認が働き続けるとは言えません。
Windows の `.cmd` は同梱スクリプトをその PowerShell プロセスだけで
`-ExecutionPolicy Bypass` により実行します。これはスクリプト実行ポリシーの
プロセス内での上書きであり、システム設定の永続変更や管理者権限取得ではありません。

SHA-256 は ZIP と **同じ Release に置かれた manifest** と照合します。
壊れた取得や manifest と異なるファイルを検出できますが、配布者の真正性を独立に
証明しません。Release と manifest の両方が攻撃者によって差し替えられれば、この照合は
通り得ます。配布元アカウント、Release 作成環境、GitHub の配信、手元のランチャーへ
信頼を置く方式です。現在のダウンローダーは独立した署名・attestation の検証を行いません。

Mac app は通常のローカルビルドでは ad-hoc 署名です。現在の確認用 ZIP も ad-hoc 署名で、
配布者を確認できる Developer ID 署名・公証（notarization）は未実施です。
Windows 配布用 EXE のコード署名も未整備です。

Windows版は全機能共通化の途中です。現在のソースには、PNG選択・顔マーカー補正・
2D変形の試作作成があり、`CastorPet.exe` / `Start-Castor.cmd` の初回案内で作成できます。
Macの自動リギング/Qualityと同等の品質、会話・音声・カメラはまだ未実装です。
Macから保存ペットを読み込むこともできます。GUI導入・全機能共通化の目標と残課題は
[実装計画](CROSS_PLATFORM_PARITY.md)を参照してください。対応範囲と未確認事項は正式Releaseにも記載します。

## 非公開 Release の認証

現在の `Methurcoder/Castor` はソース公開済みで、公開 Release の取得に認証は不要です。
公開Releaseの取得にはログイン不要です。将来、非公開リポジトリでランチャーを使う場合は、
GitHub CLI (`gh`) を用意し、アクセス権のあるアカウントで手元のターミナルからログインします。

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

将来の macOS 正式配布では、Developer ID Application で署名し、Apple の公証を
受けて ticket を staple した app を配布します。証明書・秘密鍵・公証の認証情報は
Git 管理やチャットに含めません。署名・公証済みの配布物でも、対象 Mac で初回起動を確認します。
