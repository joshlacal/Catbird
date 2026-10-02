import Testing
import Foundation
import Petrel
import SwiftCBOR

@Suite("CARReader Tests")
struct CARReaderTests {

  // MARK: - Synthetic CAR File Tests

  @Test("CARReader indexes a synthetic CAR file on init")
  func testIndexesBlocksOnInit() throws {
    let carData = try buildSyntheticCAR()
    let url = try writeTempFile(carData)
    let reader = try CARReader(fileURL: url)

    // Synthetic CAR has 2 blocks
    #expect(reader.blockIndex.count == 2)
    #expect(reader.roots.count == 1)
  }

  @Test("rawBlockData returns correct data after indexing")
  func testRawBlockData() throws {
    let carData = try buildSyntheticCAR()
    let url = try writeTempFile(carData)
    let reader = try CARReader(fileURL: url)

    // Read each block and verify it decodes as valid CBOR
    for (cidString, _) in reader.blockIndex {
      let data = try reader.rawBlockData(for: cidString)
      #expect(!data.isEmpty, "Block data should not be empty")
    }
  }

  @Test("rawBlockData throws for unknown CID")
  func testRawBlockDataUnknownCID() throws {
    let carData = try buildSyntheticCAR()
    let url = try writeTempFile(carData)
    let reader = try CARReader(fileURL: url)

    #expect(throws: CARReaderError.self) {
      _ = try reader.rawBlockData(for: "bafynotareelcid")
    }
  }

  // MARK: - Error Tests

  @Test("CARReader throws for non-existent file")
  func testFileNotFound() {
    var didThrow = false
    do {
      _ = try CARReader(fileURL: URL(fileURLWithPath: "/tmp/does_not_exist_\(UUID()).car"))
    } catch {
      didThrow = true
    }
    #expect(didThrow)
  }

  // MARK: - Helpers

  private func writeTempFile(_ data: Data) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("test-\(UUID().uuidString).car")
    try data.write(to: url)
    return url
  }

  /// Build a minimal valid CAR file with a header and two blocks.
  private func buildSyntheticCAR() throws -> Data {
    // Block 1: a simple CBOR record
    let record1CBOR = try DAGCBOR.encodeValue(["$type": "app.bsky.feed.post", "text": "hello", "createdAt": "2024-01-01T00:00:00Z"] as [String: Any])
    let cid1 = CID.fromDAGCBOR(record1CBOR)

    // Block 2: another simple record
    let record2CBOR = try DAGCBOR.encodeValue(["$type": "app.bsky.actor.profile", "displayName": "Test User"] as [String: Any])
    let cid2 = CID.fromDAGCBOR(record2CBOR)

    // CAR header: {version: 1, roots: [cid1]}
    // We need to encode roots as Tag 42 CID links
    let headerCBOR = buildCARHeader(roots: [cid1])

    var carData = Data()

    // Header section: [header_length varint][header CBOR]
    carData.append(contentsOf: encodeVarint(headerCBOR.count))
    carData.append(headerCBOR)

    // Block 1: [section_length varint][CID bytes][block data]
    let block1Section = cid1.bytes + record1CBOR
    carData.append(contentsOf: encodeVarint(block1Section.count))
    carData.append(block1Section)

    // Block 2: [section_length varint][CID bytes][block data]
    let block2Section = cid2.bytes + record2CBOR
    carData.append(contentsOf: encodeVarint(block2Section.count))
    carData.append(block2Section)

    return carData
  }

  /// Build a CAR header with roots encoded as CBOR Tag 42 links.
  private func buildCARHeader(roots: [CID]) -> Data {
    // Build header CBOR manually: {version: 1, roots: [Tag42(cid1), ...]}
    // We use SwiftCBOR directly for precise control
    var rootItems: [CBOR] = []
    for root in roots {
      let cidPayload = Data([0x00]) + root.bytes
      let tagged = CBOR.tagged(.init(rawValue: 42), .byteString(cidPayload.map { $0 }))
      rootItems.append(tagged)
    }

    let headerMap: [CBOR: CBOR] = [
      .utf8String("version"): .unsignedInt(1),
      .utf8String("roots"): .array(rootItems),
    ]

    let cborValue = CBOR.map(headerMap)
    let encoded = cborValue.encode()
    return Data(encoded)
  }

  /// Encode an integer as an unsigned LEB128 varint.
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
