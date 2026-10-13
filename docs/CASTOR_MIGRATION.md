# Pomegranate から Castor への移行メモ

2026-10-14 時点。Castor は Pomegranate の後継プロジェクトとして、別 GitHub
アカウントに新規作成しました。公開先は [Methurcoder/Castor](https://github.com/Methurcoder/Castor)
です。監査修正後、ユーザーの許可を受けてソースコードを再公開しました。新しい Git 履歴とPomegranate由来の
説明と著作権・ライセンスを保持しています。Windows実機と配布バイナリは別途確認します。

## 準備する範囲

- README を Castor 名義にし、実装と検証範囲を説明する。
- 公開手順を新アカウントでの新規作成へ更新する。
- `scripts/prepare-castor-source.py` で現時点の公開候補ソースを書き出す。
- ローカルメモ、`.claude/`、`dist/`、評価生成物を Git の除外対象にする。
- 内蔵 AI の能力制限とモデルサイズ表示もソース候補に含める。

準備元は公開候補ブランチ `claude/release-candidate` です。本体 checkout にある
追加の未コミット Arils 作業は移行対象に含めません。

## 名前と互換性

アプリと新規保存データの名称を Castor に揃えます。互換性のために保持する名前は明示します。

| 対象 | Castor の名称・動作 | 互換性・確認事項 |
| --- | --- | --- |
| macOS アプリ | `Castor/Castor.xcodeproj`、target / scheme / module `Castor` | `CastorTests` / `CastorUITests` と関連設定を更新。対象 Mac で確認する |
| 共通 Package | `CastorCore` / `import CastorCore` | アプリ・テスト・CI の依存とコマンドを更新 |
| Windows preview | `CastorDesktop`、実行ファイル `CastorPet` | 対象 Windows でビルド・Win32 動作を確認する |
| macOS bundle ID | `dev.pomegranate.prototype` を保持 | 既存 sandbox container と OS 権限の継続利用のため |
| 設定キー | `Pomegranate.*` を保持 | 設定内容の読み込み互換性のため |
| 新しいペット保存 | Application Support の `Castor/CastorPet.json` | 新名の保存を優先。旧 `Pomegranate/PomegranatePet.json` は読み取り fallback |
| Windows 既定入力 | `CastorPet.json` | 見つからない場合は旧 `PomegranatePet.json` を読み取り fallback。明示パスも受け付ける |
| helper のローカル環境 | 新しい `.castor-*` | 起動スクリプトは既存 `.pomegranate-*` 環境を fallback として利用。旧環境を削除しない |
| 独立ライブラリ・実験 | `Arils` / `Arils-ex` / `ScreenshotAnswer` を維持 | 独立したプロダクト名で、Castor 名へ変更しない |

ペットの保存先変更では、旧ファイルを削除・移動しません。新旧両方にファイルがある場合は新名を優先します。bundle ID と設定キーを含めた改名後の動作は、ビルドと実機で確認します。

## リポジトリと履歴

ユーザーの指定で新しい履歴を開始します。準備ツールは履歴のないソースコピーを作り、
その内容を独立した新リポジトリの初期コミットにします。旧リポジトリの履歴は旧側に残します。

- 新しい履歴で始める場合: ソースコピーで初期コミットを作り、由来と権利表記を残す。
- 履歴を継承する場合: 別 checkout で過去のローカルメモ・秘密情報・作者情報の
  公開範囲を確認する。現行ソースの簡易検査だけで過去履歴を安全と判断しない。

旧 repository の transfer / rename、既存 remote の付け替えは準備ツールでは行いません。
`LICENSE` の Pomegranate contributors の権利表記と `THIRD_PARTY_NOTICES.md` を保持します。

## 公開前にユーザーと決めること

- 初回リリース名と配布物。ソースコードの公開は完了しています。
- アカウントは `Methurcoder`、履歴は新規と決定済み。アプリ表示名と主要ファイル名は Castor へ統一する。

アカウント切り替え時に声をかけ、ユーザーが手元でログインします。
リポジトリ作成・push・公開設定変更・Release 作成前にも必ず声をかけます。

## Windows 実機チェック

起動完了の連絡を受けてから、接続と対象 checkout を確認します。
Windows 上の Codex でコマンドを実行できることと、画面を観察・操作できることは
個別に確認します。準備済みソースで次の挙動を確認し、結果を記録します。

1. Swift / C++ ツールチェーンと Package のビルド。
2. export 済みペットの読込と透過ウインドウへの表示。
3. ドラッグ、Alt の透過クリック、右クリック終了。
4. 瞬き、視線、呼吸、`--wide-head` の既知の描画崩れ。
5. 起動失敗時の出力と Win32 に起因するコンパイルエラー。

Windows preview は macOS の全機能を備える版ではなく、音声会話・agent 承認・
リギング UI の検証とは別に扱います。

## 検査結果の範囲

2026-10-13 の移行前の Git 管理ファイル 274 件で、代表的な credential 形式、
個人ホーム絶対パス、Xcode Team ID のパターン一致はありませんでした。
全形式の秘密情報、画像内容、過去履歴、第三者ライセンス全件の監査ではありません。

改名前の内蔵 AI 変更は Core の 109 テストと macOS app build が成功しています。
Linux クロスビルド成功は改名前の引き継ぎ資料の記録で、改名後の再実行はしていません。
Castor への改名後は Core の 109 件、Desktop の 4 件（当時1件は保存ペット不在で検証を省略）、macOS app の 34 件、
ScreenshotAnswer の 23 件、Claude Bridge helper の 6 件のテストが成功しました。
macOS の app test は `Castor` scheme でビルドも行い、旧ペット読み込み・新保存名の優先・
旧ファイルを変更しないことを回帰テストで確認しています。UI テストは除外しました。
移行用フォルダと zip と manifest の指紋一致も確認します。
GUI、実モデル、Windows 実機、アクセシビリティ権限付き退避は未確認です。


### 2026-10-14 Windows報告への対応

旧Pomegranate preview ZIPのWindows Swift 6.4.1 x64テスト報告を受け、
CastorPetのprivate型を使う変数とGetMessageWのBoolの扱いを修正しました。
個人の保存済みペットを探すテストは、全OSで常に実行する合成リグ描画へ置換しました。
MacのSwift 6.4.1でDesktopの7件がすべて実際に検査を実行して成功し、
MacアプリのReleaseビルドも成功しました。配布ZIPとダウンローダーの11件は
オフライン固定データで成功し、PowerShell側の処理もMac上のPowerShellで検査しました。
加えて[Windows/macOS CI](https://github.com/Methurcoder/Castor/actions/runs/38424052817)で両OSの7件とWindows Win32 Releaseビルドが成功しました。
ダウンローダーはWindowsで8件を実行し、Mac専用3件を明示的に省略、Macでは11件が成功しました。
Windows GUIと実ペットの見た目の再検査は未実施です。

OS/CPUに対応する完成アプリだけを取得するダウンローダーと配布準備ツールを追加しました。
GitHub Releaseは未作成です。ローカルで用意したMac appはad-hoc署名で、
配布用署名・notarizationは完了していません。詳しくは[ダウンローダー](DOWNLOADER.md)を参照してください。
