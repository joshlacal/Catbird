import SwiftUI
import Petrel

/// Extension to add report functionality to views showing content from the AT Protocol network
extension View {
    /// Add report functionality to a view showing a post
    /// - Parameters:
    ///   - post: The post that can be reported
    ///   - client: The AT Protocol client to use for reporting
    ///   - presentingFrom: The view controller to present the report form from
    /// - Returns: The view with a report button added to its context menu
    func withPostReportButton(
        uri: ATProtocolURI,
        cid: CID,
        author: String,
        client: ATProtoClient,
        presentingFrom viewController: UIViewController? = nil
    ) -> some View {
        self.contextMenu {
            Button {
                do {
                    let reportingService = ReportingService(client: client)
                    let subject = try reportingService.createPostSubject(uri: uri, cid: cid)
                    let description = "Post by @\(author)"
                    
                    presentReportForm(
                        reportingService: reportingService,
                        subject: subject,
                        contentDescription: description,
                        from: viewController
                    )
                } catch {
                    // Handle the error, perhaps show an alert
                    print("Error creating report subject: \(error)")
                }
            } label: {
                Label("Report Post", systemImage: "flag")
            }
            
            // Other context menu items would be preserved
        }
    }
    
    /// Add report functionality to a view showing a user profile
    /// - Parameters:
    ///   - did: The DID of the user that can be reported
    ///   - handle: The handle of the user that can be reported
    ///   - client: The AT Protocol client to use for reporting
    ///   - presentingFrom: The view controller to present the report form from
    /// - Returns: The view with a report button added to its context menu
    func withProfileReportButton(
        did: DID,
        handle: String,
        client: ATProtoClient,
        presentingFrom viewController: UIViewController? = nil
    ) -> some View {
        self.contextMenu {
            Button {
                let reportingService = ReportingService(client: client)
                let subject = reportingService.createUserSubject(did: did)
                let description = "Account: @\(handle)"
                
                presentReportForm(
                    reportingService: reportingService,
                    subject: subject,
                    contentDescription: description,
                    from: viewController
                )
            } label: {
                Label("Report Account", systemImage: "flag")
            }
            
            // Other context menu items would be preserved
        }
    }
    
    /// Present the report form
    /// - Parameters:
    ///   - reportingService: The reporting service to use
    ///   - subject: The subject of the report
    ///   - contentDescription: A description of the content being reported
    ///   - viewController: The view controller to present from
    private func presentReportForm(
        reportingService: ReportingService,
        subject: ComAtprotoModerationCreateReport.InputSubjectUnion,
        contentDescription: String,
        from viewController: UIViewController?
    ) {
        let reportForm = ReportFormView(
            reportingService: reportingService,
            subject: subject,
            contentDescription: contentDescription
        )
        
        let hostingController = UIHostingController(rootView: reportForm)
        hostingController.modalPresentationStyle = .formSheet
        
        // Use the provided view controller or find the topmost one
let presentingVC = viewController ?? (UIApplication.shared.connectedScenes.first as? UIWindowScene)?.keyWindow?.rootViewController?.topmostPresentedViewController()
        
        
        presentingVC?.present(hostingController, animated: true)
    }
}

// Helper extension to find the topmost presented view controller
extension UIViewController {
    func topmostPresentedViewController() -> UIViewController {
        if let presented = self.presentedViewController {
            return presented.topmostPresentedViewController()
        }
        return self
    }
}
