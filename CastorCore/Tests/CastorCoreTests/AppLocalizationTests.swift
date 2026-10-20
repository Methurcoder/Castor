import Foundation
import Testing
@testable import CastorCore

@Test func appCatalogCoversBothDirectionsAndKeepsUnknownValues() {
    for source in CastorAppStrings.sources {
        #expect(!CastorAppStrings.label(source, language: .japanese).isEmpty)
        #expect(!CastorAppStrings.label(source, language: .english).isEmpty)
    }
    #expect(CastorAppStrings.label("Import Image", language: .japanese) == "画像を読み込む")
    #expect(CastorAppStrings.label("うちの子をGIFに", language: .english) == "Make a GIF of Your Character")
    #expect(CastorAppStrings.label("落ち着いた低めの声", language: .english) == "A calm, low voice")
    #expect(CastorAppStrings.label("head", language: .japanese) == "頭")
    #expect(CastorAppStrings.label("head", language: .english) == "Head")
    for value in ["model/example-27b", "Ono_Anna", "User text: 日本語 {value} %@ 95%"] {
        #expect(CastorAppStrings.label(value, language: .english) == value)
        #expect(CastorAppStrings.label(value, language: .japanese) == value)
    }
}

@Test func appDynamicTranslationPreservesInsertedTextAndPercentages() {
    #expect(CastorAppStrings.label("Automatic confidence: 57%", language: .japanese) == "自動推定の信頼度: 57%")
    #expect(CastorAppStrings.label("Codex confidence: 72%", language: .japanese) == "Codex の信頼度: 72%")
    #expect(CastorAppStrings.label("Annaの声を選んでね", language: .english) == "Choose a Voice for Anna")
    let original = "Image drop failed: /tmp/日本語 {value} %@ 100%"
    #expect(CastorAppStrings.label(original, language: .japanese) == "画像をドロップできませんでした: /tmp/日本語 {value} %@ 100%")
    #expect(CastorAppStrings.label("Generating reply for “{value} %@ 90%”", language: .japanese) == "「{value} %@ 90%」への返答を生成しています")
    #expect(CastorAppStrings.label("GIFを作成中… 20%", language: .english) == "Creating GIF… 20%")
}

@Test func appTranslationRetainsReviewAndManualGIFAttachmentBoundaries() {
    let source = "A temporary copy of this image and its current marker coordinates will be sent through the configured localhost Codex connection. The returned proposal will still require your approval."
    let japanese = CastorAppStrings.label(source, language: .japanese)
    #expect(japanese.contains("Codex") && japanese.contains("一時コピー") && japanese.contains("承認が必要"))
    let notice = CastorAppStrings.label("GIFは自動添付されません。保存したGIFを、Xの投稿画面で手動で添付してください。", language: .english)
    #expect(notice.contains("not attached automatically") && notice.contains("Manually attach"))
    let warning = "同一人物ではない可能性のある画像（my-file.png）が混ざっています（可能性: 67%）。"
    #expect(CastorAppStrings.label(warning, language: .english) == "An image (my-file.png) may show a different character (estimated probability: 67%).")
}

@Test func appBuildSummaryRetranslatesWithoutChangingStoredStatus() {
    let status = "Arils preview is ready. LaMa underpaint was applied."
    #expect(CastorAppStrings.label(status, language: .japanese) == "Arilsのプレビューができました。 LaMaによる画像補修を適用しました。")
    #expect(CastorAppStrings.label(status, language: .english) == status)
    let failed = "Arils preview is ready. LaMa was unavailable for 2 view(s), so standard repair was used (timeout)."
    #expect(CastorAppStrings.label(failed, language: .japanese) == "Arilsのプレビューができました。 LaMaを利用できない画像が2枚あり、標準の補修を使いました (timeout)。")
}

@Test func appRiggingFailureGuidanceAndToolNamesRemainExplicit() {
    #expect(CastorAppStrings.label("Allow Read?", language: .japanese) == "Readを許可しますか？")
    let failure = CastorAppStrings.label("Arils rigging failed: timeout. Try Adjust Face, or enable Manual rigging in Settings › General › Advanced.", language: .japanese)
    #expect(failure.contains("timeout") && failure.contains("顔を調整") && failure.contains("手動リギング"))
}
