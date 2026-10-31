import Testing
import Foundation
import Petrel
@testable import Catbird

@Suite("LabelAppealTests")
struct LabelAppealTests {
    private func makeService() async -> ReportingService {
        let client = await ATProtoClient(baseURL: ATProtoClient.defaultBaseURL)
        return ReportingService(client: client)
    }
    
    @Test("Self-applied labels are non-appealable")
    func testSelfLabelNonAppealable() async throws {
        let service = await makeService()
        let viewerDID = "did:plc:viewer123456789012"
        let viewerDIDObj = try DID(didString: viewerDID)
        
        let selfLabel = ComAtprotoLabelDefs.Label(
            ver: 1,
            src: viewerDIDObj,
            uri: URI(uriString: viewerDID),
            cid: nil,
            val: "self-label",
            neg: false,
            cts: ATProtocolDate(date: Date()),
            exp: nil,
            sig: nil
        )
        
        #expect(ReportingService.isSelfLabel(selfLabel, viewerDID: viewerDID))
        
        // Attempting to appeal self-label should throw selfLabelNotAppealable
        await #expect(throws: LabelAppealError.selfLabelNotAppealable) {
            _ = try await service.submitAppeal(label: selfLabel, viewerDID: viewerDID)
        }
    }
    
    @Test("CID labels create strongRef and DID/no-CID labels create repoRef")
    func testLabelSubjectDerivation() async throws {
        let service = await makeService()
        let labelerDID = try DID(didString: "did:plc:labeler123456789012")
        let accountDID = try DID(didString: "did:plc:targetuser1234567890ab")
        let postURI = try ATProtocolURI(uriString: "at://did:plc:targetuser1234567890ab/app.bsky.feed.post/3k6wuby6vls2u")
        let postCID = try CID.parse("bafyreihyrnm3tmsrqwuk74vffv4s6gq52l7q3b2uyd4zfv3i6v6a5z3z4u")
        
        // 1. Post label with CID -> strongRef
        let postLabel = ComAtprotoLabelDefs.Label(
            ver: 1,
            src: labelerDID,
            uri: URI(uriString: postURI.uriString()),
            cid: postCID,
            val: "nsfw",
            neg: false,
            cts: ATProtocolDate(date: Date()),
            exp: nil,
            sig: nil
        )
        let postSubject = try service.createLabelSubject(for: postLabel)
        if case .comAtprotoRepoStrongRef(let strongRef) = postSubject {
            #expect(strongRef.uri == postURI)
            #expect(strongRef.cid == postCID)
        } else {
            Issue.record("Expected comAtprotoRepoStrongRef for post label with CID")
        }
        
        // 2. Account label without CID -> repoRef
        let accountLabel = ComAtprotoLabelDefs.Label(
            ver: 1,
            src: labelerDID,
            uri: URI(uriString: accountDID.didString()),
            cid: nil,
            val: "spam",
            neg: false,
            cts: ATProtocolDate(date: Date()),
            exp: nil,
            sig: nil
        )
        let accountSubject = try service.createLabelSubject(for: accountLabel)
        if case .comAtprotoAdminDefsRepoRef(let repoRef) = accountSubject {
            #expect(repoRef.did == accountDID)
        } else {
            Issue.record("Expected comAtprotoAdminDefsRepoRef for account label without CID")
        }
    }
    
    @Test("Label source becomes the report proxy target")
    func testLabelSourceProxyTarget() throws {
        let labelerDID = try DID(didString: "did:plc:customlabeler999999")
        let accountDID = try DID(didString: "did:plc:targetuser1234567890ab")
        
        let label = ComAtprotoLabelDefs.Label(
            ver: 1,
            src: labelerDID,
            uri: URI(uriString: accountDID.didString()),
            cid: nil,
            val: "misleading",
            neg: false,
            cts: ATProtocolDate(date: Date()),
            exp: nil,
            sig: nil
        )
        
        #expect(label.src.didString() == "did:plc:customlabeler999999")
    }
    
    @Test("AlreadyAppealed error maps to the non-duplicate state")
    func testAlreadyAppealedMapping() {
        let error = LabelAppealError.alreadyAppealed
        #expect(error.errorDescription == "This label has already been appealed and is currently under review.")
    }
    
    @Test("Negated and expired labels are excluded from active presentation")
    func testActiveLabelFiltering() throws {
        let labelerDID = try DID(didString: "did:plc:labeler123456789012")
        let accountDID = try DID(didString: "did:plc:targetuser1234567890ab")
        
        let now = Date()
        let pastDate = Calendar.current.date(byAdding: .day, value: -2, to: now)!
        let futureDate = Calendar.current.date(byAdding: .day, value: 2, to: now)!
        
        // 1. Normal active label
        let activeLabel = ComAtprotoLabelDefs.Label(
            ver: 1,
            src: labelerDID,
            uri: URI(uriString: accountDID.didString()),
            cid: nil,
            val: "active",
            neg: false,
            cts: ATProtocolDate(date: now),
            exp: ATProtocolDate(date: futureDate),
            sig: nil
        )
        #expect(ReportingService.isLabelActive(activeLabel, at: now) == true)
        
        // 2. Negated label
        let negatedLabel = ComAtprotoLabelDefs.Label(
            ver: 1,
            src: labelerDID,
            uri: URI(uriString: accountDID.didString()),
            cid: nil,
            val: "negated",
            neg: true,
            cts: ATProtocolDate(date: now),
            exp: nil,
            sig: nil
        )
        #expect(ReportingService.isLabelActive(negatedLabel, at: now) == false)
        
        // 3. Expired label
        let expiredLabel = ComAtprotoLabelDefs.Label(
            ver: 1,
            src: labelerDID,
            uri: URI(uriString: accountDID.didString()),
            cid: nil,
            val: "expired",
            neg: false,
            cts: ATProtocolDate(date: pastDate),
            exp: ATProtocolDate(date: pastDate),
            sig: nil
        )
        #expect(ReportingService.isLabelActive(expiredLabel, at: now) == false)
    }
}

@Suite("Label appeal routing and failure isolation")
struct LabelAppealDispatchTests {
  private let owner = "did:plc:targetuser1234567890ab"
  private let issuer = "did:plc:customlabeler999999"

  private func label(subject: String? = nil, cid: CID? = nil) throws -> ComAtprotoLabelDefs.Label {
    .init(src: try DID(didString: issuer), uri: URI(uriString: subject ?? owner), cid: cid,
      val: "joined-may-23", cts: ATProtocolDate(date: Date()))
  }

  @Test("Own-account appeal sends the exact issuer service and account subject")
  func correctIssuerAndSubject() async throws {
    let client = await ATProtoClient(baseURL: URL(string: "https://fixture.invalid")!)
    let receipt = AppealReceipt()
    let owner = owner
    let service = ReportingService(client: client, reportTransport: { input, service in
      await receipt.record(input, service: service)
      return true
    }, activeAccountDID: { owner })
    let result = try await service.submitAppeal(label: label(), viewerDID: owner, details: "  This label is incorrect.  ")
    #expect(result)
    let entry = try #require(await receipt.entries.first)
    #expect(entry.service == issuer + "#atproto_labeler")
    #expect(entry.input.reason == "This label is incorrect.")
    #expect(entry.input.reasonType == .toolsozonereportdefsreasonappeal)
    guard case .comAtprotoAdminDefsRepoRef(let subject) = entry.input.subject else {
      Issue.record("Expected account subject"); return
    }
    #expect(subject.did.didString() == owner)
  }

  @Test("Record appeals remain record subjects and cannot silently become account appeals")
  func recordSubject() async throws {
    let client = await ATProtoClient(baseURL: URL(string: "https://fixture.invalid")!)
    let service = ReportingService(client: client)
    let uri = "at://\(owner)/app.bsky.feed.post/3k6wuby6vls2u"
    let cid = try CID.parse("bafyreihyrnm3tmsrqwuk74vffv4s6gq52l7q3b2uyd4zfv3i6v6a5z3z4u")
    let subject = try service.createLabelSubject(for: label(subject: uri, cid: cid))
    if case .comAtprotoRepoStrongRef(let record) = subject {
      #expect(record.uri.uriString() == uri)
      #expect(record.cid == cid)
    } else { Issue.record("Expected record subject") }
    #expect(throws: (any Error).self) { try service.createLabelSubject(for: label(subject: uri)) }
    #expect(ReportingService.canAppeal(try label(subject: uri, cid: cid), viewerDID: owner))
    #expect(!ReportingService.canAppeal(try label(subject: uri, cid: cid), viewerDID: issuer))
  }

  @Test("Other-account and changed-session appeals fail before submitting")
  func ownershipAndAccountChange() async throws {
    let client = await ATProtoClient(baseURL: URL(string: "https://fixture.invalid")!)
    let receipt = AppealReceipt()
    let service = ReportingService(client: client, reportTransport: { input, service in
      await receipt.record(input, service: service); return true
    }, activeAccountDID: { "did:plc:differentaccount123456" })
    await #expect(throws: LabelAppealError.subjectNotOwned) {
      try await service.submitAppeal(label: label(), viewerDID: issuer, details: "Not mine")
    }
    await #expect(throws: LabelAppealError.accountChanged) {
      try await service.submitAppeal(label: label(), viewerDID: owner, details: "Valid reason")
    }
    #expect(await receipt.entries.isEmpty)
  }

  @Test("Empty and oversized details are rejected without transport")
  func validation() async throws {
    let client = await ATProtoClient(baseURL: URL(string: "https://fixture.invalid")!)
    let service = ReportingService(client: client)
    for reason in [" \n ", String(repeating: "a", count: 301)] {
      await #expect(throws: LabelAppealError.invalidDetails) {
        try await service.submitAppeal(label: label(), viewerDID: owner, details: reason)
      }
    }
  }

  @Test("Exact AlreadyAppealed response maps distinctly; unrelated errors retain failure")
  func errorsAreNotSubstringMatched() async throws {
    let client = await ATProtoClient(baseURL: URL(string: "https://fixture.invalid")!)
    let owner = owner
    let duplicate = ReportingService(client: client, reportTransport: { _, _ in
      throw ATProtoXRPCError(error: "AlreadyAppealed", statusCode: 400)
    }, activeAccountDID: { owner })
    await #expect(throws: LabelAppealError.alreadyAppealed) {
      try await duplicate.submitAppeal(label: label(), viewerDID: owner, details: "Valid reason")
    }
    let expected = ATProtoXRPCError(error: "InvalidRequest", message: "Already processing a duplicate identifier", statusCode: 400)
    let failed = ReportingService(client: client, reportTransport: { _, _ in throw expected }, activeAccountDID: { owner })
    await #expect(throws: expected) {
      try await failed.submitAppeal(label: label(), viewerDID: owner, details: "Valid reason")
    }
  }

  @Test("Unsuccessful submission stays unsuccessful without automatic retry")
  func failedSubmission() async throws {
    let client = await ATProtoClient(baseURL: URL(string: "https://fixture.invalid")!)
    let receipt = AppealReceipt()
    let owner = owner
    let service = ReportingService(client: client, reportTransport: { input, service in
      await receipt.record(input, service: service); return false
    }, activeAccountDID: { owner })
    #expect(try await !service.submitAppeal(label: label(), viewerDID: owner, details: "Valid reason"))
    #expect(await receipt.entries.count == 1)
  }

  @Test("Cancel before submission prevents the transport from running")
  func cancellation() async throws {
    let client = await ATProtoClient(baseURL: URL(string: "https://fixture.invalid")!)
    let receipt = AppealReceipt()
    let owner = owner
    let service = ReportingService(client: client, reportTransport: { input, service in
      await receipt.record(input, service: service); return true
    }, activeAccountDID: { owner })
    let label = try label()
    let task = Task {
      withUnsafeCurrentTask { $0?.cancel() }
      return try await service.submitAppeal(label: label, viewerDID: owner, details: "Valid reason")
    }
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(await receipt.entries.isEmpty)
  }
}

private actor AppealReceipt {
  struct Entry: Sendable {
    let input: ComAtprotoModerationCreateReport.Input
    let service: String
  }
  private(set) var entries: [Entry] = []
  func record(_ input: ComAtprotoModerationCreateReport.Input, service: String) {
    entries.append(Entry(input: input, service: service))
  }
}

@Suite("Label appeal presentation lifecycle")
@MainActor
struct LabelAppealSubmissionTests {
  @Test("Canceled attempt cannot clear or publish into a newer pending submission")
  func cancelReopenResubmit() async throws {
    let model = LabelAppealSubmission()
    let firstGate = AppealTestGate()
    let secondGate = AppealTestGate()
    let first = try #require(model.submit { await firstGate.wait() })
    await firstGate.waitUntilEntered()
    model.cancel()
    let second = try #require(model.submit { await secondGate.wait() })
    await secondGate.waitUntilEntered()
    await firstGate.release(false)
    await first.value
    #expect(model.isSubmitting)
    #expect(model.errorMessage == nil)
    #expect(model.successCount == 0)
    #expect(model.submit { true } == nil)
    await secondGate.release(true)
    await second.value
    #expect(!model.isSubmitting)
    #expect(model.successCount == 1)
  }
}

private actor AppealTestGate {
  private var continuation: CheckedContinuation<Bool, Never>?
  private var enteredContinuation: CheckedContinuation<Void, Never>?
  private var entered = false

  func wait() async -> Bool {
    await withCheckedContinuation { continuation in
      self.continuation = continuation
      entered = true
      enteredContinuation?.resume()
      enteredContinuation = nil
    }
  }

  func waitUntilEntered() async {
    if entered { return }
    await withCheckedContinuation { enteredContinuation = $0 }
  }

  func release(_ result: Bool) {
    continuation?.resume(returning: result)
    continuation = nil
  }
}
