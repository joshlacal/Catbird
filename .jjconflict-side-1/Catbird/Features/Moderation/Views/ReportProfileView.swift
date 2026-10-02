import SwiftUI
import Petrel

/// Compatibility forwarder that renders the multi-step `ReportFormView` wizard for profile reports.
struct ReportProfileView: View {
    let profile: AppBskyActorDefs.ProfileViewDetailed
    let reportingService: ReportingService
    let onComplete: (Bool) -> Void
    
    var body: some View {
        let subject = reportingService.createUserSubject(did: profile.did)
        let handle = profile.handle.description
        let displayName = profile.displayName ?? "@\(handle)"
        let description = "Account \(displayName) (@\(handle))"
        
        ReportFormView(
            reportingService: reportingService,
            subject: subject,
            contentDescription: description,
            onComplete: onComplete
        )
    }
}
