import Foundation

extension Bundle {
    /// Returns true when the current build is distributed via TestFlight.
    ///
    /// TestFlight builds report a sandbox receipt path without an embedded
    /// provisioning profile. Debug and local builds also use the sandbox
    /// receipt, but they bundle an embedded mobileprovision file.
    var isTestFlightBuild: Bool {
        #if DEBUG
        return false
        #else
        guard appStoreReceiptURL?.lastPathComponent == "sandboxReceipt" else {
            return false
        }

        if path(forResource: "embedded", ofType: "mobileprovision") != nil {
            return false
        }

        return true
        #endif
    }
}
