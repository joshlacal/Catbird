import Testing
import Foundation
import Petrel
import SwiftCBOR

@Suite("CARReader Tests")
struct CARReaderTests {

  // MARK: - Varint Tests

  @Test("readVarint decodes single-byte values correctly")
  func testVarintSingleByte() throws {
    // Value 42 = 0x2A (single byte, MSB clear)
    let data = Data([0x2A])
    let url = try writeTempFile(data)
    let reader = try CARReader(fileURL: url)
    let value = try reader.readVarint()
    #expect(value == 42)
  }

  @Test("readVarint decodes multi-byte values correctly")
  func testVarintMultiByte() throws {
    // Value 300 = 0b100101100 → LEB128: [0xAC, 0x02]
    let data = Data([0xAC, 0x02])
    let url = try writeTempFile(data)
    let reader = try CARReader(fileURL: url)
    let value = try reader.readVarint()
    #expect(value == 300)
  }

  @Test("readVarint decodes zero")
  func testVarintZero() throws {
    let data = Data([0x00])
    let url = try writeTempFile(data)
    let reader = try CARReader(fileURL: url)
    let value = try reader.readVarint()
    #expect(value == 0)
  }

  @Test("readVarint decodes max single-byte value (127)")
  func testVarintMaxSingleByte() throws {
    let data = Data([0x7F])
    let url = try writeTempFile(data)
    let reader = try CARReader(fileURL: url)
    let value = try reader.readVarint()
    #expect(value == 127)
  }

  @Test("readVarint decodes 128 (first multi-byte)")
  func testVarint128() throws {
    // 128 → LEB128: [0x80, 0x01]
    let data = Data([0x80, 0x01])
    let url = try writeTempFile(data)
    let reader = try CARReader(fileURL: url)
    let value = try reader.readVarint()
    #expect(value == 128)
  }

  // MARK: - CID Parsing Tests

  @Test("readCID parses a CIDv1 dag-cbor SHA-256")
  func testReadCIDv1() throws {
    // CIDv1: version=1, codec=0x71 (dag-cbor), hash=0x12 (SHA-256), len=0x20
    var cidBytes = Data([0x01, 0x71, 0x12, 0x20])
    cidBytes.append(Data(repeating: 0xAB, count: 32)) // 32-byte digest

    let url = try writeTempFile(cidBytes)
    let reader = try CARReader(fileURL: url)
    let cid = try reader.readCID()

    #expect(cid.codec == .dagCBOR)
    #expect(cid.multihash.algorithm == 0x12)
    #expect(cid.multihash.length == 0x20)
    #expect(cid.multihash.digest.count == 32)
    #expect(cid.multihash.digest == Data(repeating: 0xAB, count: 32))
  }

  @Test("readCID parses a CIDv1 raw codec")
  func testReadCIDv1Raw() throws {
    // CIDv1: version=1, codec=0x55 (raw), hash=0x12 (SHA-256), len=0x20
    var cidBytes = Data([0x01, 0x55, 0x12, 0x20])
    cidBytes.append(Data(repeating: 0xCD, count: 32))

    let url = try writeTempFile(cidBytes)
    let reader = try CARReader(fileURL: url)
    let cid = try reader.readCID()

    #expect(cid.codec == .raw)
    #expect(cid.multihash.digest.count == 32)
  }

  // MARK: - Synthetic CAR File Tests

  @Test("indexAllBlocks correctly indexes a synthetic CAR file")
  func testIndexAllBlocks() throws {
    let carData = try buildSyntheticCAR()
    let url = try writeTempFile(carData)
    let reader = try CARReader(fileURL: url)
    let count = try reader.indexAllBlocks()

    // Synthetic CAR has 2 blocks
    #expect(count == 2)
    #expect(reader.blockIndex.count == 2)
    #expect(reader.roots.count == 1)
  }

  @Test("readBlockData returns correct data after indexing")
  func testReadBlockData() throws {
    let carData = try buildSyntheticCAR()
    let url = try writeTempFile(carData)
    let reader = try CARReader(fileURL: url)
    try reader.indexAllBlocks()

    // Read each block and verify it decodes as valid CBOR
    for (cidString, _) in reader.blockIndex {
      let data = reader.readBlockData(for: cidString)
      #expect(data != nil, "Block data should be readable for CID: \(cidString.prefix(20))")
      #expect(data!.count > 0, "Block data should not be empty")
    }
  }

  @Test("readBlockData returns nil for unknown CID")
  func testReadBlockDataUnknownCID() throws {
    let carData = try buildSyntheticCAR()
    let url = try writeTempFile(carData)
    let reader = try CARReader(fileURL: url)
    try reader.indexAllBlocks()

    let data = reader.readBlockData(for: "bafynotareelcid")
    #expect(data == nil)
  }

  // MARK: - Error Tests

  @Test("CARReader throws for non-existent file")
  func testFileNotFound() {
    #expect(throws: CARReaderError.self) {
      _ = try CARReader(fileURL: URL(fileURLWithPath: "/tmp/does_not_exist_\(UUID()).car"))
    }
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
