import Petrel
import CatbirdMLSCore

/// Text, attachment and reply context travel together for a Bluesky DM send.
struct BlueskyConversationDraft {
  var text = ""
  var attachedEmbed: MLSEmbedData?
  var postRef: ComAtprotoRepoStrongRef?
  var replyTarget: BlueskyMessageAdapter?
}
