//
//  PostOptionsMenuBuilder.swift
//  Catbird
//
//  The items of a post's options menu, shared by the SwiftUI and native feed rows.
//

#if os(iOS)
import Petrel
import UIKit

// MARK: - Post Options Menu

/// The objects a post's options menu reads and drives. The menu's items set `postState`'s
/// presentation flags, which `PostPresentationsModifier` presents.
@MainActor
struct PostOptionsMenuContext {
  let postState: PostState
  let contextMenuViewModel: PostContextMenuViewModel
  let viewModel: PostViewModel
  let appState: AppState
  /// The custom feed that accepts "Show More / Show Less" feedback, if any.
  let feedInteractionTarget: FeedInteractionTarget?
  let visibilityContext: PostVisibilityContext
}

@MainActor
enum PostOptionsMenuBuilder {
  /// The options menu for `post`, in the same sections and order as the SwiftUI menu
  /// (`PostContentLayout.swiftUIPostOptionsMenu`). Built each time the menu opens, so items
  /// reflect the post's current state.
  static func elements(post: AppBskyFeedDefs.PostView, context: PostOptionsMenuContext) -> [UIMenuElement] {
    let postState = context.postState
    let contextMenuViewModel = context.contextMenuViewModel
    let viewModel = context.viewModel
    let appState = context.appState
    let feedInteractionTarget = context.feedInteractionTarget
    let visibilityContext = context.visibilityContext
    var sections: [[UIMenuElement]] = []

    if CopilotAvailability.isAvailable {
      sections.append([
        UIAction.postOption(
          String(localized: "Ask Catbird", comment: "Post options menu item to ask Catbird intelligence about this post"),
          systemImage: "sparkles"
        ) {
          postState.copilotContextToPresent = postState.copilotContext
          postState.isShowingCopilot = true
        }
      ])
    }

    if !postState.isOwnPost {
      sections.append([
        UIAction.postOption(
          String(localized: "Add Author to List", comment: "Post options menu item to add the post author to a Bluesky list"),
          systemImage: "list.bullet.rectangle"
        ) {
          contextMenuViewModel.addAuthorToList()
        }
      ])
    }

#if canImport(FoundationModels)
    if #available(iOS 26.0, macOS 26.0, *), contextMenuViewModel.allowsThreadSummary, CopilotAvailability.isAvailable {
      let rootURI: String
      if case .knownType(let record) = post.record,
         let feedPost = record as? AppBskyFeedPost,
         let replyRootUri = feedPost.reply?.root.uri.uriString() {
        rootURI = replyRootUri
      } else {
        rootURI = post.uri.uriString()
      }
      sections.append([
        UIAction.postOption(
          String(localized: "Ask Catbird About Thread", comment: "Post options menu item to ask Catbird intelligence about the thread"),
          systemImage: "sparkles"
        ) {
          postState.copilotContextToPresent = .thread(anchorURI: rootURI)
          postState.isShowingCopilot = true
        }
      ])
    }
#endif

    sections.append([
      UIAction.postOption(
        viewModel.isBookmarked
          ? String(localized: "Remove Bookmark", comment: "Post options menu item to remove a bookmark")
          : String(localized: "Bookmark", comment: "Post options menu item to bookmark a post"),
        systemImage: viewModel.isBookmarked ? "bookmark.fill" : "bookmark"
      ) {
        contextMenuViewModel.toggleBookmark()
      }
    ])

    if let feedInteractionTarget {
      sections.append([
        UIAction.postOption(
          String(localized: "Show More Like This", comment: "Custom feed feedback action requesting more posts like this"),
          systemImage: "hand.thumbsup"
        ) {
          contextMenuViewModel.sendShowMore(target: feedInteractionTarget)
        },
        UIAction.postOption(
          String(localized: "Show Less Like This", comment: "Custom feed feedback action requesting fewer posts like this"),
          systemImage: "hand.thumbsdown"
        ) {
          contextMenuViewModel.sendShowLess(target: feedInteractionTarget)
        },
      ])
    }

    var moderation: [UIMenuElement] = []
    if !postState.isOwnPost {
      moderation.append(UIAction.postOption(
        String(localized: "Mute User", comment: "Post options menu item to mute the post's author"),
        systemImage: "speaker.slash"
      ) {
        if DestructiveActionConfirmation.shouldConfirm(isEnabled: appState.appSettings.confirmBeforeActions) {
          postState.showMuteUserConfirmation = true
        } else {
          Task { await contextMenuViewModel.muteUser() }
        }
      })
      moderation.append(UIAction.postOption(
        String(localized: "Block User", comment: "Post options menu item to block the post's author"),
        systemImage: "exclamationmark.octagon",
        destructive: true
      ) {
        postState.showBlockConfirmation = true
      })
    }

    if case .public = visibilityContext {
      moderation.append(UIAction.postOption(
        String(localized: "Mute Thread", comment: "Post options menu item to mute notifications from this thread"),
        systemImage: "bubble.left.and.bubble.right.fill"
      ) {
        if DestructiveActionConfirmation.shouldConfirm(isEnabled: appState.appSettings.confirmBeforeActions) {
          postState.showMuteThreadConfirmation = true
        } else {
          Task { await contextMenuViewModel.muteThread() }
        }
      })
    }

    if !postState.isOwnPost {
      let isHidden = contextMenuViewModel.isPostHidden
      moderation.append(UIAction.postOption(
        isHidden
          ? String(localized: "Unhide Post", comment: "Post options menu item to unhide a hidden post")
          : String(localized: "Hide Post", comment: "Post options menu item to hide a post from feeds"),
        systemImage: isHidden ? "eye" : "eye.slash"
      ) {
        Task {
          if isHidden {
            await contextMenuViewModel.unhidePost()
          } else {
            await contextMenuViewModel.hidePost()
          }
        }
      })
      moderation.append(UIAction.postOption(
        String(localized: "Report Post", comment: "Post options menu item to report a post to moderators"),
        systemImage: "flag"
      ) {
        postState.showingReportView = true
      })

      // Threadgate OP Moderation (G13): Root author can hide/show replies for everyone
      if contextMenuViewModel.isRootAuthor {
        let isHiddenForEveryone = contextMenuViewModel.isReplyHiddenByThreadgate
        moderation.append(UIAction.postOption(
          isHiddenForEveryone
            ? String(localized: "Show Reply for Everyone", comment: "Thread author moderation action to unhide a reply for all viewers")
            : String(localized: "Hide Reply for Everyone", comment: "Thread author moderation action to hide a reply for all viewers"),
          systemImage: isHiddenForEveryone ? "eye" : "eye.slash"
        ) {
          Task {
            if isHiddenForEveryone {
              await contextMenuViewModel.unhideReplyForEveryone()
            } else {
              await contextMenuViewModel.hideReplyForEveryone()
            }
          }
        })
      }

      // Postgate Quote Detachment (G14): Author of quoted post can detach/re-attach quote
      if contextMenuViewModel.quotedPostURI != nil {
        let isDetached = contextMenuViewModel.isQuoteDetached
        moderation.append(UIAction.postOption(
          isDetached
            ? String(localized: "Re-attach Quote", comment: "Quoted post author action to re-attach a detached quote post")
            : String(localized: "Detach Quote", comment: "Quoted post author action to detach their post from a quote post"),
          systemImage: isDetached ? "link" : "arrow.branch"
        ) {
          Task {
            if isDetached {
              await contextMenuViewModel.reattachQuote()
            } else {
              await contextMenuViewModel.detachQuote()
            }
          }
        })
      }
    }

    if postState.isOwnPost {
      let isPinned = contextMenuViewModel.isPinned
      moderation.append(UIAction.postOption(
        isPinned
          ? String(localized: "Unpin from Profile", comment: "Post options menu item to unpin a post from the user's profile")
          : String(localized: "Pin to Profile", comment: "Post options menu item to pin a post to the user's profile"),
        systemImage: isPinned ? "pin.slash" : "pin"
      ) {
        Task { await contextMenuViewModel.togglePin() }
      })
      moderation.append(UIAction.postOption(
        String(localized: "Edit Interaction Settings", comment: "Post options menu item to edit reply and quote permissions"),
        systemImage: "slider.horizontal.3"
      ) {
        postState.showingInteractionSettings = true
      })
      moderation.append(UIAction.postOption(
        String(localized: "View Labels", comment: "Post options menu item to inspect moderation labels applied to the post"),
        systemImage: "tag"
      ) {
        postState.showingLabelsOnPost = true
      })
      moderation.append(UIAction.postOption(
        String(localized: "Delete Post", comment: "Post options menu item to permanently delete the user's post"),
        systemImage: "trash",
        destructive: true
      ) {
        postState.showDeleteConfirmation = true
      })
    }
    if !moderation.isEmpty { sections.append(moderation) }

    return sections.map { UIMenu.inlineSection($0) }
  }
}
#endif
