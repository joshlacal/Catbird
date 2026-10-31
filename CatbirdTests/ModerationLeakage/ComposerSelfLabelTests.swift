import Foundation
import Petrel
import Testing

@testable import Catbird

// Self-labels warn other viewers about a post's media. The composer offers and
// publishes every adult self-label whatever the author's own adult-content
// setting; neither helper reads that setting.

@Suite("Moderation leakage: composer self-labels")
@MainActor
struct ComposerSelfLabelTests {
  private static let adultSelfLabels = ["graphic-media", "nudity", "porn", "sexual"]

  @Test("The label picker offers every adult self-label")
  func pickerOffersAdultLabels() {
    let offered = Set(LabelSelectorView.selfLabelOptions.map(\.rawValue))
    #expect(offered == Set(Self.adultSelfLabels + ["!no-unauthenticated"]))
  }

  @Test("Publishing keeps every chosen adult self-label")
  func publishKeepsAdultLabels() {
    let chosen = Set(Self.adultSelfLabels.map { ComAtprotoLabelDefs.LabelValue(rawValue: $0) })
    let published = PostComposerViewModel.selfLabels(from: chosen)
    #expect(published.values.map(\.val) == Self.adultSelfLabels)
  }

  @Test("Publishing keeps a mix of adult and audience labels in a stable order")
  func publishKeepsMixedLabels() {
    let chosen: Set<ComAtprotoLabelDefs.LabelValue> = [.porn, .exclamationnodashunauthenticated]
    let published = PostComposerViewModel.selfLabels(from: chosen)
    #expect(published.values.map(\.val) == ["!no-unauthenticated", "porn"])
  }

  @Test("No chosen labels publishes an empty self-label list")
  func publishEmpty() {
    #expect(PostComposerViewModel.selfLabels(from: []).values.isEmpty)
  }
}
