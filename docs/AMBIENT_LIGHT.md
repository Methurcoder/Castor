# カーソル光（2026-10-20）

粒子と波は見づらいというユーザーの要望により撤去し、追加前の淡い光の追従へ戻した。

- 光のサイズ・ぼかし・濃さ・追従アニメーションは `eb342c7` の背景に合わせる。
- 波と粒子のCanvas、TimelineView、減衰状態・タスクを削除する。
- カーソル通知を背景へ限定する改善と、変形計算の重複削減は保持する。
- Claudeの顔推定・Windowsマーカー修正も保持する。公開Releaseは行わない。

実装: `Castor/Castor/Visual Language/CastorDesign.swift` と `ContentView.swift`。
