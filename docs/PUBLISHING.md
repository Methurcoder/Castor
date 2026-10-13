# Castor の公開準備

Castor は Pomegranate の後継として、新しい GitHub アカウントに新規リポジトリを
作成しました。公開先は [Methurcoder/Castor](https://github.com/Methurcoder/Castor) です。
Pomegranate由来とライセンスを残して新しい履歴を開始し、ソースコードを公開しています。初回リリースのバージョンと配布バイナリは未確定です。
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
remote 変更、アップロードは行いません。新しい履歴で始めるかは別途確定します。

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

## 新リポジトリの作成・公開前

準備済みソース、名前、owner、履歴方式、公開範囲を示して確認した後、新アカウントの
リポジトリ作成と最初の push を行います。private 作成と push の前にも声をかけます。
公開設定変更、Release 作成、バイナリ添付の前にも対象を伝えます。

履歴なしで始める場合は準備済み `Castor/` で新しい Git を初期化し、履歴を継承する場合は
別 checkout に監査済み履歴を用意します。既存 Pomegranate と本体の未コミット作業を保持します。
新しい URL とバージョンが確定したら README とリリース説明に反映します。
