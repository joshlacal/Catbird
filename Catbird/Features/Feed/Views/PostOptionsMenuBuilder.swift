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
        UIAction.postOption("Ask Catbird", systemImage: "sparkles") {
          postState.copilotContextToPresent = postState.copilotContext
          postState.isShowingCopilot = true
        }
      ])
    }

    if !postState.isOwnPost {
      sections.append([
        UIAction.postOption("Add Author to List", systemImage: "list.bullet.rectangle") {
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
        UIAction.postOption("Ask Catbird About Thread", systemImage: "sparkles") {
          postState.copilotContextToPresent = .thread(anchorURI: rootURI)
          postState.isShowingCopilot = true
        }
      ])
    }
#endif

    sections.append([
      UIAction.postOption(
        viewModel.isBookmarked ? "Remove Bookmark" : "Bookmark",
        systemImage: viewModel.isBookmarked ? "bookmark.fill" : "bookmark"
      ) {
        contextMenuViewModel.toggleBookmark()
      }
    ])

    if let feedInteractionTarget {
      sections.append([
        UIAction.postOption("Show More Like This", systemImage: "hand.thumbsup") {
          contextMenuViewModel.sendShowMore(target: feedInteractionTarget)
        },
        UIAction.postOption("Show Less Like This", systemImage: "hand.thumbsdown") {
          contextMenuViewModel.sendShowLess(target: feedInteractionTarget)
        },
      ])
    }

    var moderation: [UIMenuElement] = []
    if !postState.isOwnPost {
      moderation.append(UIAction.postOption("Mute User", systemImage: "speaker.slash") {
        if DestructiveActionConfirmation.shouldConfirm(isEnabled: appState.appSettings.confirmBeforeActions) {
          postState.showMuteUserConfirmation = true
        } else {
          Task { await contextMenuViewModel.muteUser() }
        }
      })
      moderation.append(UIAction.postOption("Block User", systemImage: "exclamationmark.octagon", destructive: true) {
        postState.showBlockConfirmation = true
      })
    }

    if case .public = visibilityContext {
      moderation.append(UIAction.postOption("Mute Thread", systemImage: "bubble.left.and.bubble.right.fill") {
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
        isHidden ? "Unhide Post" : "Hide Post", systemImage: isHidden ? "eye" : "eye.slash"
      ) {
        Task {
          if isHidden {
            await contextMenuViewModel.unhidePost()
          } else {
            await contextMenuViewModel.hidePost()
          }
        }
      })
      moderation.append(UIAction.postOption("Report Post", systemImage: "flag") {
        postState.showingReportView = true
      })

      // Threadgate OP Moderation (G13): Root author can hide/show replies for everyone
      if contextMenuViewModel.isRootAuthor {
        let isHiddenForEveryone = contextMenuViewModel.isReplyHiddenByThreadgate
        moderation.append(UIAction.postOption(
          isHiddenForEveryone ? "Show Reply for Everyone" : "Hide Reply for Everyone",
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
          isDetached ? "Re-attach Quote" : "Detach Quote", systemImage: isDetached ? "link" : "arrow.branch"
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
        isPinned ? "Unpin from Profile" : "Pin to Profile", systemImage: isPinned ? "pin.slash" : "pin"
      ) {
        Task { await contextMenuViewModel.togglePin() }
      })
      moderation.append(UIAction.postOption("Edit Interaction Settings", systemImage: "slider.horizontal.3") {
        postState.showingInteractionSettings = true
      })
      moderation.append(UIAction.postOption("View Labels", systemImage: "tag") {
        postState.showingLabelsOnPost = true
      })
      moderation.append(UIAction.postOption("Delete Post", systemImage: "trash", destructive: true) {
        postState.showDeleteConfirmation = true
      })
    }
    if !moderation.isEmpty { sections.append(moderation) }

    return sections.map { UIMenu.inlineSection($0) }
  }
}
#endif
