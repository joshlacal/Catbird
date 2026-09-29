import Foundation

/// Visibility context of a post.
///
/// Catbird Lite only renders public-network posts, so this has a single case.
/// The type is kept (rather than removing the parameter from every feed,
/// thread, and composer view) so private-audience contexts can be re-added
/// later without re-plumbing those call sites.
public enum PostVisibilityContext: Equatable, Hashable, Sendable, CustomStringConvertible {
  case `public`

  public var description: String {
    switch self {
    case .public: return "public"
    }
  }
}
