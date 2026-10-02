import Petrel

/// Text, attachment and reply context travel together for a Bluesky DM send.
struct BlueskyConversationDraft {
  var text = ""
  var attachedEmbed: ChatSharedPostPreview?
  var postRef: ComAtprotoRepoStrongRef?
  var replyTarget: BlueskyMessageAdapter?
}
