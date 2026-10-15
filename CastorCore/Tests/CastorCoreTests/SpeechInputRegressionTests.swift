import Foundation
import Testing
@testable import CastorCore

struct SpeechInputRegressionTests {
    @Test func diagnosticsAreSingleLineAndBounded() {
        var value = SpeechInputDiagnostics()
        value.backend = "dictation"
        value.locale = "ja-JP\ninvalid/path"
        value.asset = "installed"
        value.buffers = 42
        value.delivered = 41
        value.peak = .infinity
        #expect(!value.code.contains("\n"))
        #expect(!value.code.contains("/"))
        #expect(value.code.contains("buffers=42 sent=41"))
        #expect(value.code.contains("peak=0"))
    }
    @Test func japaneseApplicationErrorKeepsDiagnostic() {
        let diagnostic = "\n[SI1 backend=dictation end=no_result]"
        let text = SpeechInputMessages.localized("I couldn't hear that. Click to try again." + diagnostic, language: .japanese)
        #expect(text.hasPrefix("音声を文字にできませんでした。"))
        #expect(text.hasSuffix(diagnostic))
    }
    @Test func unknownProviderContentIsNeverTranslated() {
        let content = "Provider reply: I couldn't hear that. Click to try again."
        #expect(SpeechInputMessages.localized(content, language: .japanese) == content)
        #expect(SpeechInputMessages.localized(content, language: .english) == content)
    }
    @Test func noAmbientObserverDoesNotBlockRecognition() async {
        await SpeechCaptureHandoff().waitForRelease()
    }
    @Test func acknowledgementBeforeWaitIsRetained() async {
        let handoff = SpeechCaptureHandoff()
        let first = handoff.reserve(), second = handoff.reserve()
        first(); second()
        await handoff.waitForRelease()
    }
    @Test func allCaptureQueuesMustReleaseBeforeRecognition() async throws {
        let handoff = SpeechCaptureHandoff()
        let first = handoff.reserve(), second = handoff.reserve()
        let released = ReleasedCaptureQueues()
        let releasing = Task {
            try await Task.sleep(for: .milliseconds(15))
            released.increment(); first()
            try await Task.sleep(for: .milliseconds(15))
            released.increment(); second()
        }
        await handoff.waitForRelease()
        #expect(released.count == 2)
        try await releasing.value
    }
}

private nonisolated final class ReleasedCaptureQueues: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var count: Int { lock.withLock { value } }
    func increment() { lock.withLock { value += 1 } }
}
