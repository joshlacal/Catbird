// import Foundation
// import OSLog
// import Observation
// import Petrel
//
// @Observable final class ProfileState {
//  private let logger = Logger(subsystem: "blue.catbird", category: "ProfileState")
//  var profile: AppBskyActorDefs.ProfileViewDetailed?
//  var isLoading = false
//  var lastUpdate = Date()
//  var fetchError: Error?
//  var currentDID: String?
//
//  func update(profile: AppBskyActorDefs.ProfileViewDetailed?, forDID: String?) {
//    self.profile = profile
//    self.currentDID = forDID
//    self.lastUpdate = Date()
//    self.isLoading = false
//    self.fetchError = nil
//    logger.info("ProfileState updated with new profile for \(forDID ?? "unknown")")
//  }
//
//  func markLoading() {
//    self.isLoading = true
//    self.fetchError = nil
//  }
//
//  func markError(_ error: Error) {
//    self.fetchError = error
//    self.isLoading = false
//    logger.error("Profile fetch error: \(error.localizedDescription)")
//  }
//
//  func reset() {
//    self.profile = nil
//    self.currentDID = nil
//    self.isLoading = false
//    self.fetchError = nil
//    logger.info("ProfileState reset")
//  }
// }
