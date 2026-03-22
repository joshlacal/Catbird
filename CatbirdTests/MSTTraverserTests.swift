import Testing
import Foundation
import Petrel
import SwiftCBOR

@Suite("MSTTraverser Tests")
struct MSTTraverserTests {

  // MARK: - MST Node Decoding

  @Test("decodeMSTNode parses a simple node with one entry")
  func testDecodeSingleEntry() throws {
    // Build MST node: {l: nil, e: [{p: 0, k: <bytes>, v: <CID>, t: nil}]}
    let recordCID = makeCID(digest: 0xAA)
    let keySuffix = Data("app.bsky.feed.post/abc123".utf8)

    let nodeCBOR = buildMSTNodeCBOR(leftSubtree: nil, entries: [
      (prefixLen: 0, keySuffix: keySuffix, valueCID: recordCID, rightSubtree: nil),
    ])

    let reader = try makeReaderWithBlocks([:])
    let traverser = MSTTraverser(reader: reader)
    let node = try traverser.decodeMSTNode(data: nodeCBOR)

    #expect(node.leftSubtree == nil)
    #expect(node.entries.count == 1)
    #expect(node.entries[0].prefixLen == 0)
    #expect(node.entries[0].keySuffix == keySuffix)
    #expect(node.entries[0].valueCID == recordCID)
    #expect(node.entries[0].rightSubtree == nil)
  }

  @Test("decodeMSTNode parses a node with left subtree")
  func testDecodeWithLeftSubtree() throws {
    let leftCID = makeCID(digest: 0xBB)
    let recordCID = makeCID(digest: 0xCC)
    let keySuffix = Data("app.bsky.feed.post/xyz".utf8)

    let nodeCBOR = buildMSTNodeCBOR(leftSubtree: leftCID, entries: [
      (prefixLen: 0, keySuffix: keySuffix, valueCID: recordCID, rightSubtree: nil),
    ])

    let reader = try makeReaderWithBlocks([:])
    let traverser = MSTTraverser(reader: reader)
    let node = try traverser.decodeMSTNode(data: nodeCBOR)

    #expect(node.leftSubtree == leftCID)
    #expect(node.entries.count == 1)
  }

  // MARK: - Key Reconstruction

  @Test("reconstructKeys with no prefix compression")
  func testReconstructKeysNoCompression() throws {
    let reader = try makeReaderWithBlocks([:])
    let traverser = MSTTraverser(reader: reader)

    let entries: [MSTTraverser.MSTEntry] = [
      .init(prefixLen: 0, keySuffix: Data("app.bsky.feed.post/aaa".utf8), valueCID: makeCID(digest: 0x01), rightSubtree: nil),
      .init(prefixLen: 0, keySuffix: Data("app.bsky.graph.follow/bbb".utf8), valueCID: makeCID(digest: 0x02), rightSubtree: nil),
    ]

    let keys = traverser.reconstructKeys(entries: entries)

    #expect(keys.count == 2)
    #expect(keys[0] == "app.bsky.feed.post/aaa")
    #expect(keys[1] == "app.bsky.graph.follow/bbb")
  }

  @Test("reconstructKeys with prefix compression")
  func testReconstructKeysWithCompression() throws {
    let reader = try makeReaderWithBlocks([:])
    let traverser = MSTTraverser(reader: reader)

    // First key: "app.bsky.feed.post/aaa"
    // Second key shares first 19 bytes ("app.bsky.feed.post/") + "bbb"
    let entries: [MSTTraverser.MSTEntry] = [
      .init(prefixLen: 0, keySuffix: Data("app.bsky.feed.post/aaa".utf8), valueCID: makeCID(digest: 0x01), rightSubtree: nil),
      .init(prefixLen: 19, keySuffix: Data("bbb".utf8), valueCID: makeCID(digest: 0x02), rightSubtree: nil),
    ]

    let keys = traverser.reconstructKeys(entries: entries)

    #expect(keys.count == 2)
    #expect(keys[0] == "app.bsky.feed.post/aaa")
    #expect(keys[1] == "app.bsky.feed.post/bbb")
  }

  @Test("reconstructKeys handles multi-level prefix compression")
  func testReconstructKeysMultiLevel() throws {
    let reader = try makeReaderWithBlocks([:])
    let traverser = MSTTraverser(reader: reader)

    let entries: [MSTTraverser.MSTEntry] = [
      .init(prefixLen: 0, keySuffix: Data("app.bsky.feed.post/aaa".utf8), valueCID: makeCID(digest: 0x01), rightSubtree: nil),
      .init(prefixLen: 19, keySuffix: Data("bbb".utf8), valueCID: makeCID(digest: 0x02), rightSubtree: nil),
      .init(prefixLen: 19, keySuffix: Data("ccc".utf8), valueCID: makeCID(digest: 0x03), rightSubtree: nil),
    ]

    let keys = traverser.reconstructKeys(entries: entries)

    #expect(keys[0] == "app.bsky.feed.post/aaa")
    #expect(keys[1] == "app.bsky.feed.post/bbb")
    #expect(keys[2] == "app.bsky.feed.post/ccc")
  }

  // MARK: - Full Walk

  @Test("walkRepository traverses commit → MST → records")
  func testFullWalk() throws {
    // Build a minimal repository:
    // - Commit block: {data: <mstRootCID>, ...}
    // - MST root: {l: nil, e: [{p:0, k:"app.bsky.feed.post/abc", v:<recordCID>, t:nil}]}
    // - Record block: {$type: "app.bsky.feed.post", text: "hello"}

    let recordCBOR = try DAGCBOR.encodeValue([
      "$type": "app.bsky.feed.post",
      "text": "hello world",
      "createdAt": "2024-01-01T00:00:00Z",
    ] as [String: Any])
    let recordCID = CID.fromDAGCBOR(recordCBOR)

    let mstNodeCBOR = buildMSTNodeCBOR(leftSubtree: nil, entries: [
      (prefixLen: 0, keySuffix: Data("app.bsky.feed.post/abc123".utf8), valueCID: recordCID, rightSubtree: nil),
    ])
    let mstCID = CID.fromDAGCBOR(mstNodeCBOR)

    let commitCBOR = buildCommitCBOR(dataCID: mstCID)
    let commitCID = CID.fromDAGCBOR(commitCBOR)

    // Build CAR file with these three blocks
    let carData = try buildCAR(root: commitCID, blocks: [
      (commitCID, commitCBOR),
      (mstCID, mstNodeCBOR),
      (recordCID, recordCBOR),
    ])

    let url = writeTempFile(carData)
    let reader = try CARReader(fileURL: url)
    try reader.indexAllBlocks()

    let traverser = MSTTraverser(reader: reader)
    var results: [(String, CID)] = []

    try traverser.walkRepository(commitCID: commitCID) { path, cid in
      results.append((path, cid))
    }

    #expect(results.count == 1)
    #expect(results[0].0 == "app.bsky.feed.post/abc123")
    #expect(results[0].1 == recordCID)
  }

  @Test("walkRepository handles MST with multiple entries and subtrees")
  func testWalkWithSubtrees() throws {
    // Record blocks
    let record1CBOR = try DAGCBOR.encodeValue(["$type": "app.bsky.feed.post", "text": "first"] as [String: Any])
    let record1CID = CID.fromDAGCBOR(record1CBOR)

    let record2CBOR = try DAGCBOR.encodeValue(["$type": "app.bsky.feed.post", "text": "second"] as [String: Any])
    let record2CID = CID.fromDAGCBOR(record2CBOR)

    let record3CBOR = try DAGCBOR.encodeValue(["$type": "app.bsky.graph.follow", "subject": "did:plc:test"] as [String: Any])
    let record3CID = CID.fromDAGCBOR(record3CBOR)

    // Left subtree with record3
    let leftNodeCBOR = buildMSTNodeCBOR(leftSubtree: nil, entries: [
      (prefixLen: 0, keySuffix: Data("app.bsky.graph.follow/xyz".utf8), valueCID: record3CID, rightSubtree: nil),
    ])
    let leftNodeCID = CID.fromDAGCBOR(leftNodeCBOR)

    // Root MST node with left subtree and two entries
    let rootNodeCBOR = buildMSTNodeCBOR(leftSubtree: leftNodeCID, entries: [
      (prefixLen: 0, keySuffix: Data("app.bsky.feed.post/aaa".utf8), valueCID: record1CID, rightSubtree: nil),
      (prefixLen: 19, keySuffix: Data("bbb".utf8), valueCID: record2CID, rightSubtree: nil),
    ])
    let rootNodeCID = CID.fromDAGCBOR(rootNodeCBOR)

    let commitCBOR = buildCommitCBOR(dataCID: rootNodeCID)
    let commitCID = CID.fromDAGCBOR(commitCBOR)

    let carData = try buildCAR(root: commitCID, blocks: [
      (commitCID, commitCBOR),
      (rootNodeCID, rootNodeCBOR),
      (leftNodeCID, leftNodeCBOR),
      (record1CID, record1CBOR),
      (record2CID, record2CBOR),
      (record3CID, record3CBOR),
    ])

    let url = writeTempFile(carData)
    let reader = try CARReader(fileURL: url)
    try reader.indexAllBlocks()

    let traverser = MSTTraverser(reader: reader)
    var results: [(String, CID)] = []

    try traverser.walkRepository(commitCID: commitCID) { path, cid in
      results.append((path, cid))
    }

    // Should find 3 records: left subtree record first, then root entries
    #expect(results.count == 3)

    let paths = results.map(\.0)
    #expect(paths.contains("app.bsky.graph.follow/xyz"))
    #expect(paths.contains("app.bsky.feed.post/aaa"))
    #expect(paths.contains("app.bsky.feed.post/bbb"))
  }

  // MARK: - Helpers

  private func makeCID(digest: UInt8) -> CID {
    CID(codec: .dagCBOR, multihash: Multihash(algorithm: 0x12, length: 0x20, digest: Data(repeating: digest, count: 32)))
  }

  private func makeReaderWithBlocks(_ blocks: [String: Data]) throws -> CARReader {
    // Build a minimal CAR file with the given blocks
    let dummyCID = makeCID(digest: 0xFF)
    let dummyCBOR = try DAGCBOR.encodeValue(["dummy": true] as [String: Any])

    var allBlocks: [(CID, Data)] = [(dummyCID, dummyCBOR)]
    for (cidString, data) in blocks {
      if let cid = try? CID.parse(cidString) {
        allBlocks.append((cid, data))
      }
    }

    let carData = try buildCAR(root: dummyCID, blocks: allBlocks)
    let url = writeTempFile(carData)
    let reader = try CARReader(fileURL: url)
    try reader.indexAllBlocks()
    return reader
  }

  /// Build a commit block CBOR: {did: "did:test", data: <Tag42 CID>, rev: "test", version: 3}
  private func buildCommitCBOR(dataCID: CID) -> Data {
    let cidPayload = Data([0x00]) + dataCID.bytes
    let commitMap: [CBOR: CBOR] = [
      .utf8String("did"): .utf8String("did:plc:test"),
      .utf8String("data"): .tagged(.init(rawValue: 42), .byteString(cidPayload.map { $0 })),
      .utf8String("rev"): .utf8String("test-rev"),
      .utf8String("version"): .unsignedInt(3),
    ]
    let cborValue = CBOR.map(commitMap)
    return Data(cborValue.encode())
  }

  /// Build MST node CBOR with optional left subtree and entries.
  private func buildMSTNodeCBOR(
    leftSubtree: CID?,
    entries: [(prefixLen: Int, keySuffix: Data, valueCID: CID, rightSubtree: CID?)]
  ) -> Data {
    var nodeMap: [CBOR: CBOR] = [:]

    // `l` field
    if let leftCID = leftSubtree {
      let cidPayload = Data([0x00]) + leftCID.bytes
      nodeMap[.utf8String("l")] = .tagged(.init(rawValue: 42), .byteString(cidPayload.map { $0 }))
    } else {
      nodeMap[.utf8String("l")] = .null
    }

    // `e` array
    var entryItems: [CBOR] = []
    for entry in entries {
      var entryMap: [CBOR: CBOR] = [
        .utf8String("p"): .unsignedInt(UInt64(entry.prefixLen)),
        .utf8String("k"): .byteString(entry.keySuffix.map { $0 }),
      ]

      let vPayload = Data([0x00]) + entry.valueCID.bytes
      entryMap[.utf8String("v")] = .tagged(.init(rawValue: 42), .byteString(vPayload.map { $0 }))

      if let rightCID = entry.rightSubtree {
        let tPayload = Data([0x00]) + rightCID.bytes
        entryMap[.utf8String("t")] = .tagged(.init(rawValue: 42), .byteString(tPayload.map { $0 }))
      }

      entryItems.append(.map(entryMap))
    }
    nodeMap[.utf8String("e")] = .array(entryItems)

    let cborValue = CBOR.map(nodeMap)
    return Data(cborValue.encode())
  }

  /// Build a complete CAR file from a root CID and block list.
  private func buildCAR(root: CID, blocks: [(CID, Data)]) throws -> Data {
    // Header
    let cidPayload = Data([0x00]) + root.bytes
    let headerMap: [CBOR: CBOR] = [
      .utf8String("version"): .unsignedInt(1),
      .utf8String("roots"): .array([
        .tagged(.init(rawValue: 42), .byteString(cidPayload.map { $0 })),
      ]),
    ]
    let headerCborValue = CBOR.map(headerMap)
    let headerCBOR = Data(headerCborValue.encode())

    var carData = Data()
    carData.append(contentsOf: encodeVarint(headerCBOR.count))
    carData.append(headerCBOR)

    for (cid, blockData) in blocks {
      let section = cid.bytes + blockData
      carData.append(contentsOf: encodeVarint(section.count))
      carData.append(section)
    }

    return carData
  }

  private func writeTempFile(_ data: Data) -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("test-\(UUID().uuidString).car")
    try! data.write(to: url)
    return url
  }

  private func encodeVarint(_ value: Int) -> [UInt8] {
    var result: [UInt8] = []
    var v = value
    repeat {
      var byte = UInt8(v & 0x7F)
      v >>= 7
      if v > 0 { byte |= 0x80 }
      result.append(byte)
    } while v > 0
    return result
  }
}
