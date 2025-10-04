import Foundation

/// Centralized access to legal and support URLs configured in Info.plist.
///
/// Add any of the following keys to the app target's Info.plist to override defaults:
/// - `LegalPrivacyPolicyURL` (String): Absolute URL to your Privacy Policy
/// - `LegalTermsOfServiceURL` (String): Absolute URL to your Terms of Service
/// - `SupportURL` (String): Absolute URL to your support page or contact form
/// - `SupportEmail` (String): Email address for support (used if `SupportURL` is not set)
/// - `ServiceStatusURL` (String): Absolute URL to your service status page
///
/// If a given key is not present or invalid, the app will fall back to sensible defaults
/// where appropriate, or omit the optional links entirely.
enum LegalConfig {
    private static var info: [String: Any] { Bundle.main.infoDictionary ?? [:] }

    static var privacyPolicyURL: URL? {
        url(forKey: "LegalPrivacyPolicyURL")
    }

    static var termsOfServiceURL: URL? {
        url(forKey: "LegalTermsOfServiceURL")
    }

    static var supportURL: URL? {
        url(forKey: "SupportURL")
    }

    static var supportEmail: String? {
        guard let raw = info["SupportEmail"] as? String, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return raw
    }

    static var serviceStatusURL: URL? {
        url(forKey: "ServiceStatusURL")
    }

    private static func url(forKey key: String) -> URL? {
        guard let raw = info[key] as? String, let url = URL(string: raw), url.scheme?.hasPrefix("http") == true else { return nil }
        return url
    }
}

