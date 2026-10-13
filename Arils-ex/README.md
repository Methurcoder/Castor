# Arils-ex

Arils-ex は、既存の `Arils` を変更せずに使う実験的な3ビュー拡張です。正面・左向き・右向きの3枚から、Live2Dに近い「少ない手直しで動く2Dキャラクター」を作るための土台を分離して検証します。

## 現在できること（v0.4 cross-view articulation）

1. 正面・左向き・右向きの3画像を読み込む。
2. macOS Vision の人体姿勢検出で、頭・首・肩・ひじ・手首・腰・ひざ・足首をローカル推定する。
3. イラストで Vision が失敗した点を、透過シルエットに合わせた低信頼度テンプレートで補う。
4. 画像上の点をクリック・ドラッグして、人が誤検出だけを修正する。
5. `JointVisibility` は関節の投影位置と、そのビューに実際の画素があるかを分離する。`visible / occluded / outOfFrame / unknown` と、位置・可視性それぞれの根拠を保存する。
6. `OcclusionTopology` は側面の非対称なVision証拠から完全遮蔽腕を保守的に推定する。判断できない場合は`unknown`のまま停止し、テンプレート座標を可視テクスチャとして確定しない。
7. 3枚の欠損点を相互補完するが、他ビューから改善するのは位置だけで、対象ビューの可視性は上書きしない。
8. 各画像を既存 Arils で個別に自動リギングし、関節メタデータと一緒に `ThreeViewRigArchive` へ保存する。
9. 首と腰を使って3ビューを整列し、`viewTurn` が -1〜1 の間で左・正面・右画像をクロスフェードする。左右画像を暗黙に反転しない。
10. `PoseAdmission(.bustUp)` は原寸被写体マスクで可視関節を検査する。側面では遮蔽腕を許すが、少なくとも1本の腕と首の位置根拠を必須とする。非透過PNGの全面alphaを被写体根拠にしない。
11. `ArticulationCompiler` はそのビューで両端が見える腕パーツだけを生成する。遮蔽パーツは`omittedParts`に理由を保存し、髪や胴体を隠れ腕として切り出さない。可視パーツに対してのみPNG、6×10メッシュ、2ボーンLBS、隠面補修、`RigIntegrityMetrics`ゲートを適用する。ゲートは`accepted / requiresReview / rejected`の三値で、穴/ゴースト差だけの場合はBuildを破棄せずレビュー必須として保存する。
12. `ArticulationEvaluator` で肩・ひじ回転後の各パーツ頂点を純粋ロジックとして評価できる。
13. `CrossViewArticulationAnalyzer` は正面の上腕・前腕ごとに、反転シルエット、色分布、骨長、切り出し面積から左右対称度を計測する。側面の可視腕は正面のどちらの腕に対応するかを2仮説で比較し、対称で区別不能な場合は関節ラベルを保持した低信頼度のまま保存する。
14. ランタイムは元画像の腕領域をアンダーペイントパッチで隠し、コンパイル済み腕メッシュをMetalで独立描画する。側面にない腕は正面テクスチャを中間角まで保ち、胴体の後ろへ移して真横までに消す。側面画像から隠れ腕を生成・誤切り出ししない。
15. `ThreeViewCharacterEngine.articulationPoseParameters` に肩・ひじ角を渡せる。デモは腕曲げスライダーで、パーツが元画像から分離されていることを確認できる。

画像や関節情報を外部サービスへ送る処理はありません。

## 試す

```sh
cd Arils-ex
swift run arils-ex-demo
```

テスト:

```sh
cd Arils-ex
swift test
```

デモでは3枚を選択し、黄色の点（低信頼度）を中心に確認してから「3ビューをBuild」を押します。右側のスライダーで左→正面→右を確認できます。

関節可視性の単体監査:

```sh
swift run arils-ex-visibility /path/to/right.png right
swift run arils-ex-visibility /path/to/right.png right --occluded left --visible right
```

`--visible`は可視性だけを確定し、テンプレート座標の信頼度を上げません。Visionが失敗した画像は、`JointSelectionEditor`で首と可視腕をドラッグするまでBuildを拒否します。側面で腕が完全に隠れる場合は「腕全体を遮蔽」を指定します。

## APIの最短例

```swift
let inputs = [
    ReferenceImageInput(role: .left, fileName: "left.png", image: leftImage),
    ReferenceImageInput(role: .front, fileName: "front.png", image: frontImage),
    ReferenceImageInput(role: .right, fileName: "right.png", image: rightImage),
]

let builder = ThreeViewRigBuilder()
let proposed = try await builder.proposeJoints(for: inputs)
// JointSelectionEditor で proposed を必要に応じて補正する。

let archive = try await builder.build(from: reviewedInputs)
let engine = try ThreeViewCharacterEngine(archive: archive)
engine.viewTurn = 0.35
```

## 「ほぼ自動Live2D」に対して、まだできないこと

v0.4 で腕メッシュの描画とビュー間可視性はランタイムへ接続しました。ただし、通常の `MotionParameters` から肩・ひじ角を自動生成するモーション変換、脚・胴体の分離、側面に完全に欠けた腕を前へ振り出すための新規テクスチャ生成は未実装です。

次の実装順:

- v0.5: 顔・髪・服・手足の失敗確率を表示し、信頼できる画像では確認操作を省略できる自動承認候補。
- v0.5: `MotionParameters` から肩/ひじパラメータへの保守的な変換。

狙いは「すべてをAIに賭ける」ことではなく、正しい画像ではほぼ自動、外れた画像でも数点・数ストロークの修正で完了することです。

## 既存 Arils との境界

- `Arils-ex` はローカル package dependency として `../Arils` を読みます。
- 既存の Standard / 2D Quality は変更しません。
- 3ビューの実験形式が安定するまで、Castor アプリ本体の保存形式やUIへは統合しません。
- `ThreeViewRigArchive` は独立形式です。通常の `AvatarArchive` / `QualityAvatarArchive` と混同しません。
