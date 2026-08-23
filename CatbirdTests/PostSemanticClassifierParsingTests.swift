import XCTest
@testable import Catbird

#if canImport(FoundationModels)
final class PostSemanticClassifierParsingTests: XCTestCase {
    @available(iOS 26.0, macOS 26.0, *)
    func testParsesBoundedClassifierOutput() throws {
        let features = try SystemPostSemanticClassifier.parse(
            "topics=artificial intelligence,swift;tones=anger,hostility;behaviors=activeConflict"
        )

        XCTAssertEqual(features.topics, ["artificial intelligence", "swift"])
        XCTAssertEqual(features.tones, [.anger, .hostility])
        XCTAssertEqual(features.behaviors, [.activeConflict])
    }

    @available(iOS 26.0, macOS 26.0, *)
    func testRejectsEmptyOrMalformedClassifierOutput() {
        XCTAssertThrowsError(try SystemPostSemanticClassifier.parse("here is my analysis"))
    }
}
#endif
