
  // Test-only seams: inject account/token state; unrelated platform work is inert.
  init(testAppState: AppState, testDefaults: UserDefaults, testToken: Data? = nil) {
    notificationServiceDIDString = "did:web:notification-harness.invalid"
    notificationDefaults = testDefaults
    appState = testAppState
    deviceToken = testToken
    super.init()
  }

  func testWaitForMutation() async {
    _ = try? await activePreferenceMutationTask?.value
  }

  func testSetCachedServerSnapshot(_ snapshot: AppBskyNotificationDefs.Preferences?) {
    serverPreferencesSnapshot = snapshot
  }

  func testSetPreferencePersistence(_ enabled: Bool) {
    shouldPersistChatPreference = enabled
  }

  func testActiveMutationExists() -> Bool {
    activePreferenceMutationTask != nil
  }

  func testMutationGeneration() -> UInt64 {
    preferenceMutationGeneration
  }

  func testServerSnapshot() -> AppBskyNotificationDefs.Preferences? {
    serverPreferencesSnapshot
  }

  func testSetMasterPushEnabled(_ enabled: Bool) {
    setMasterPushEnabled(enabled)
  }

  func testAttemptTokenRegistration(_ token: Data) async {
    await registerDeviceToken(token)
  }

  func cleanupNotifications(previousClient: ATProtoClient? = nil) async {}
  func syncRelationships() async {}
  func updateSignedRequestPushRegistration(enabled override: Bool? = nil) async {}
  func registerMLSDeviceToken(_ token: Data) async {}
  func unregisterMLSDeviceToken(_ token: Data, expectedAccount: String? = nil) async {}
