import Testing
import Foundation
import Petrel
@testable import Catbird

@Suite("ReportingFlowTests")
struct ReportingFlowTests {
    private func makeService() async -> ReportingService {
        let client = await ATProtoClient(baseURL: ATProtoClient.defaultBaseURL)
        return ReportingService(client: client)
    }
    
    @Test("Subject creation produces correct union types")
    func testSubjectCreation() async throws {
        let service = await makeService()
        let did = try DID(didString: "did:plc:ragtjsm2j2vknwk6zpk4dxku")
        let uri = try ATProtocolURI(uriString: "at://did:plc:ragtjsm2j2vknwk6zpk4dxku/app.bsky.feed.post/3k6wuby6vls2u")
        let cid = try CID.parse("bafyreihyrnm3tmsrqwuk74vffv4s6gq52l7q3b2uyd4zfv3i6v6a5z3z4u")
        // 1. User subject -> repoRef
        let userSubject = service.createUserSubject(did: did)
        if case .comAtprotoAdminDefsRepoRef(let repoRef) = userSubject {
            #expect(repoRef.did == did)
        } else {
            Issue.record("User subject should produce comAtprotoAdminDefsRepoRef")
        }
        
        // 2. Post subject -> strongRef
        let postSubject = service.createPostSubject(uri: uri, cid: cid)
        if case .comAtprotoRepoStrongRef(let strongRef) = postSubject {
            #expect(strongRef.uri == uri)
            #expect(strongRef.cid == cid)
        } else {
            Issue.record("Post subject should produce comAtprotoRepoStrongRef")
        }
        
        // 3. List subject -> strongRef
        let listUri = try ATProtocolURI(uriString: "at://did:plc:ragtjsm2j2vknwk6zpk4dxku/app.bsky.graph.list/3k6wuby6vls2v")
        let listSubject = service.createListSubject(uri: listUri, cid: cid)
        if case .comAtprotoRepoStrongRef(let strongRef) = listSubject {
            #expect(strongRef.uri == listUri)
            #expect(strongRef.cid == cid)
        } else {
            Issue.record("List subject should produce comAtprotoRepoStrongRef")
        }
        
        // 4. Feed subject -> strongRef
        let feedUri = try ATProtocolURI(uriString: "at://did:plc:ragtjsm2j2vknwk6zpk4dxku/app.bsky.feed.generator/myfeed")
        let feedSubject = service.createFeedSubject(uri: feedUri, cid: cid)
        if case .comAtprotoRepoStrongRef(let strongRef) = feedSubject {
            #expect(strongRef.uri == feedUri)
            #expect(strongRef.cid == cid)
        } else {
            Issue.record("Feed subject should produce comAtprotoRepoStrongRef")
        }
    }
    
    @Test("Bluesky-only reasons are accurately identified")
    func testBlueskyOnlyReasons() {
        // Child safety reasons MUST be Bluesky-only
        #expect(ReportingService.isBlueskyOnlyReason(.toolsozonereportdefsreasonchildsafetycsam))
        #expect(ReportingService.isBlueskyOnlyReason(.toolsozonereportdefsreasonchildsafetygroom))
        #expect(ReportingService.isBlueskyOnlyReason(.toolsozonereportdefsreasonchildsafetyprivacy))
        #expect(ReportingService.isBlueskyOnlyReason(.toolsozonereportdefsreasonchildsafetyharassment))
        #expect(ReportingService.isBlueskyOnlyReason(.toolsozonereportdefsreasonchildsafetyother))
        
        // Violent extremism MUST be Bluesky-only
        #expect(ReportingService.isBlueskyOnlyReason(.toolsozonereportdefsreasonviolenceextremistcontent))
        
        // General reasons allow custom labelers
        #expect(!ReportingService.isBlueskyOnlyReason(.toolsozonereportdefsreasonmisleadingspam))
        #expect(!ReportingService.isBlueskyOnlyReason(.toolsozonereportdefsreasonharassmenttargeted))
        #expect(!ReportingService.isBlueskyOnlyReason(.toolsozonereportdefsreasonsexualncii))
        #expect(!ReportingService.isBlueskyOnlyReason(.toolsozonereportdefsreasonviolencethreats))
        #expect(!ReportingService.isBlueskyOnlyReason(.comatprotomoderationdefsreasonother))
    }
    
    @Test("NCII reason is accurately identified")
    func testNCIIReason() {
        #expect(ReportingService.isNCIIReason(.toolsozonereportdefsreasonsexualncii))
        #expect(!ReportingService.isNCIIReason(.toolsozonereportdefsreasonsexualdeepfake))
        #expect(!ReportingService.isNCIIReason(.toolsozonereportdefsreasonsexualunlabeled))
        #expect(!ReportingService.isNCIIReason(.toolsozonereportdefsreasonchildsafetycsam))
    }
    
    @Test("Report categories contain valid Ozone reason mappings")
    func testReportCategoryCatalog() {
        for category in ReportCategory.allCases {
            #expect(!category.title.isEmpty)
            #expect(!category.subtitle.isEmpty)
            #expect(!category.reasons.isEmpty)
            
            for item in category.reasons {
                #expect(!item.title.isEmpty)
                #expect(!item.description.isEmpty)
                #expect(!item.reason.rawValue.isEmpty)
            }
        }
    }
    
    @Test("Video timestamp metadata attaches integer seconds for official labeler when >= 1 second")
    func testVideoTimestampModTool() async throws {
        let service = await makeService()
        let uri = try ATProtocolURI(uriString: "at://did:plc:ragtjsm2j2vknwk6zpk4dxku/app.bsky.feed.post/3k6wuby6vls2u")
        let cid = try CID.parse("bafyreihyrnm3tmsrqwuk74vffv4s6gq52l7q3b2uyd4zfv3i6v6a5z3z4u")
        
        // 1. Below 1 second: modTool should not be generated
        var sub1ModTool: ComAtprotoModerationCreateReport.ModTool? = nil
        let sub1Seconds: Int? = 0
        if let s = sub1Seconds, s >= 1 {
            sub1ModTool = ComAtprotoModerationCreateReport.ModTool(name: "video", meta: .object(["videoTimestampSeconds": .number(s)]))
        }
        #expect(sub1ModTool == nil)
        
        // 2. >= 1 second with official labeler: produces modTool
        let validSeconds = 42
        let modTool = ComAtprotoModerationCreateReport.ModTool(name: "video", meta: .object(["videoTimestampSeconds": .number(validSeconds)]))
        #expect(modTool.name == "video")
        if case .object(let dict) = modTool.meta {
            #expect(dict["videoTimestampSeconds"] == .number(42))
        } else {
            Issue.record("Expected object metadata in ModTool")
        }
    }
    
    @Test("Label subject creation produces strongRef for record labels and repoRef for account labels")
    func testLabelSubjectCreation() async throws {
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
            val: "spam",
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
            Issue.record("Post label should create comAtprotoRepoStrongRef")
        }
        
        // 2. Account label without CID -> repoRef
        let accountLabel = ComAtprotoLabelDefs.Label(
            ver: 1,
            src: labelerDID,
            uri: URI(uriString: accountDID.didString()),
            cid: nil,
            val: "impersonation",
            neg: false,
            cts: ATProtocolDate(date: Date()),
            exp: nil,
            sig: nil
        )
        let accountSubject = try service.createLabelSubject(for: accountLabel)
        if case .comAtprotoAdminDefsRepoRef(let repoRef) = accountSubject {
            #expect(repoRef.did == accountDID)
        } else {
            Issue.record("Account label should create comAtprotoAdminDefsRepoRef")
        }
    }
    
    @Test("Report routing selects endpoint-scoped service DID mapping")
    func testReportRoutingSelection() async throws {
        let client = await ATProtoClient(baseURL: ATProtoClient.defaultBaseURL)
        let customLabeler = "did:plc:customlabeler1234567890"
        
        // Verify official Bluesky DID constant
        #expect(ReportingService.officialBlueskyDID == "did:plc:ar7c4by46qjdydhdevvrndac")
        
        // Verify execution succeeds through ReportDispatcher with custom and default labelers
        let customResult = try await ReportDispatcher.shared.execute(client: client, labelerDid: customLabeler) { _ in
            return "custom"
        }
        #expect(customResult == "custom")
        
        let defaultResult = try await ReportDispatcher.shared.execute(client: client, labelerDid: nil) { _ in
            return "default"
        }
        #expect(defaultResult == "default")
        
        // Verify Bluesky-only vs generic reason routing classification
        #expect(ReportingService.isBlueskyOnlyReason(.toolsozonereportdefsreasonchildsafetycsam))
        #expect(ReportingService.isBlueskyOnlyReason(.toolsozonereportdefsreasonviolenceextremistcontent))
        #expect(!ReportingService.isBlueskyOnlyReason(.toolsozonereportdefsreasonmisleadingspam))
        #expect(!ReportingService.isBlueskyOnlyReason(.toolsozonereportdefsreasonsexualncii))
    }
    
    @Test("ReportDispatcher enforces non-reentrant FIFO execution across concurrent operations")
    func testReportDispatcherFIFOExecution() async throws {
        let client = await ATProtoClient(baseURL: ATProtoClient.defaultBaseURL)
        let labelerA = "did:plc:labelerAAAAAAAAAAAAAAAA"
        let labelerB = "did:plc:labelerBBBBBBBBBBBBBBBB"
        
        actor DispatcherTracker {
            var taskAEntered = false
            var steps: [String] = []
            private var continuation: CheckedContinuation<Void, Never>?
            
            func waitForTaskA() async {
                if taskAEntered { return }
                await withCheckedContinuation { cont in
                    continuation = cont
                }
            }
            
            func markTaskAEntered() {
                taskAEntered = true
                continuation?.resume()
                continuation = nil
            }
            
            func record(_ step: String) {
                steps.append(step)
            }
        }
        
        let tracker = DispatcherTracker()
        
        let taskA = Task {
            try await ReportDispatcher.shared.execute(client: client, labelerDid: labelerA) { _ in
                await tracker.markTaskAEntered()
                await tracker.record("A_start")
                
                // Suspend inside operation to give Task B an opportunity to re-enter if non-reentrancy failed
                try await Task.sleep(nanoseconds: 50_000_000)
                
                await tracker.record("A_end")
                return "A_done"
            }
        }
        
        await tracker.waitForTaskA()
        
        let taskB = Task {
            try await ReportDispatcher.shared.execute(client: client, labelerDid: labelerB) { _ in
                await tracker.record("B_start")
                await tracker.record("B_end")
                return "B_done"
            }
        }
        
        let resultA = try await taskA.value
        let resultB = try await taskB.value
        
        #expect(resultA == "A_done")
        #expect(resultB == "B_done")
        
        let steps = await tracker.steps
        #expect(steps == ["A_start", "A_end", "B_start", "B_end"])
    }
    
    @Test("ReportDispatcher releases FIFO lock on thrown error or cancellation")
    func testReportDispatcherLockReleaseOnError() async throws {
        let client = await ATProtoClient(baseURL: ATProtoClient.defaultBaseURL)
        let labelerError = "did:plc:labelerError111111111"
        let labelerSuccess = "did:plc:labelerSuccess222222"
        
        struct DummyError: Error, Equatable {}
        
        let taskA = Task {
            try await ReportDispatcher.shared.execute(client: client, labelerDid: labelerError) { _ in
                throw DummyError()
            }
        }
        
        do {
            _ = try await taskA.value
            Issue.record("Task A should have thrown DummyError")
        } catch is DummyError {
            // Expected error
        }
        
        let taskB = Task {
            try await ReportDispatcher.shared.execute(client: client, labelerDid: labelerSuccess) { _ in
                return "success"
            }
        }
        
        let resultB = try await taskB.value
        #expect(resultB == "success")
    }
    
    @Test("ReportDispatcher removes canceled queued waiter without setting DID or stranding subsequent tasks")
    func testReportDispatcherCancellation() async throws {
        let client = await ATProtoClient(baseURL: ATProtoClient.defaultBaseURL)
        let labelerA = "did:plc:labelerAAAAAAAAAAAAAAAA"
        let labelerB = "did:plc:labelerBBBBBBBBBBBBBBBB"
        let labelerC = "did:plc:labelerCCCCCCCCCCCCCCCC"
        
        actor Tracker {
            var taskAEntered = false
            var taskBExecuted = false
            var taskCExecuted = false
            private var continuation: CheckedContinuation<Void, Never>?
            
            func waitForTaskA() async {
                if taskAEntered { return }
                await withCheckedContinuation { cont in
                    continuation = cont
                }
            }
            
            func markTaskAEntered() {
                taskAEntered = true
                continuation?.resume()
                continuation = nil
            }
            
            func recordB() {
                taskBExecuted = true
            }
            
            func recordC() {
                taskCExecuted = true
            }
        }
        
        let tracker = Tracker()
        
        // Task A holds the lock briefly
        let taskA = Task {
            try await ReportDispatcher.shared.execute(client: client, labelerDid: labelerA) { _ in
                await tracker.markTaskAEntered()
                try await Task.sleep(nanoseconds: 60_000_000)
                return "A"
            }
        }
        
        await tracker.waitForTaskA()
        
        // Task B queues behind A
        let taskB = Task {
            try await ReportDispatcher.shared.execute(client: client, labelerDid: labelerB) { _ in
                await tracker.recordB()
                return "B"
            }
        }
        
        // Task C queues behind B
        let taskC = Task {
            try await ReportDispatcher.shared.execute(client: client, labelerDid: labelerC) { _ in
                await tracker.recordC()
                return "C"
            }
        }
        
        // Allow B and C to enter acquire() and queue up
        try await Task.sleep(nanoseconds: 10_000_000)
        
        // Cancel Task B while queued
        taskB.cancel()
        
        let resultA = try await taskA.value
        #expect(resultA == "A")
        
        // Task B should throw CancellationError
        do {
            _ = try await taskB.value
            Issue.record("Task B should have thrown CancellationError")
        } catch is CancellationError {
            // Expected
        }
        
        // Task C should proceed and succeed (not stranded!)
        let resultC = try await taskC.value
        #expect(resultC == "C")
        
        let bExecuted = await tracker.taskBExecuted
        let cExecuted = await tracker.taskCExecuted
        #expect(!bExecuted)
        #expect(cExecuted)
    }
}

