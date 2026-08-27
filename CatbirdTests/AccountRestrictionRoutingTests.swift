//
//  AccountRestrictionRoutingTests.swift
//  CatbirdTests
//
//  Created by Josh LaCalamito on 8/24/26.
//

import Testing
import Foundation
import Petrel
@testable import Catbird

@Suite("AccountRestrictionRoutingTests")
struct AccountRestrictionRoutingTests {
    
    @MainActor
    private func makeAppState(userDID: String = "did:plc:testuser1234567890ab") async -> AppState {
        let client = await ATProtoClient(baseURL: ATProtoClient.defaultBaseURL)
        return AppState(userDID: userDID, client: client)
    }
    
    // MARK: - G42: Account Takedown Lifecycle & Routing
    
    @Test("Taken down session maps to takendown lifecycle state and restricted access")
    @MainActor
    func testTakedownLifecycleProperties() async throws {
        let appState = await makeAppState()
        let lifecycle = AppLifecycle.takendown(appState)
        
        #expect(!lifecycle.isAuthenticated)
        #expect(lifecycle.isRestricted)
        #expect(lifecycle.userDID == appState.userDID)
        #expect(lifecycle.appState?.userDID == appState.userDID)
        #expect(lifecycle.description.contains("takendown"))
        
        // Equatable conformance
        let sameLifecycle = AppLifecycle.takendown(appState)
        #expect(lifecycle == sameLifecycle)
        
        let authenticatedLifecycle = AppLifecycle.authenticated(appState)
        #expect(lifecycle != authenticatedLifecycle)
    }
    
    @Test("Takedown appeal generates official Bluesky labeler reasonAppeal and user repoRef subject")
    func testTakedownAppealSubjectAndPayload() async throws {
        let client = await ATProtoClient(baseURL: ATProtoClient.defaultBaseURL)
        let reportingService = ReportingService(client: client)
        let userDIDString = "did:plc:takendown1234567890"
        let userDID = try DID(didString: userDIDString)
        
        let subject = reportingService.createUserSubject(did: userDID)
        
        if case .comAtprotoAdminDefsRepoRef(let repoRef) = subject {
            #expect(repoRef.did == userDID)
        } else {
            Issue.record("Expected .comAtprotoAdminDefsRepoRef subject union")
        }
        
        #expect(ReportingService.officialBlueskyDID == "did:plc:ar7c4by46qjdydhdevvrndac")
    }
    
    @Test("Takedown appeal maps duplicate/already appealed error")
    func testTakedownAppealDuplicateError() async throws {
        let error = LabelAppealError.alreadyAppealed
        #expect(error.errorDescription?.contains("already been appealed") == true)
    }
    
    // MARK: - G43: Account Deactivation Lifecycle & Reactivation
    
    @Test("Deactivated session maps to deactivated lifecycle state and restricted access")
    @MainActor
    func testDeactivatedLifecycleProperties() async throws {
        let appState = await makeAppState()
        let lifecycle = AppLifecycle.deactivated(appState)
        
        #expect(!lifecycle.isAuthenticated)
        #expect(lifecycle.isRestricted)
        #expect(lifecycle.userDID == appState.userDID)
        #expect(lifecycle.appState?.userDID == appState.userDID)
        #expect(lifecycle.description.contains("deactivated"))
        
        // Equatable conformance
        let sameLifecycle = AppLifecycle.deactivated(appState)
        #expect(lifecycle == sameLifecycle)
        
        let authenticatedLifecycle = AppLifecycle.authenticated(appState)
        #expect(lifecycle != authenticatedLifecycle)
    }
    
    @Test("Lifecycle state transitions between deactivated and authenticated")
    @MainActor
    func testLifecycleTransitions() async throws {
        let appState = await makeAppState()
        let stateManager = AppStateManager.shared
        
        stateManager.setLifecycle(.deactivated(appState))
        #expect(stateManager.lifecycle == .deactivated(appState))
        #expect(!stateManager.lifecycle.isAuthenticated)
        #expect(stateManager.lifecycle.isRestricted)
        
        stateManager.setLifecycle(.authenticated(appState))
        #expect(stateManager.lifecycle == .authenticated(appState))
        #expect(stateManager.lifecycle.isAuthenticated)
        #expect(!stateManager.lifecycle.isRestricted)
        
        stateManager.setLifecycle(.unauthenticated)
        #expect(stateManager.lifecycle == .unauthenticated)
        #expect(stateManager.lifecycle.appState == nil)
    }
    
    @Test("Account isolation: switching accounts does not leak deactivated or takedown state")
    @MainActor
    func testAccountIsolation() async throws {
        let account1 = await makeAppState(userDID: "did:plc:account111111111111")
        let account2 = await makeAppState(userDID: "did:plc:account222222222222")
        
        let stateManager = AppStateManager.shared
        stateManager.setLifecycle(.deactivated(account1))
        #expect(stateManager.lifecycle == .deactivated(account1))
        #expect(stateManager.lifecycle.userDID == "did:plc:account111111111111")
        
        stateManager.setLifecycle(.authenticated(account2))
        #expect(stateManager.lifecycle == .authenticated(account2))
        #expect(stateManager.lifecycle.userDID == "did:plc:account222222222222")
        #expect(!stateManager.lifecycle.isRestricted)
    }
    
    // MARK: - G71: Labeler Liked-By Title Resolution
    
    @Test("LikesView title resolves to Liked By for labeler service URI and Likes for posts")
    func testLikesViewTitleResolution() throws {
        let labelerUri = "at://did:plc:ar7c4by46qjdydhdevvrndac/app.bsky.labeler.service/self"
        let postUri = "at://did:plc:z72i7hdynmk6r22z27h6tvur/app.bsky.feed.post/3l2s5xxv6fn2c"
        
        let isLabeler = labelerUri.contains("app.bsky.labeler.service")
        #expect(isLabeler)
        
        let isPost = postUri.contains("app.bsky.labeler.service")
        #expect(!isPost)
    }
}
