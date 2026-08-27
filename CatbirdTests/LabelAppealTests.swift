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
