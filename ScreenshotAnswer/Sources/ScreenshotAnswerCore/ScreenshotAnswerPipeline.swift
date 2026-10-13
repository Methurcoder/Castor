import Foundation

public actor ScreenshotAnswerPipeline {
    private let recognizer: any ScreenshotTextRecognizing
    private let generator: any ScreenshotAnswerGenerating

    public init(
        recognizer: any ScreenshotTextRecognizing = VisionTextRecognizer(),
        generator: any ScreenshotAnswerGenerating
    ) {
        self.recognizer = recognizer
        self.generator = generator
    }

    public func process(
        imageURL: URL,
        model: String,
        options: LMStudioGenerationOptions = LMStudioGenerationOptions()
    ) async throws -> ScreenshotAnswerResult {
        let text: String
        do {
            text = try await recognizer.recognizeText(in: imageURL)
        } catch ScreenshotAnswerError.noTextFound {
            return ScreenshotAnswerResult(
                imageURL: imageURL,
                recognizedText: "",
                answer: "画像から文字を検出できませんでした。画像対応モデルを選び、「これは何？ 内容を説明」を押すと画像そのものを説明できます。",
                model: model,
                offersContentExplanation: true
            )
        }
        let generatedAnswer = try await generator.answer(
            recognizedText: text,
            model: model,
            options: options
        )
        let offersContentExplanation = AnswerResponseClassifier.offersContentExplanation(
            generatedAnswer
        )
        let answer = AnswerResponseClassifier.displayText(generatedAnswer)
        return ScreenshotAnswerResult(
            imageURL: imageURL,
            recognizedText: text,
            answer: answer,
            model: model,
            offersContentExplanation: offersContentExplanation
        )
    }
}
