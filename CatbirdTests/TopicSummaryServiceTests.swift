import XCTest
@testable import Catbird

final class TopicSummaryServiceTests: XCTestCase {
    func testExtractsBetweenOutputTags() {
        let raw = "<output>This is a concise summary.</output>"
        let extracted = TopicSummaryService.extractOneSentence(from: raw)
        XCTAssertEqual(extracted, "This is a concise summary.")
    }

    func testExtractsCaseInsensitiveAndWhitespace() {
        let raw = """
        Here you go:
        <OUTPUT>
            Something happened in the news today.
        </OUTPUT>
        """
        let extracted = TopicSummaryService.extractOneSentence(from: raw)
        XCTAssertEqual(extracted, "Something happened in the news today.")
    }

    func testHandlesCodeFenceWrapping() {
        let raw = """
        ```xml
        <output>Creative one-liner that explains the trend.</output>
        ```
        """
        let extracted = TopicSummaryService.extractOneSentence(from: raw)
        // extractOneSentence prefers tag capture and should ignore fences implicitly
        XCTAssertEqual(extracted, "Creative one-liner that explains the trend.")
    }

    func testSanitizeRemovesResidualTags() {
        let raw = "<output>Extra tags should not leak.</output>"
        let sanitized = TopicSummaryService.sanitizeSummary(raw, topic: "Topic")
        XCTAssertEqual(sanitized, "Extra tags should not leak.")
    }

    func testSanitizeEmitsFallbackWhenEmpty() {
        let sanitized = TopicSummaryService.sanitizeSummary("   \n\n", topic: "Cats")
        XCTAssertEqual(sanitized, "Cats is trending on social media.")
    }
}

