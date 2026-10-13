# Arils

画像1枚から、自然に動く2Dキャラクターを生成する macOS 向けエンジン。
Castor 本体から独立した Swift Package で、`import Arils` だけで使えます。

名前はザクロの果粒(aril)から。

```
画像1枚 ──► 自動Rigging ──► リグ文書+レイヤー ──► モーション生成 ──► Metal描画
            (AutoRigPipeline)  (AvatarRig/Archive)   (MotionController)   (AvatarMetalView)
```

## できること

- **自動Rigging** — 透過PNG、Vision による被写体切り抜き、または画像端からの均一背景色分離から、体・頭・両目・口のレイヤーを自動抽出。目や口の裏の肌、頭の移動元は元画像から拡散・襟色で補完する。手動/自動の頭矩形は最終カットではなく探索範囲として使い、両目・口と被写体シルエットから曲線状の頭/体所有マスクへ補正する。首傾げは頭だけでなく胴体へ小さく分配し、首元の相対変形を抑える。被写体を信頼できる形で分離できない場合は、画像全体を誤ってリギングせず失敗とする。
- **髪の縁まで抜ける切り抜き(任意の ML)** — 不透明な画像では、Vision が「どれが被写体か」を、アニメキャラ用の切り抜きモデル(ISNet、`skytnt/anime-seg`、Apache 2.0)が「輪郭」を受け持つ。Vision の丸い塊が抱え込む毛束の間の背景(白い髪の周りの白いもや)を抜き、モデル単体が拾う机・椅子・影は Vision の範囲外として捨てる。モデルが無い環境では、Vision の境界を画像の色で精細化する従来の経路に戻る。
- **目の形の切り抜き(任意の ML)** — アニメ顔ランドマークモデルの瞼の6点から目の輪郭を作り、目のレイヤーと瞬き時の裏の肌塗りを矩形ではなく目の形にする。目にかかる前髪はそのまま残る。モデルが無ければ従来の矩形。
- **自然な Idle Motion** — 呼吸(周期・深さがゆらぐ)、多オクターブノイズによる姿勢ドリフト、瞬き(対数正規の間隔・半瞬き・二連瞬き)。単純な周期運動は一切使わない。
- **会話の態度と「不器用さ」** — `behavior`(idle / listening / thinking / speaking / surprised)を姿勢・視線戦略・瞬き頻度・ジェスチャーへ変換する(`AttitudeLayer`)。変化は必ず「ためらい」を経る: 反応遅延、途中で止まる言い淀み、慌てた目の泳ぎ、不足減衰の行き過ぎ。驚きだけは反射的に速くビクッと跳ねる。
- **個性(`MotionPersonality`)** — ためらい・反応の速さ・揺れの大きさ・瞬き頻度・そわそわ度・内気さ・表現の大きさを数値で持ち、全レイヤーが共有する。プリセット: standard / shy / lively / calm / clumsy。
- **視線追尾** — 弾道的なサッカード(振幅で持続が伸びる主系列・最小ジャーク軌道・大振幅はわずかにアンダーシュート)、固視中のドリフトとマイクロサッカード、目が先に動き頭が追いつくと目が戻る協調(VOR)、下を見るとまぶたが下がる連動。動かないカーソルには飽き、たまに目を逸らし(内気なほど多い)、考え中は上や横を見る。大きな視線移動では瞬きが誘発される。
- **会話のしぐさ** — 話し始めの吸気と視線外し、句の切れ目のうなずき・瞬き・息継ぎ、強勢でのビート、話し中の頭の揺れ、話し終わりに視線を戻す(`SpeechGestureLayer`)。聞き手のときは、ユーザーの声の切れ目に相づちのうなずき(`listenerVoiceLevel`)。
- **口同期** — 音量(RMS→dB)で開きを、スペクトル傾斜(高域/低域バランス)で母音形状(い/え ↔ お/う)を推定。ライブ経路は発話音量に追従する自動ゲインで小声でも口が動く。TTS には `LipSyncTimeline`(再生前に全体を解析: 中心窓で遅延なし、クリップ単位の正規化、閉鎖子音で口を閉じる、音より少し先行)を再生クロックで引く経路が最も正確。音声がなければ音節風のプロシージャル口パクにフォールバック。
- **自発的な小さな行動** — 一瞥、予備動作つきの重心移動、ため息、退屈するとあくび・うたた寝(話しかけるとビクッと起きる)(`MicroActionLayer`)。腕の関節はリグに無いため、伸び・髪を触るなど腕のしぐさは扱わない。
- **頭を撫でる** — 頭部をドラッグすると、押されて沈み、手の方向に傾き、髪が揺れ、目が細まる。離すと少し弾んで戻る(減衰不足バネ)。
- **自発的なくしゃみ** — 数分に一度(既定 平均240秒、`Configuration.sneezeInterval` で調整・`.infinity` で無効化)、誰も操作していなくても「息を吸って目を閉じ→くしゅんっ(頭が前に振れ髪がばさっ)→余韻」の3段モーションが起こる。`engine.triggerSneeze()` で手動発火も可能。
- **擬似3D** — 首振り(angleX/Y)はパーツ内部だけを放物面状に変位させる `perspectiveShift` で表現。輪郭は動かず内部の顔だけが動くため、「平面が滑っている」ようには見えない。
- **軽量** — 頂点変形は CPU(数百頂点)、描画は Metal で1パス。ウインドウが完全に隠れると描画停止し、Qualityの正面/側面viewもalphaが完全に0なら個別に停止する。リギングは1回だけ実行し、`AvatarArchive` で保存・復元。
- **Arils-2D-Quality(2枚画像モード)** — 正面+横向きの2枚を独立にリギングし、`viewTurn`(-1〜1)で正面↔横をクロスフェード。首位置・頭サイズの位置合わせは自動(`QualityViewRegistration`)。横画像は宣言された向きにのみ使い、非対応側は左右反転せず正面を維持する。保存形式は `QualityAvatarArchive`(従来の1枚 `AvatarArchive` と完全互換共存)。Quality は**視点差分**(正面⇄横)のみで、**表情差分**(通常⇄笑顔など)を切り替える機構は未実装(表情バリアントは将来機能)。
- **Quality 2.5D+深度** — 横シルエットの高さ別厚み制約を正面メッシュへ転写したv2リグは、小角度で実3Dヨー/ピッチ回転と透視視差を使う。新規リグの`FaceAwareRibbonDepthEstimator`は頭部メッシュを24×24へ高密度化し、頭頂・顎を含む全周輪郭をZ=0の薄いリボンとして固定する。顔ランドマークから浅い顔板を作り、色と位置が一致する前髪候補だけに小さな局所Zを追加する。長髪やヴェールの幅を顔の奥行きと誤認しないよう、正面の頭幅と両目間隔で顔層の深度を制限する。意味的な顔深度と行楕円ベースラインは`HeadRegionProfile.ownershipWeight`でブレンドし、256px深度面でもフェザーが最低2セル残るよう原寸比で調整して、頭矩形の直線辺にZ段差を作らない。左右回転は顔の下半分にわたって首(ピボット行)へ滑らかに減衰し、Z=0輪郭の投影短縮だけを相殺して静止時の頭幅を保つ一方、深度差による内部視差は残す。上下回転は髪を含む横幅由来の深度ではなく、制限した一貫する浅い顔プレートとして頭部全体を動かす。実際の口と首の位置から下端減衰帯を決めるため、目・口の縦間隔と頭頂輪郭がばらばらに動きにくい。どちらも頭と体の継ぎ目は開かない。通常の上下角は最大±6度。大角度では横画像へ滑らかにクロスフェードし、横画像には上下形状の根拠がないためピッチは同時に中立へ減衰する。旧アーカイブは従来の2D表示を既定として維持する。
- **自動振り向き** — 既定で `viewTurn`(左右) / `viewPitch`(上下) は視線ターゲット(ポインタ/外部ターゲット)に連動し、バネで滑らかに向きを変え、中央へ戻る・消えると正面へ戻る(デッドゾーン付き、`QualityTurnModel`)。`automaticTurn = false` で両軸を手動制御に切替可能。
- **同一キャラ判定** — 2枚が同一人物らしいか(色ヒストグラム・シルエット面積・頭幅の類似度)、顔(目・口)をはっきり読み取れているか(`faceReadabilityConfidence`。表情差分の評価ではない)を保守的なヒューリスティックで評価し、日本語の警告文付き `QualityPairAssessment` を返す(断定せず、確認はホスト側に委ねる)。
- **複数被写体の選択** — 1枚に複数キャラが写っている場合、`subjectCandidates(from:)` が連結成分ごとの候補を返し、選んだ1体だけをリギングできる(接触・重なりは無理に分離しない)。
- **M0姿勢検証** — CPUのBuild時検査とMetal描画は`RenderProjectionContract`の透視投影を共有する。メッシュ反転・非有限頂点・未知画素露出は硬い安全性、rest姿勢との穴/ゴースト差は品質レビューとして別々に記録する。`swift run arils-corpus --pilot`で同梱`Arils_Dataset`の小規模回帰baselineを再生できる(外部hold-out精度の証明ではない)。

## 使い方

```swift
import Arils

// 初回: 画像から自動リギング(重いのは1回だけ)
let engine = try await CharacterEngine.make(image: cgImage)
try engine.archiveData().write(to: archiveURL)   // 保存しておく

// 2回目以降: アーカイブから即復元
let engine = try CharacterEngine(archiveData: try Data(contentsOf: archiveURL))

// 表示(AppKit)
window.contentView = engine.makeView()
// 表示(SwiftUI)
AvatarView(engine: engine)

// 外部入力
engine.isSpeaking = true                          // 口パク開始(音声なしでも動く)
engine.pushSpeechSamples(pcm, sampleRate: 24_000) // TTS音声を流すと本物の口同期
engine.pushSpeechLevel(level)                     // メーター値しか無い場合
engine.externalGazeTarget = SIMD2(0.3, 0.1)       // カメラの顔位置などを視線目標に
engine.energy = 0.8                               // 元気さ(モーション振幅・呼吸速度)
engine.behavior = .thinking                       // 会話の態度(ためらいつつ姿勢・視線が変わる)
engine.hesitation = 0.8                           // 自信のない返答など、一時的な不器用さ
engine.listenerVoiceLevel = micLevel              // 聞いている間のユーザーの声 → 相づち

// TTS は再生前に解析し、プレイヤーの時計で口を引くのが最も正確
let timeline = engine.makeSpeechTimeline(samples: pcm, sampleRate: 24_000)
engine.playSpeechTimeline(timeline) { player.isPlaying ? player.currentTime + outputLatency : nil }

// 個性はエンジン生成時に
let shy = try await CharacterEngine.make(image: cgImage, configuration: .init(personality: .shy))
```

視線(ビュー内ホバー)と撫で(頭部ドラッグ)はビューが自動処理します。

### 2枚画像(Quality)の使い方

```swift
let pipeline = AutoRigPipeline()

// 事前判定(任意): 同一キャラらしいか・顔をはっきり読み取れているかの警告を得る
let assessment = try await pipeline.assessQualityPair(
    front: frontImage, side: sideImage, sideFileName: "side.png"
)
// assessment.warnings をユーザーへ提示して確認を取る

// ビルド(正面+横向き。sideDirection は横画像が向いている方向)
let archive = try await pipeline.makeQualityArchive(
    front: frontImage, side: sideImage,
    sideDirection: .right, sideFileName: "side.png"
)
let engine = try QualityCharacterEngine(archive: archive)
// 既定では視線ターゲットに連動して自動で振り向く。手動制御する場合:
engine.automaticTurn = false
engine.viewTurn = 0.6   // -1...1、宣言された側だけ横顔へクロスフェード
engine.viewPitch = 0.4  // -1...1→最大±6°、正で上(横画像へのブレンド中は中立へ減衰)
QualityAvatarView(engine: engine)  // SwiftUI
```

複数キャラが写った画像は `pipeline.subjectCandidates(from:)` → `makeAvatar(from:selecting:)` で1体を選んでリギングできます。

### デモ

```sh
swift run arils-demo
```

ウインドウにキャラクター画像をドロップ → ホバーで視線、頭をドラッグで撫で、
Speak トグルでプロシージャル口パク、Play audio… で音声ファイル同期。

### ビルドとテスト

```sh
cd Arils
swift build
swift test    # 約270テスト(ヘッドレス、GUI不要)
```

### 任意の ML モデル(リポジトリには含めない)

顔ランドマークと切り抜きのモデルは、公開されている重みから手元で Core ML に書き出します(PyTorch・coremltools が必要)。無くてもビルド・実行でき、それぞれ従来の推定に戻ります。

```sh
python3 Arils/Tools/AnimeFaceModels/export_coreml.py          # 顔検出+28点ランドマーク(MIT)
python3 Arils/Tools/AnimeSegmentationModel/export_coreml.py   # アニメキャラ切り抜き ISNet(Apache 2.0)
```

書き出し先はそれぞれ `Sources/ArilsFaceInference/Resources/AnimeFaceModels/` と `Sources/ArilsSubjectInference/Resources/AnimeSegmentationModel/`。出典とライセンスは [THIRD_PARTY_NOTICES.md](../THIRD_PARTY_NOTICES.md)。

## アーキテクチャ

5つのモジュールに分かれ、依存は一方向のみ:

```
                 ┌─────────────┐
                 │  ArilsCore   │  数学・メッシュ・パラメータ語彙(依存なし)
                 └──────┬──────┘
        ┌───────────┼───────────────┐
   ┌────┴────┐ ┌────┴─────┐ ┌───────┴───────┐
   │ ArilsRig │ │ArilsMotion│ │  (ArilsRender) │  RenderはRigにも依存
   └────┬────┘ └────┬─────┘ └───────┬───────┘
        └───────────┼───────────────┘
                 ┌──┴───┐
                 │ Arils │  CharacterEngine(統合ファサード)
                 └──────┘
```

### 各モジュールの責務

| モジュール | 責務 | 主要型 |
|---|---|---|
| `ArilsCore` | 決定論的乱数・ノイズ・バネ・エンベロープ、グリッドメッシュ、パラメータ定義と合成規則 | `SeededRandom` `ValueNoise1D` `SpringDamper` `DeformableMesh` `ParameterID` `ParameterValues` |
| `ArilsRig` | リグ文書(Codable)、変形評価、自動Riggingパイプライン | `AvatarRig` `DeformationOp` `DeformationEvaluator` `AutoRigPipeline` `AvatarArchive` |
| `ArilsMotion` | パラメータを毎フレーム生成するモーション層と髪物理、音声解析、動きの評価指標 | `MotionController` `MotionInputs` `MotionPersonality` 各`MotionLayer` `SwaySimulator` `LipSyncAnalyzer` `LipSyncTimeline` `MotionMetrics` |
| `ArilsRender` | Metal メッシュ描画と AppKit ビュー(マウス追跡・省電力) | `MetalAvatarRenderer` `AvatarMetalView` `AvatarRendering` |
| `Arils` | 全体の配線と1オブジェクトAPI | `CharacterEngine` `AvatarView` |

### データの流れ(毎フレーム)

1. `AvatarMetalView` がフレーム毎に `CharacterEngine.parameters(at:)` を呼ぶ
2. `MotionController` が各レイヤー(呼吸→姿勢ドリフト→態度→口→会話しぐさ→瞬き→視線→顔追跡→撫で→くしゃみ→小さな行動→髪物理)を実行し、`[ParameterID: Float]` を返す。レイヤー間の連動(視線移動→瞬き、句の切れ目→うなずき、驚き→髪)は内部の `MotionCues` を経由する
3. `DeformationEvaluator` がリグの `DeformationOp` 列を解釈して頂点座標を計算(純関数)
4. `MetalAvatarRenderer` が頂点をアップロードし、premultiplied alpha で奥から描画

モーション値はすべて「シード+時刻の決定論的関数(+状態バネ)」なので、同じシードと入力列は常に同じアニメーションを再生し、テストで回帰検証できます。イベント(瞬き・サッカード・しぐさ)は予定時刻から評価するため、30/60/120fps でほぼ同じ動きになります。

### 動きの評価(`arils-motion-eval`)

`swift run -c release arils-motion-eval --audio a.wav --json out.json` で、決定的なシナリオ群を `MotionController` に流し、`MotionMetrics` の数値(瞬き頻度と間隔のばらつき・半瞬き率、サッカードの持続と視線誘発瞬き、2秒の体の動きから会話状態を当てる分類精度、状態遷移の遅延と行き過ぎ、相づちのタイミング、小さな行動の頻度、個性ごとの差、fps 不変性、実音声での口同期の遅延・相関・無音時の口閉じ・音節追従・小声への追従)を表で出します。音声は `say -v Kyoko -o a.wav --data-format=LEF32@24000 "…"` などで作れ、画像コーパス同様 Git には入れません。「生きている感じ」の正解ではなく、動きが機械的・停止・過剰・ずれに傾いたことを検出する回帰の物差しです。

### パラメータ(モーションとリグの契約)

Live2D 準拠の語彙(`angleX/Y/Z`, `eyeLeftOpen`, `mouthOpen`, `mouthForm`, `breath`,
`hairFrontSway`, `touchSquash` など、`StandardParameters.all` 参照)。モーション側は
リグの中身を知らず、リグ側はモーションの発生源を知りません。片方だけの差し替えが可能です。

### 交換できる境界(すべて protocol / データ駆動)

| 差し替えたいもの | 境界 |
|---|---|
| リギングアルゴリズム全体 | `RiggingPipeline` |
| 被写体切り抜き | `SubjectMaskProviding`(アルファ→Vision→画像端からの均一背景色分離の順に試行。全面マスクは既定で使用しない)。`SubjectMaskSet`はヒューリスティック用の既定256pxマスクと切り出し用の原寸マスクを分離する。透過PNGは元alpha、Visionは原寸出力を保持し、均一背景フォールバックだけは原画像の色エッジをguideにしたjoint-bilateralアップサンプルを使う。`PreparedRiggingInput`を候補選択→顔確認→Buildで持ち回ると、デコード・縮小・セグメンテーションを再実行しない |
| 顔検出 | `FaceLayoutEstimating`(アニメ用ヒューリスティック主経路+Vision補助を `CompositeFaceEstimator` が調停)。推定器固有のconfidenceは`calibratedConfidence`で調停用の共通尺度へ写像し、さらに後段推定器には既定1.2倍の交代マージンを課すため、Visionの観測確率がアニメ経路を僅差で上書きしない。アニメ経路は目ペア確定後に目間隔から顔特徴スケールを1回再推定し、口・目の局所窓を髪幅から切り離す。口候補は色を弱い補助に留め、長い水平稜線を減点する。被写体解析は既定256px、顔特徴は既定768pxで再解析し、`FaceLayoutReviewer`が独立した幾何検査と確認理由を返す。`faceLayoutProposal`→ホスト側で確認/補正→`makeAvatar(...faceLayout:)`の経路で手動確定値を注入できる。確定した頭矩形はROIとして扱い、`HeadRegionProfile`が顔ランドマークと被写体マスクから曲線状のソフト所有境界を作る |
| インペイント | 目・口は `HoleFiller`(拡散法)。頭の背面は低周波パレット補修を常設し、`OcclusionInpaintingProviding`を注入すると首元と回転時に露出しうる側面だけを任意のMLバックエンドで上書きできる。側面範囲は固定幅ではなく、`SupportedHeadPose`の最大角・顔深度上限・透視短縮から求めた最大露出量に安全余白を加えて決め、マスク境界が最大姿勢でも頭の下に残る。失敗時は同じ範囲の常設補修へ戻る |
| 変形の種類 | `DeformationOp`(データなので enum ケース追加+評価器対応のみ) |
| 描画バックエンド | `AvatarRendering`(現在は Metal) |
| モーション | `MotionLayer` の追加・削除 |

### Live2D 級への拡張路線

- **キーフォーム変形**: `DeformationOp.warpKeyform(parameterX:parameterY:keys:)` は実装済み。口は `mouthOpen × mouthForm` の5キーを2次元補間し、手続き的変形と共存する
- **手動リグ編集**: `AvatarRig` は Codable なので、エディタは JSON を吐くだけでよい
- **パーツ追加**(前髪・後髪の独立レイヤー、腕): `PartKind` は既に予約済み。v1 の自動パイプラインは前髪=頭レイヤー内ワープ、後髪=体側面帯ワープで近似(切り出しの継ぎ目を避けるため)
- **アトラス化・GPU頂点変形**: パーツ数が増えたら `MetalAvatarRenderer` 内部だけで完結する最適化

## Castor への組み込み(組み込み済み)

app ターゲットにローカルパッケージとしてリンク済み。橋渡しは `Castor/Castor/Aril Bridge/` にあり:

- **リギング画面**: 「Arils」ボタンで自動リギング+プレビュー(Standard)。横顔を追加インポートすると判定シートを経て、側面側の頭・目・口マーカーも確認/補正してから Quality プレビューへ進む。複数被写体の候補選択シートあり。前面・側面ごとの`PreparedRiggingInput`を候補選択・顔確認・判定・Buildの間だけ保持して同じ解析結果を再利用し、画像世代IDで差し替え中の古い非同期結果を拒否する。Build成功後は原寸画像とFloatマスクを保持し続けないようトークンを解放する。Save Pet は構築済みのアーカイブ(Standard の `arilsArchiveData`、Quality の `qualityArchiveData`)を同梱する
- **フローティングペット**: Quality アーカイブ持ちは `QualityArilsPetView`、Standard のみは `ArilsPetView` が描画(Quality 優先)。どちらも `PetVoiceConversation.isSpeaking` / `speechPlaybackEnergy` を口同期へ、タップを `voice.toggle()` へ中継する。カメラ許可済みで顔が見つかった間だけ、`TrilobiteEngine` の顔位置とVisionランドマーク由来のroll/yaw/pitch・目/口比率も `FaceTrackingLayer` へ渡す。追跡は既存モーションを置き換えず、`CharacterEngine.faceTrackingBlend` で調整できる加算バイアス
- 従来の手動リグは詳細設定の fallback として残る。Castor に公式キャラクターと図形 Prototype は含まない

未接続の入力(今後): `HesitateCore` の状態 → `engine.energy` の状態連動。

## 3D化ロードマップ

2枚(正面+横向き)から奥行きを推定する Stage A(M1〜M4)は実装済み。設計、実装状況、未実装の Stage B/C は [ROADMAP_3D.md](ROADMAP_3D.md) を参照。

## 姿勢一般化ロードマップ

立ち絵前提を解き、浮遊・座り・バストアップなど一般的な姿勢のイラストへ対応する計画(顔優先推定・`PoseTraits`・手動補正UI)は [ROADMAP_POSE.md](ROADMAP_POSE.md) を参照。未実装。

## 制限(v1)

- 正面〜軽い斜め向きの一人立ち絵を想定(目・口は特徴密度のピーク探索で、少し向きのある絵でも顔中心のずれに追従する)。極端な斜め向き・複数人は未対応
- 浮遊・座りポーズで髪や衣が顔より大きく画面を流れる絵は、頭部矩形が髪に引きずられて目・口の検出が外れやすい(顔優先の推定経路は将来課題)。半透明の薄衣は不透明として切り抜かれる(アルファマッティング未実装)
- 透過背景を推奨。均一色の不透明背景は画像端から自動分離するが、写真・複雑な背景で被写体を分離できない場合は、画像全体を誤ってリギングせず失敗として扱う
- 首のくびれが見えず、目・口のコントラストも弱いバストアップ絵は、誤った顔パーツを作る代わりに顔検出失敗として扱う場合がある
- 前髪・後髪は専用レイヤーではなくワープ近似(継ぎ目のない揺れを優先)
- Face-aware Ribbonの前髪Zは色差と顔内位置による保守的な局所手掛かりであり、髪と肌が同色、顔が隠れている、半透明髪、複雑な飾りでは0または誤推定になる。独立した髪面ではないため、顔をまたぐ完全な前後反転や新しい隠面の生成は行わない
- 正面/側面の切替は密な画素対応を持たないalphaクロスフェードである。2枚の輪郭・表情・照明が大きく違う場合、中間域で二重輪郭が残る。対応のない2枚だけから安全なワープを作ると顔を破綻させるため、今回の方式では未解決条件として扱う
- 腕は体メッシュの側面ワープによる微動のみ(1枚絵からの腕分離は将来課題)
- 口の開閉は自動生成した5つの2次元キーフォームで補間し、開口時の暗部も生成する。ただし歯・舌・母音別の描き分けは入力画像に根拠がないため未対応
- 表情バリアント(通常⇄笑顔など)未対応。Quality の2枚は視点(正面⇄横)専用で、表情の切替は行わない


## 画像フレームの書き出し（macOS）

`AvatarImageExporter(archive:)` または `AvatarImageExporter(qualityArchive:)` をMainActor上で作り、
`image(at:size:gaze:viewTurn:)` から `CGImage` を取得できます。専用のモーションengineを使い、
表示中のキャラクターの状態は変更しません。Qualityの表示モード、方向制限、首の登録位置も保持します。
`MetalAvatarRenderer.renderImage(parameters:size:)` はライブ描画と同じ変形・投影・depth/alpha passを
オフスクリーンtextureへ描画します。Metal deviceが必要です。画面キャプチャは使いません。
GIFのエンコードや投稿用UIはホスト（Castor）の責務です。
