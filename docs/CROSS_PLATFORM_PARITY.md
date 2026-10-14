# Castor Mac / Windows共通機能・簡単導入

2026-10-14。ユーザーの要求を採用し、実装に着手。引き継ぎ先のClaude Codeも本書と
最新のAGENTS.md / docs/PUBLISHING.mdを確認する。ソースの基準は9fd0427。

## 完了の定義

MacとWindowsで現行Mac本体の全機能と品質をそろえる。OS別の案内だけで導入・起動できること。
Windowsの再生プレビュー、単体のダウンローダー、デモ表示では完了としない。
Macの機能を削って合わせない。旧公式キャラクターは戻さない。

- Swift / Xcode / Visual Studio / Pythonの手動導入、コマンド入力を一般利用者へ求めない。
- Windows単体で画像から作成→補正→保存→再起動後の表示まで行う。
- 1枚/2枚Quality、手動リグ、Advancedを含む全設定を対象にする。
- OS固有のキー・権限画面・音声名だけは異なってよい。
- データ形式、既存Macの保存・設定互換性、ローカル優先、外部操作の個別承認を保持する。
- 取得失敗、キャンセル、破損、更新失敗でも旧アプリ・ペット・設定を保持する。
- 開発環境なしの両OSで全機能を実機確認し、リグを相互利用する。署名・公証まで含める。

## 現状調査

「実装あり」は実機検証済みを意味しない。Windows CIはコンパイル/合成データの確認。

|機能|Macの実装・根拠|Windowsの現状と不足|
|---|---|---|
|1枚自動リグ・マスク・顔候補|ArilsRig/AutoRigPipeline、SubjectMask、FaceLayoutReview|共有マスク/イラスト推定/レイヤー構築に接続。Windows Vision/CoreML代替は未接続|
|2枚Quality・向き・登録・深度|QualityCharacterEngine、QualityHybridTurnModel、QualityPair、MetalAvatarRenderer|Windowsで両画像の補正→共有Quality深度構築を接続。実画像/GUIの品質検証が必要|
|顔マーカー・手動リグ・保存読込|ImageRiggingView、RigDocument、PetCharacterStore|今回Win32補正画面と互換保存を追加。Mac全編集項目/手動パーツ編集が不足|
|呼吸・瞬き・視線・口パク・撫で・自発動作|ArilsMotion、CherryConnection|共有モーションと変形はあり。入力/会話接続・同品質描画が不足|
|移動・透過・背後クリック|CastorPetController、PetPassThrough|ドラッグ/Alt透過あり。透明部分hit-test、位置保持、OS間設定統一を整備する|
|退避・帰巣・反応|PetEvasionWindowProvider、CastorCore/PetEvasion|純粋ロジックは共有可能。Windowsウインドウメタデータ/UI接続なし|
|ボタン検出・広い首振り|PointerTargetClient、SettingsView、controller|広い首振りCLIフラグのみ。検出helper、UI、退避接続が必要|
|会話・性格・モデル・ルーティング|PetVoiceConversation、OllamaSession、LMStudioClient、CastorAgentSettings|CastorCoreに共通クライアントあり。Windows会話/性格/設定画面なし|
|マイク・カメラ・音声認識|TrilobiteEngine、SpeechInputEngine、TrilobiteArilsFaceBridge|Windows入力adapter・権限・録音/認識UIなし|
|標準/Neural TTS・口同期|PetSpeechOutput、PetVoiceProfile、PetSpeechSegmentation|Windows標準音声と同梱helper、共通会話パイプライン接続が必要|
|Codex/Claude Code・承認・拒否・取消|CastorCore/Agent、PetVoiceConversation、承認カード|クライアント再利用。Windows表示・helper管理・キャンセルの実経路が必要|
|AIマーカー提案・顔推定・切り抜き|ArilsAIAdjustment、AnimeFaceModels、AnimeSegmentationModel|ONNX等のWindows代替と同じモデル/前処理/座標/出力の一致検査が必要|
|LaMa|LaMaInpainting、ArilsRig/OcclusionInpainting、localhost helper|Macもbootstrap/startコマンド案内あり。両OSでGUI導入へ変える|
|GIF・X共有|PetGIFExporter、PetGIFShareWindow|生成/容量調整/native preview/保存/X案内を接続。実機GUIと画質を確認する|
|外観/Input/Voice/Brain/Advanced|SettingsViewの全タブ・保存キー|Windows設定画面なし。UI項目単位で完了管理する|
|簡単導入・更新・修復・削除|download/、prepare-castor-release.py|現状はスクリプト式。GUI installerと自動起動、更新/修復/削除は未実装|

独立製品のScreenshotAnswer / Arils-exの新規統合はこの作業の完了条件へ混ぜない。
現行Castor本体が呼び出す機能を基準とし、調査で見つかった追加項目も上表へ足す。

## アーキテクチャ

Swiftの全面書き換えは行わない。ArilsCore/ArilsMotion/ArilsPlayerとCastorCoreを共有する。

|境界|共通契約|Mac adapter|Windows adapter / 作業|
|---|---|---|---|
|画像/リグ|RGBA、image-spaceマーカー、Arils archive、Quality archive|Vision/Core ML、既存ArilsRig|portable 2D試作→ONNX Runtime C API、モデルと前処理一致|
|描画|DeformationEvaluator3D、RenderProjectionContract、深度/alpha pass、画像出力|Metal|CPU基準器→D3D等のGPU backend。depth/opaque/feather一致を要求|
|UI|共通状態/設定DTO、入力・進行・承認イベント|SwiftUI/AppKit|ネイティブUI。今回Win32補正/ファイル選択。CはUIとOS呼出だけを担当|
|入力|TrilobiteInputSnapshot、顔/音量/認識イベント|AVFoundation/Speech/Vision|Media Foundation/Windows認識/ローカル推定のadapter|
|会話/agent|共通クライアント、ルーティング、承認・中断状態|既存接続|同クライアントのWindows対応。権限境界を弱めない|
|音声|文章分割/口同期/再生イベント|標準音声/Neural helper|標準Windows音声/同梱helper。本人選択で追加モデル導入|
|installer|version manifest、hash、署名、stage/commit/rollback|署名・公証済みGUI|署名済みGUI。必要DLL/リソースを同梱|

[ONNX Runtime C API](https://onnxruntime.ai/docs/get-started/with-c.html)を代替候補にする。
これは採用済み/同梱済みではない。モデル配布権、速度、メモリ、Windows実機でのparityを確認する。
MacのApple backendは保持し、Windows対応のためにMac品質を落とさない。

## 第1段階の試作

- PetRuntime/PortableRigging.swift: PNG decode/encode、alpha/単色背景処理、テンプレート、
  マーカー検証、既存warpKeyformで2D変形、Arils/保存ペット形式への書出し。
- CDesktopUI: PNG/ペット選択、画像上で矩形ドラッグ・数値補正。追加ランタイム不要。
- CastorPet/RiggingFlow.swift: 初回作成/読込、PortablePetLibraryの保存履歴、次回再読込。ペット右クリックから
  新規作成/読込/Arils書出し。作成・読込失敗とキャンセルは既存ペットを保持する。
- 作成データは `%LOCALAPPDATA%\Castor\Library` にUUID名で保持し、LastPet.jsonはatomic更新。
  Macは「保存ペットを読み込む」からJSONを選び、既存ペットを履歴に残して表示する。
  appのversionフォルダ、TEMP、ソースcheckoutとは分ける。旧Mac/Pomegranateデータを移動しない。
- 画像は4K以下PNG、64MiB以下。基本作成にログイン・外部モデル・画像uploadなし。
- テンプレートはAI検出ではない。Macのレイヤー/深度、Quality、隠面補修、精密瞬きと同等ではない。
- 開発用pet-rigはPNGと任意の補正マーカーJSONから保存データを生成し、pet-snapshotへ渡して
  両OSの同一入力/姿勢を比較する。利用者の起動・導入にはこのコマンドを要求しない。
- 単体検査/コンパイル確認と、Windowsでの画面/再起動/実画像確認を分けて記録する。

## 実施順と受入条件

1. **現状調査と試作:** 上の機能差を把握し、Windows単体の画像→補正→保存→再起動を作る。
   次は実画像、複数姿勢、透過・opaque画像で試作の限界を測る。
2. **全機能と梱包:** Quality/depth/推定器、入力、会話、agent承認、音声、GIF、全設定を順に接続。
   同時にDLL/リソース/モデルライセンスを固定し、GUI downloaderを作る。
3. **導入の完成:** 初回案内→直接起動。追加helper/modelは画面から導入/起動/停止。
   更新は同volumeのstageを検証して切替。失敗時は旧版へ戻り、データの破壊的移行をしない。
   修復と削除は対象を表示し、ペット/設定の削除は別の明示選択にする。
4. **配布候補:** Developer ID/公証、Windows署名、完全DLL集合とライセンスを確認。
   開発環境のない両OSで全機能・相互データ・ネット取得失敗/破損/取消/更新失敗を検証する。

各項目は「未実装 / 実装済み未検証 / 自動検査済み / 両OS実機済み」を分ける。
全項目が両OS実機済みで、導入条件も満たされるまで完成扱いにしない。
実機や署名が不足しても他項目を進める。push/Release公開前はdocs/PUBLISHING.mdに従って声をかける。

## 配布場所（ユーザー確定）

入口は **GitHub Releases**。app本体とGUI downloaderを置く。追加モデルは画面から導入する。
大きなモデルの実ファイル置場はモデルの配布権/元の提供元/ファイルサイズに応じて別途決める。
GitHubの[現行制限](https://docs.github.com/en/repositories/releasing-projects-on-github/about-releases)は
1 asset 2GiB未満。取得先URLだけに信頼を置かず、署名・ハッシュ・固定版・ライセンスを記録する。
OSのquarantine/Mark of the Webを適切に扱い、警告が出ないことを導入上の利点にしない。
基本ペットの導入をアカウント認証や大モデルの取得で止めない。

## 第1段階の検査記録

- 作業ブランチ: `codex/desktop-parity`。初期実装 `5626611`。
- [Windows/Mac CI](https://github.com/Methurcoder/Castor/actions/runs/38525296116):
  両OSで14件のarchive/描画/PNG/マーカー/保存保持テスト成功。Windows Win32 Release EXEビルド成功。
  配布検査はMac11件、Windows8件（Mac専用3件skip）。
- Mac appのarm64/x86_64 Release build成功。署名無効のコンパイル確認で、配布候補ではない。
- 1024×1536の実イラストを手動マーカーでリグ化し、Mac上の共通CPU rendererで
  260×340の91フレームを0.85秒（平均9.4ms/frame）で描画した。単一のMac/画像/解像度の測定。
  原画像や教師ラベルを変更せず、データセット/出力フレームをGitへ追加していない。
- Windowsの選択画面・マーカードラッグ・保存・再起動、Macの読込画面と実機相互利用は未確認。
  2Dの精密瞬き/隠面/品質評価は未達。2枚Qualityと残り全機能の実装へ続く。
- Mac appの単体テスト42件成功（UIテストを除外）。Windows互換JSONを実際の
  SavedPetCharacterで受け入れ、不完全/破損ペットを拒否する2件も含む。GUIの相互利用確認ではない。

## Quality再生・深度描画の共通化（第2の実装単位）

- `ArilsPlayer/Model/QualityAvatarArchive.swift`: 既存Quality保存形式をApple非依存へ移動。
  旧キーexpressionConfidenceと表示モード未保存の2D fallbackを保持。Macも同じ型を使う。
- `QualityTurnModel` / `QualityHybridTurnModel` / `QualityRegistrationLayout`もArilsPlayerへ移動。
  MacとWindowsで同じspring、方向制限、保存姿勢上限、首の位置合わせを使う。
- `PetSource.loadAsset`と`PetPlayback`: 正面だけに切り捨てず、Quality優先で両ビューを保持。
  破損Qualityを古いStandardへ暗黙fallbackしない。元ファイル・保存済み履歴を保持する。
  bare Qualityと保存JSONを読み、exportは両ビューと現在の表示モードを保持する。
- Windows右クリックで2D/3D＋横画像を切替。設定変更は現在のセッションだけ。
  保存モードを保持したいときは別のArilsファイルへexportする。全設定UI/永続化は継続課題。
- CPU描画: 共通投影・深度bias、opaque/featherの2pass、透明画素は深度を書かない。
  meshの共有辺を二重合成しないtop-left規則、縦方向clamp-to-zeroを追加。
  ペット全体の透過は描画後に適用し、奥行き判定のthresholdを変えない。
- Macの首登録・自動turn・Qualityアーカイブの既存検査13件成功。
  Mac上のDesktop回帰検査26件成功（前段階14件＋新規12件）。
  Mac arm64/x86_64 Releaseビルド成功。署名無効のコンパイル確認。
- WindowsでのQuality新規作成、横顔のvisibility補正、推定器/隠面補修はまだ未実装。
  CPUのtexture縮小とMetalのfilteringは一致していない。実画像での視覚parity、
  Windows GUI/性能、Intel GPUの描画、相互利用の実機確認は引き続き未検証。
  Macの保存JSON importは使えるが、bare Quality exportのMac import画面は未実装。
  会話/音声/agent/GUI installer等の不足一覧と完了条件は変わらない。

- 深度/alpha描画変更後、同じ1024×1536の単一イラストを260×340で91フレーム描画:
  Macで0.96秒、平均10.5ms/frame。単一Standardリグの計測で、Windows/Quality性能の証明ではない。

### 次のリギング実装の分離点

Qualityの再生から新規作成へ進むには、単一surfaceの試作をMacのパーツ構築へ置き換える。
次の順でApple入力と純粋な構築処理を分離する。

1. Bitmap/FloatPlaneのRGBA・premultiplied alpha・原寸/解析mask契約を共有し、
   CGImage変換はMac adapterへ残す。WindowsのPNG decodeと同じ画素で一致を検査する。
2. FaceLayout/PartPlan、HeadRegionProfile、EyeShape、LayerFactory、HoleFiller、
   BindingSynthesizerを共有する。頭/体/目/口/首パッチと元alphaのcoverage上限を再利用する。
3. Side thickness/depth推定とPoseSweepの安全上限を共有してQualityの新規構築へつなぐ。
   Windowsも隠れた目を可視教師やテンプレートの確定結果へ変換しない。
4. AnalysisContextのCGImage、Vision/CoreMLとLaMa adapterを分離し、Windows推定器を接続。
   ONNX/helperの導入とモデルの配布権確認、GUIでの取得/取消/再試行を同時に整備する。

現在のPNG試作をMac同品質の完成自動リグとして表示しない。既存Mac構築結果を参照し、
同じ入力・mask・顔補正から作ったarchiveと複数姿勢の描画を比較する。

### 最新の確認記録

実装コミット: `fdfb93b`（`codex/desktop-parity`）。
[Windows/Mac CI 38530641208](https://github.com/Methurcoder/Castor/actions/runs/38530641208)は両job成功。
両OSのDesktop検査26件、Windows Swift 6.4.1 x64のWin32 Releaseビルドが成功した。
配布検査はMac11件、Windows8件（Mac専用3件は明示skip）。
Macアプリの単体検査も42件成功、失敗/skipなし。UIテストは対象外。
Macのarm64/x86_64 Releaseビルドは署名無効のコンパイル確認。
source書出し301ファイルとScreenshotAnswer公開対象24ファイルの既知パターン検査成功。
包括的セキュリティ監査やGUI/実画像のQuality検証とは扱わない。
Windows GUIと同品質の新規Quality構築、会話・入力・音声・全設定・GUI導入は継続課題。
mainへのmerge、配布Releaseの作成は行っていない。

## 一括実装の進行記録: 共通リギングとWindows作成/GIF

ArilsRigPortableに既存MacのOS非依存処理を移動し、RigLayerBuilderをMac AutoRigPipelineと
Windows LayeredRiggingの両方から利用する。単一surface試作から、頭/体/目/口/首のレイヤー、
非MLの隠面補修、Quality厚み/深度と安全な姿勢上限の構築へ進んだ。
Windowsの1枚/2枚選択、被写体選択、顔補正、進行表示/取消、互換JSON保存をnative UIへ接続。
基本経路にモデル/Python/ログインは不要。イラストheuristicとalpha/単色背景fallbackを使い、
確認は必須。WindowsのVision/CoreML代替、LaMa、任意の画像での推定品質は未達。

GIFは独自のローカルmedian-cut/LZW encoderで作成。384/320px 20fps、256px 10fpsの順に
5MB以内へ調整し、量子化済みの実GIF色でnative animation previewを表示する。
保存したGIFをXへ手動添付する案内を保存前/保存後に表示し、Web Intentだけを開く。
MacのImageIOで乱数256色・2フレームのLZW幅拡張/辞書clear/色表を復号検査した。
Mac上でDesktop32件、既存Arils270件の検査成功。Universal Releaseコンパイルも成功。
WindowsのGUI/画像品質・動作速度、残りの会話/音声/設定/導入は引き続き未完成・未検証。
