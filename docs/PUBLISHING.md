# Castor の公開準備

Castor は Pomegranate の後継として、新しい GitHub アカウントに新規リポジトリを
作成しました。管理先は [Methurcoder/Castor](https://github.com/Methurcoder/Castor) です。
Pomegranate由来とライセンスを残して新しい履歴を開始しました。2026-10-14に監査修正と
ユーザーによる2段階認証の有効化確認を経て、許可を受けてソースを再公開しました。
初回アプリReleaseは `v0.3.0` の正式版として公開します。
Mac arm64とWindows x64のQwen対応配布物を用意し、Windowsは公開プレビュー、
署名・実機確認の未完了事項はREADMEとRelease説明に明記します。
宣伝は管理者本人の指示により後日にします。
アカウント切り替えと公開操作の前にユーザーへ声をかけます。

## ローカルで用意するもの

1. [README](../README.md) と実装を一致させる。アプリ / Xcode scheme は `Castor`、共有 Package は `CastorCore`、Windows preview は `CastorDesktop` / `CastorPet`。
2. [変更点の下書き](RELEASE_NOTES_DRAFT.md) をまとめる。
3. [移行メモ](CASTOR_MIGRATION.md) に従い、公開候補 worktree のソースをコピーする。
4. 改名後のビルド・テストと旧保存データの読込を確認し、対象 OS の実機確認結果と未確認事項を残す。改名前の成功記録とは区別する。

リポジトリルートで次を実行すると、Git 管理ファイルの**現在の内容**と、
指定した新規準備ファイルを新しいフォルダへ書き出せます。未コミットの修正も含みます。
出力先は checkout 外の未作成フォルダを指定してください。

```sh
python3 scripts/prepare-castor-source.py --output /private/tmp/castor-source-preparation
```

結果は `Castor/`、`Castor-source-preparation.zip`、ファイルごとの SHA-256 を持つ
`migration-manifest.json` です。履歴を含まない確認用ソースで、Git 初期化、ログイン、
remote 変更、アップロードは行いません。Castor 本体は新しい履歴で開始済みですが、
このソースコピーは履歴を持たない確認用成果物です。

## 公開対象の確認

- ソース、README、ライセンス、第三者表記、必要なビルド資料を含める。
- ローカル引き継ぎメモ、宣伝下書き、`.claude/`、`dist/`、評価生成物、学習データ、
  モデル、保存したペット、私的なスクリーンショット、署名情報を含めない。
- `LICENSE` の Pomegranate contributors の権利表記と `THIRD_PARTY_NOTICES.md` を保持する。
- 書き出しツールの既知パターン検査だけで安全と判断しない。候補ファイルを確認し、
  履歴を継承する場合は過去の履歴も確認する。
- ScreenshotAnswer を含める場合、その Package の検査も実施する。

```sh
./ScreenshotAnswer/scripts/check-public-safety.sh
git diff --check
```

作者署名付き macOS バイナリと Windows 実行ファイルは、対象 OS で実際に確認してから
配布物として作成します。ソース zip の作成はバイナリの動作検証を意味しません。

## アカウント切り替え前

ローカル準備ができた段階でユーザーへ声をかけ、新アカウントを確認します。
ログインはユーザーが手元で行い、パスワードやトークンをチャットへ貼り付けません。
現在の Pomegranate の `origin` へ push する従来手順は、この移行では使いません。

## 更新・再公開前

`Methurcoder/Castor` はソース公開済みです。ローカルの修正内容と確認結果を
示し、ユーザーへ声をかけてから push を行います。非公開リポジトリへの push も対象です。
公開設定変更、Release 作成、バイナリ添付の前にも対象を伝え、確認を受けます。

Castor は新しい Git 履歴で開始済みです。旧 Pomegranate とその未コミット作業を保持します。
公開範囲とバージョンが決まったら README とリリース説明に反映します。

## アカウントとReleaseの保護

- Methurcoder の「Settings → Password and authentication」で 2段階認証を有効にし、
  recovery codes を安全な場所へ保存する。公開前にユーザーが手元で有効なことを確認する。
  GitHub API の取得結果が null の場合は、有効・無効の根拠には使わない。
- リポジトリの「Settings → General → Releases → Enable release immutability」を有効にする。
  2026-10-14 に有効化済み（API 読取値 `enabled: true`）。公開前にも再確認する。
  [GitHub の手順](https://docs.github.com/en/code-security/how-tos/secure-your-supply-chain/establish-provenance-and-integrity/prevent-release-changes)。
- 不変設定は今後公開する Release に適用される。Draft の間に全 ZIP、manifest、
  ライセンスと説明を揃えて確認し、それから Release を公開する。公開後の asset/tag の
  差し替えによる修正は行わず、新しいバージョンを作る。
- 不変設定だけでは、不正な新規 Release の作成やビルド環境の侵害を防げない。
  SHA-256 と同じ Release の manifest だけでは配布者の真正性を証明できない。
  [ダウンローダーの保護と限界](DOWNLOADER.md#アプリ取得時の保護と限界)を利用者へ示す。
- Developer ID 署名・notarization は未整備。Apple の証明書と公証を使う正式配布経路を
  次の段階で用意し、鍵や認証情報は手元の keychain / CI の秘密情報として管理する。

## アプリRelease候補の確認（2026-10-15）

利用者はソース更新だけでなく、Qwen 3 TTSをターミナルなしで使えるアプリReleaseを
目指すよう指示しました。UI刷新は後回しです。既存の事前通知・実機確認・署名の
未完了事項の明示を維持し、全機能parityを達成したとは扱いません。

- [候補の確認記録と未確認事項](RELEASE_NOTES_DRAFT.md#配布候補の状態2026-10-15)を揃える。
- Mac候補は指定4つのcompiled Core MLモデルを必須とし、欠落時は梱包を停止する。
- Macはad-hocのみ、Windowsはコード署名未整備。正式署名済みと表示しない。
- 現行ダウンローダーはlatest通常Release専用。Pre-releaseを公開するなら、取得経路を
  先に対応し、取得可能なことを確認する。候補のbeta名だけでは公開区分を決めない。
- CI artifactは開発用の配布候補。Release公開や実機確認を代替しない。
- Draft作成やバイナリ添付の前に、候補名・対象CPU・署名・確認範囲をユーザーへ伝える。

## 公開後のX紹介URL

GIF の Web Intent にリポジトリ URL を入れる準備を実装済み。
ソースの再公開に合わせ、Xcode の app ターゲットの Debug / Release で
`SWIFT_ACTIVE_COMPILATION_CONDITIONS` に `$(inherited) CASTOR_PUBLIC_REPOSITORY` を
指定した。投稿画面の `url` に
`https://github.com/Methurcoder/Castor` が追加される。
X への添付・投稿は引き続きユーザーが手動で行う。

## ソース再公開の確認記録 (2026-10-14)

- 2段階認証の有効化を管理者本人が確認した。認証情報や recovery codes は取得・保存していない。
- 監査修正コミット `b7aab1c` の Windows / Mac CI は成功。
- 公開前に到達可能な Git 履歴の326 blobで既知のcredential・個人ホームパスを検査し、
  検出なし。ScreenshotAnswer の公開対象24ファイルの検査も成功。
  これらは包括的な秘密情報・セキュリティ監査ではない。
- Release の不変設定は有効。アプリ配布 Release は作成しない。
- Developer ID署名・公証、Intel GPUのGIF出力、WindowsのGUI・配布物の実機確認は継続課題。

## 正式公開を先行する方針（2026-10-15）

管理者本人が「実行レビュー用に正式公開を先行し、宣伝は後にする」と指定しました。
初回の正式公開番号は `v0.3.0`。GitHubの通常Releaseとして公開し、latest経由の取得を使います。
READMEへ「これは正式リリース版です。」を記載し、Windowsの公開preview/実機未確認、
Mac ad-hoc/Developer ID・公証なし、Windowsコード署名なし、新規導入の未確認を併記します。
従来の署名・全機能実機確認を終えてから公開する方針は、今回の明示指示で変更します。
全機能共通化の完了条件は保持し、未完成を完成扱いしません。宣伝・X投稿は行いません。

全asset/manifest/ライセンスをローカルで検査し、Draftへ揃えてから公開します。
公開操作の前には今回の具体的なバージョンと確認範囲を本人へ伝えます。
