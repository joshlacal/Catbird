import Foundation
import Petrel

/// The AppView projects com.germnetwork.declaration.messageMe into associated.germ.
/// Only a deliberate external handoff is performed; Catbird never sends a message.
struct GermProfileAction: Equatable, Identifiable {
  let url: URL
  let viewerDID: String
  let profileDID: String
  var id: String { url.absoluteString }

  static func make(
    metadata: AppBskyActorDefs.ProfileAssociatedGerm?,
    profileDID: String, viewerDID: String, loadedForViewerDID: String?,
    profileFollowsViewer: Bool, isBlocked: Bool, platform: String = "iOS"
  ) -> GermProfileAction? {
    guard ["iOS", "web", "android"].contains(platform), loadedForViewerDID == viewerDID, !viewerDID.isEmpty, profileDID != viewerDID,
          !isBlocked, let metadata,
          metadata.showButtonTo == "everyone" || (metadata.showButtonTo == "usersIFollow" && profileFollowsViewer),
          (try? DID(didString: profileDID)) != nil, (try? DID(didString: viewerDID)) != nil,
          var components = URLComponents(string: metadata.messageMeUrl.originalString ?? metadata.messageMeUrl.uriString()),
          components.scheme?.lowercased() == "https", let host = components.host, !host.isEmpty,
          components.user == nil, components.password == nil, components.fragment == nil else { return nil }
    var path = components.percentEncodedPath
    if path.hasSuffix("/") { path.removeLast() }
    components.percentEncodedPath = path + "/" + platform
    // Escape '+' inside a DID so only the delimiter separates the two identities.
    var allowed = CharacterSet.urlFragmentAllowed
    allowed.remove(charactersIn: "+%#")
    guard let recipient = profileDID.addingPercentEncoding(withAllowedCharacters: allowed),
          let viewer = viewerDID.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
    components.percentEncodedFragment = recipient + "+" + viewer
    guard let url = components.url else { return nil }
    return GermProfileAction(url: url, viewerDID: viewerDID, profileDID: profileDID)
  }
}
