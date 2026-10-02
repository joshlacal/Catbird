//
//  MLSMessageDisplayOrderTests.swift
//  CatbirdTests
//

import Foundation
import Testing
@testable import Catbird

struct MLSMessageDisplayOrderTests {
  private func adapter(
    id: String,
    sentAt: TimeInterval,
    sequence: Int?,
    senderDID: String = "did:plc:alice"
  ) -> MLSMessageAdapter {
    MLSMessageAdapter(
      id: id,
      convoID: "convo-1",
      text: id,
      senderDID: senderDID,
      currentUserDID: "did:plc:me",
      sentAt: Date(timeIntervalSince1970: sentAt),
      epoch: sequence == nil ? nil : 7,
      sequence: sequence
    )
  }

  @Test("Delivered seq=0 row anchors into the timeline by timestamp")
  func legacySeqZeroRowAnchorsByTimestamp() {
    let ugh = adapter(id: "ugh", sentAt: 1_000, sequence: 5)
    let hello = adapter(id: "hello", sentAt: 3_000, sequence: 6)
    let hiLatest = adapter(id: "hi", sentAt: 4_000, sequence: 7)
    let wow = adapter(id: "wow", sentAt: 2_000, sequence: nil, senderDID: "did:plc:me")

    let sorted = MLSMessageAdapter.sortedForDisplay([hello, wow, hiLatest, ugh])

    #expect(sorted.map(\.id) == ["ugh", "wow", "hello", "hi"])
  }

  @Test("History-boundary marker anchors at its join time")
  func boundaryMarkerAnchorsAtJoinTime() {
    let ugh = adapter(id: "ugh", sentAt: 1_000, sequence: 5)
    let hello = adapter(id: "hello", sentAt: 3_000, sequence: 6)
    let hiLatest = adapter(id: "hi", sentAt: 4_000, sequence: 7)
    let marker = adapter(id: "hb-marker", sentAt: 1_500, sequence: nil)
    let wow = adapter(id: "wow", sentAt: 2_000, sequence: nil, senderDID: "did:plc:me")

    let sorted = MLSMessageAdapter.sortedForDisplay([hello, wow, hiLatest, marker, ugh])

    #expect(sorted.map(\.id) == ["ugh", "hb-marker", "wow", "hello", "hi"])
  }

  @Test("Unsequenced row newer than all sequenced rows still sorts last")
  func freshUnsequencedRowStaysLast() {
    let first = adapter(id: "a", sentAt: 1_000, sequence: 1)
    let second = adapter(id: "b", sentAt: 2_000, sequence: 2)
    let fresh = adapter(id: "fresh", sentAt: 3_000, sequence: nil, senderDID: "did:plc:me")

    let sorted = MLSMessageAdapter.sortedForDisplay([fresh, second, first])

    #expect(sorted.map(\.id) == ["a", "b", "fresh"])
  }

  @Test("Server sequence stays authoritative under sender clock skew")
  func sequenceAuthorityUnderClockSkew() {
    let seq1 = adapter(id: "seq1", sentAt: 200, sequence: 1)
    let seq2 = adapter(id: "seq2", sentAt: 100, sequence: 2)
    let mid = adapter(id: "mid", sentAt: 150, sequence: nil)

    let sorted = MLSMessageAdapter.sortedForDisplay([seq2, mid, seq1])

    #expect(sorted.map(\.id) == ["mid", "seq1", "seq2"])
  }

  @Test("Display order is deterministic across all input permutations")
  func displayOrderIsDeterministicAcrossPermutations() {
    let items = [
      adapter(id: "ugh", sentAt: 1_000, sequence: 5),
      adapter(id: "hb-marker", sentAt: 1_500, sequence: nil),
      adapter(id: "wow", sentAt: 2_000, sequence: nil, senderDID: "did:plc:me"),
      adapter(id: "hello", sentAt: 3_000, sequence: 6),
      adapter(id: "hi", sentAt: 4_000, sequence: 7),
    ]
    let expected = ["ugh", "hb-marker", "wow", "hello", "hi"]

    for permutation in permutations(of: items) {
      let sorted = MLSMessageAdapter.sortedForDisplay(permutation)
      #expect(sorted.map(\.id) == expected)
    }
  }

  @Test("With no sequenced rows, unsequenced rows order by time then id")
  func onlyUnsequencedRowsOrderByTimeThenID() {
    let second = adapter(id: "b", sentAt: 2_000, sequence: nil)
    let first = adapter(id: "a", sentAt: 1_000, sequence: nil)
    let tie1 = adapter(id: "tie-1", sentAt: 3_000, sequence: nil)
    let tie2 = adapter(id: "tie-2", sentAt: 3_000, sequence: nil)

    let sorted = MLSMessageAdapter.sortedForDisplay([tie2, second, tie1, first])

    #expect(sorted.map(\.id) == ["a", "b", "tie-1", "tie-2"])
  }

  private func permutations(of items: [MLSMessageAdapter]) -> [[MLSMessageAdapter]] {
    guard items.count > 1 else { return [items] }
    var result: [[MLSMessageAdapter]] = []
    for (index, item) in items.enumerated() {
      var rest = items
      rest.remove(at: index)
      for var sub in permutations(of: rest) {
        sub.insert(item, at: 0)
        result.append(sub)
      }
    }
    return result
  }
}
