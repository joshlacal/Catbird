import Foundation

/// Lenient reading of space URIs saved during the Spaces alpha, which used
/// `at://{spaceDid}/space/{spaceType}/{skey}[/...]`. Petrel's `SpaceRef` and
/// `ATProtocolURI` accept only the current form, `at:space/{spaceDid}/...`.
///
/// Use this only on values this device stored (Keychain items, saved drafts)
/// or read back from records written during the alpha, never on user input
/// or request parameters. Mirrors `fromLegacySpaceUri` in `@atproto/syntax`.
///
/// It exists only to read alpha-era values, and is deleted together with the
/// Keychain migration in `CircleKeyStore`.
enum LegacySpaceURI {
  static let spaceURIPrefix = "at:space/"

  /// `uri` in the current form when it is an alpha-form space URI
  /// (`at://X/space/...` becomes `at:space/X/...`), otherwise nil.
  static func fromLegacySpaceUri(_ uri: String) -> String? {
    guard uri.hasPrefix("at://") else { return nil }
    let rest = uri.dropFirst("at://".count)
    guard let slash = rest.firstIndex(of: "/") else { return nil }
    let authority = rest[..<slash]
    let path = rest[rest.index(after: slash)...]
    guard !authority.isEmpty,
          !authority.contains(where: { $0 == "?" || $0 == "#" || $0.isWhitespace }),
          path.hasPrefix("space/")
    else { return nil }
    return "\(spaceURIPrefix)\(authority)/\(path.dropFirst("space/".count))"
  }

  /// `uri` converted when it is an alpha-form space URI, unchanged otherwise.
  static func normalized(_ uri: String) -> String {
    fromLegacySpaceUri(uri) ?? uri
  }
}
