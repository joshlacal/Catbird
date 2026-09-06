import Foundation
import NukeUI
import OSLog
import Petrel
import SwiftUI
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

struct ProfileHeader: View {
    let profile: AppBskyActorDefs.ProfileViewDetailed
    let viewModel: ProfileViewModel
    let appState: AppState
    @Binding var isEditingProfile: Bool
    @Binding var path: NavigationPath
    let screenWidth: CGFloat
    let hideAvatar: Bool
    
    @Environment(\.colorScheme) private var colorScheme
    @State private var isFollowButtonLoading = false
    @State private var localIsFollowing = false
    @State private var localActivitySubscription: AppBskyNotificationDefs.ActivitySubscription?
    @State private var isActivitySubscriptionLoading = false
    @State private var activitySubscriptionError: String?
    @State private var isShowingProfileImageViewer = false
    @State private var verificationInfoKind: VerificationBadgeKind?
    @State private var showUnfollowConfirmation = false
    @State private var showingSuggestedFollows = false
    @Namespace private var imageTransition
    private let verticalSpacing: CGFloat = 12
    private let avatarSize: CGFloat = 80
    
    private let logger = Logger(subsystem: "blue.catbird", category: "ProfileHeader")
    
    var body: some View {
        ZStack(alignment: .topLeading) {
            profileInfoContent
                .padding(.top, hideAvatar ? verticalSpacing : 8)

            if !hideAvatar {
                avatarView
                    .overlay(alignment: .bottom) {
                        liveStatusBadgeOverlay
                    }
                    .offset(y: -avatarSize / 2)
                    .padding(.leading, 16)
            }
        }
#if os(iOS)
        .fullScreenCover(isPresented: $isShowingProfileImageViewer) {
            if let profile = viewModel.profile, let avatarURI = profile.avatar?.uriString() {
                ProfileImageViewerView(avatar: profile.avatar, isPresented: $isShowingProfileImageViewer, namespace: imageTransition)
                    .navigationTransition(.zoom(sourceID: avatarURI, in: imageTransition))
            }
        }
        .presentationBackground(.black)
#elseif os(macOS)
        .sheet(isPresented: $isShowingProfileImageViewer) {
            if let profile = viewModel.profile {
                ProfileImageViewerView(avatar: profile.avatar, isPresented: $isShowingProfileImageViewer, namespace: imageTransition)
            }
        }
#endif
        .sheet(item: $verificationInfoKind) { kind in
            VerificationInfoSheet(
                kind: kind,
                displayName: profile.displayName ?? profile.handle.description,
                verifications: profile.verification?.verifications ?? []
            )
        }
        .onAppear {
            localIsFollowing = profile.viewer?.following != nil
            updateLocalActivitySubscription()
        }
        .onChange(of: profile) { _, newProfile in
            localIsFollowing = newProfile.viewer?.following != nil
            updateLocalActivitySubscription()
        }
        .onChange(of: activitySubscriptionSnapshot) { _, _ in
            updateLocalActivitySubscription()
        }
        .alert("Unfollow", isPresented: $showUnfollowConfirmation) {
            Button("Cancel", role: .cancel) { }
            Button("Unfollow", role: .destructive) { performUnfollow() }
        } message: {
            Text("Unfollow @\(profile.handle)? You'll stop seeing their posts in your following feed.")
        }
        .sheet(isPresented: $showingSuggestedFollows) {
            ContextualSuggestedFollowsSheet(
                actorDID: profile.did.didString(),
                actorHandle: profile.handle.description,
                path: $path
            )
        }
    }
    
    private var activitySubscriptionService: ActivitySubscriptionService {
        appState.activitySubscriptionService
    }

    private struct SubscriptionSnapshot: Equatable {
        let id: String
        let post: Bool
        let reply: Bool
    }

    private var activitySubscriptionSnapshot: [SubscriptionSnapshot] {
        activitySubscriptionService.subscriptions.map { entry in
            SubscriptionSnapshot(
                id: entry.id,
                post: entry.subscription?.post ?? false,
                reply: entry.subscription?.reply ?? false
            )
        }
    }
    
    private var isSubscriptionUpdating: Bool {
        isActivitySubscriptionLoading || activitySubscriptionService.isUpdating(did: profile.did.didString())
    }
    
    private var canSubscribeToActivity: Bool {
        guard !viewModel.isCurrentUser else { return false }
        if profile.viewer?.blocking != nil || profile.viewer?.blockedBy == true {
            return false
        }
        if let allowSubscriptions = profile.associated?.activitySubscription?.allowSubscriptions {
            // The lexicon currently allows: followers, mutuals, or none.
            switch allowSubscriptions {
            case "none":
                return false
            case "followers":
                return profile.viewer?.following != nil
            case "mutuals":
                return profile.viewer?.following != nil && profile.viewer?.followedBy != nil
            default:
                return true
            }
        }
        return true
    }
    
    private var currentActivitySubscriptionState: ActivitySubscriptionState {
        guard let subscription = localActivitySubscription else { return .none }
        switch (subscription.post, subscription.reply) {
        case (true, true):
            return .postsAndReplies
        case (true, false):
            return .postsOnly
        case (false, true):
            return .repliesOnly
        default:
            return .none
        }
    }
    
    private var nextActivitySubscriptionState: ActivitySubscriptionState {
        switch currentActivitySubscriptionState {
        case .none:
            return .postsOnly
        case .postsOnly:
            return .postsAndReplies
        case .postsAndReplies, .repliesOnly:
            return .none
        }
    }
    
    private var subscriptionButtonIcon: String {
        switch currentActivitySubscriptionState {
        case .none:
            return "bell"
        case .postsOnly:
            return "bell.badge"
        case .postsAndReplies:
            return "bell.badge.fill"
        case .repliesOnly:
            return "bubble.left"
        }
    }
    
    private var subscriptionButtonTint: Color {
        switch currentActivitySubscriptionState {
        case .none:
            return .secondary
        case .postsOnly, .postsAndReplies:
            return .indigo
        case .repliesOnly:
            return .teal
        }
    }
    
    private var subscriptionButtonAccessibilityLabel: String {
        switch currentActivitySubscriptionState {
        case .none:
            return "Activity notifications off"
        case .postsOnly:
            return "Activity notifications for posts"
        case .postsAndReplies:
            return "Activity notifications for posts and replies"
        case .repliesOnly:
            return "Activity notifications for replies"
        }
    }
    
    private var isSubscriptionControlDisabled: Bool {
        isSubscriptionUpdating
    }
    
    @ViewBuilder
    private var activitySubscriptionControl: some View {
        Button(action: cycleActivitySubscriptionState) {
            Group {
                if isSubscriptionUpdating {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .tint(subscriptionButtonTint)
                        .frame(width: 36, height: 36)
                } else {
                    Image(systemName: subscriptionButtonIcon)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(subscriptionButtonTint)
                        .frame(width: 18, height: 18)
                        .padding(10)
                        .background(
                            Circle()
                                .fill(currentActivitySubscriptionState == .none ? Color.clear : subscriptionButtonTint.opacity(0.15))
                        )
                        .overlay(
                            Circle()
                                .stroke(subscriptionButtonTint.opacity(0.8), lineWidth: 1.5)
                        )
                        .contentShape(Circle())
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(subscriptionButtonAccessibilityLabel)
        .accessibilityHint("Cycles activity notifications between posts, posts & replies, or off")
        .disabled(isSubscriptionControlDisabled)
    }
    
    private func cycleActivitySubscriptionState() {
        guard canSubscribeToActivity, !isSubscriptionControlDisabled else { return }
        let did = profile.did.didString()
        let nextState = nextActivitySubscriptionState
        activitySubscriptionError = nil
        isActivitySubscriptionLoading = true

        Task {
            do {
                let updatedSubscription: AppBskyNotificationDefs.ActivitySubscription?

                switch nextState {
                case .none:
                    try await activitySubscriptionService.clearSubscription(for: did)
                    updatedSubscription = nil
                case .postsOnly:
                    updatedSubscription = try await activitySubscriptionService.setSubscription(for: did, posts: true, replies: false)
                case .postsAndReplies:
                    updatedSubscription = try await activitySubscriptionService.setSubscription(for: did, posts: true, replies: true)
                case .repliesOnly:
                    updatedSubscription = try await activitySubscriptionService.setSubscription(for: did, posts: false, replies: true)
                }

                await MainActor.run {
                    localActivitySubscription = updatedSubscription
                    activitySubscriptionError = nil
                }
            } catch {
                logger.error("Failed to update activity subscription: \(error.localizedDescription)")
                await MainActor.run {
                    activitySubscriptionError = error.localizedDescription
                }
            }

            await MainActor.run {
                isActivitySubscriptionLoading = false
            }
        }
    }

    private func performUnfollow() {
        Task(priority: .userInitiated) {
            isFollowButtonLoading = true
            localIsFollowing = false
            do {
                let success = try await appState.unfollow(did: profile.did.didString())
                if success {
                    try? await Task.sleep(for: .seconds(0.5))
                    await viewModel.loadProfile()
                } else {
                    localIsFollowing = true
                }
            } catch {
                logger.debug("Error unfollowing: \(error.localizedDescription)")
                localIsFollowing = true
            }
            isFollowButtonLoading = false
        }
    }

    private func updateLocalActivitySubscription() {
        let did = profile.did.didString()
        if let subscription = profile.viewer?.activitySubscription {
            localActivitySubscription = subscription
        } else if let cached = activitySubscriptionService.subscription(for: did) {
            localActivitySubscription = cached
        } else {
            localActivitySubscription = nil
        }
    }

    private enum ActivitySubscriptionState {
        case none
        case postsOnly
        case postsAndReplies
        case repliesOnly
    }
    
    private var isLabeler: Bool {
        viewModel.isLabeler
    }
    
    private var avatarView: some View {
        let moderationState = getAvatarModerationState(profile.labels)
        let shouldDisableTap = (moderationState == .hide)
        
        return Group {
            if isLabeler {
                // Square avatar for labelers
                Group {
                    if moderationState == .hide {
                        // Hidden avatar placeholder
                        RoundedRectangle(cornerRadius: 12)
                            .fill(Color.secondary.opacity(0.3))
                            .overlay(
                                Image(systemName: "eye.slash.fill")
                                    .resizable()
                                    .aspectRatio(contentMode: .fit)
                                    .foregroundColor(.secondary.opacity(0.5))
                                    .frame(width: avatarSize * 0.4, height: avatarSize * 0.4)
                            )
                    } else {
                        LazyImage(url: URL(string: profile.avatar?.uriString() ?? "")) { state in
                            if let image = state.image {
                                image.resizable().aspectRatio(contentMode: .fill)
                            } else {
                                RoundedRectangle(cornerRadius: 12).fill(Color.secondary.opacity(0.3))
                            }
                        }
                        .matchedTransitionSource(id: profile.avatar?.uriString() ?? "", in: imageTransition)
                        .blur(radius: moderationState == .blur ? 20 : 0)
                    }
                }
                .onTapGesture {
                    if !shouldDisableTap {
                        isShowingProfileImageViewer = true
                    }
                }
                .frame(width: avatarSize, height: avatarSize)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.dynamicBackground(appState.themeManager, currentScheme: colorScheme), lineWidth: 4)
                        .scaleEffect((avatarSize + 8) / avatarSize)
                )
                .zIndex(10)
            } else {
                // Circular avatar for regular users
                Group {
                    if moderationState == .hide {
                        // Hidden avatar placeholder
                        Circle()
                            .fill(Color.secondary.opacity(0.3))
                            .overlay(
                                Image(systemName: "eye.slash.fill")
                                    .resizable()
                                    .aspectRatio(contentMode: .fit)
                                    .foregroundColor(.secondary.opacity(0.5))
                                    .frame(width: avatarSize * 0.4, height: avatarSize * 0.4)
                            )
                    } else {
                        LazyImage(url: URL(string: profile.avatar?.uriString() ?? "")) { state in
                            if let image = state.image {
                                image.resizable().aspectRatio(contentMode: .fill)
                            } else {
                                Circle().fill(Color.secondary.opacity(0.3))
                            }
                        }
                        .matchedTransitionSource(id: profile.avatar?.uriString() ?? "", in: imageTransition)
                        .blur(radius: moderationState == .blur ? 20 : 0)
                    }
                }
                .onTapGesture {
                    if !shouldDisableTap {
                        isShowingProfileImageViewer = true
                    }
                }
                .frame(width: avatarSize, height: avatarSize)
                .clipShape(Circle())
                .background(
                    Circle()
                        .foregroundStyle(Color.dynamicBackground(appState.themeManager, currentScheme: colorScheme))
                        .scaleEffect((avatarSize + 8) / avatarSize)
                )
                .zIndex(10)
            }
        }
    }

    @ViewBuilder
    private var liveStatusBadgeOverlay: some View {
        if let status = profile.status, status.isLiveNow {
            LiveStatusBadge(embedURL: status.liveEmbedURL)
                .offset(y: 8)
                .zIndex(11)
        }
    }

    private var profileInfoContent: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Top section with edit/follow/subscribe button aligned to trailing edge
            HStack(alignment: .top, spacing: 8) {
                Spacer()
                
                if viewModel.isCurrentUser {
                    editProfileButton
                        .allowsHitTesting(true)
                } else if isLabeler {
                    HStack(spacing: 8) {
                        subscribeButton
                            .allowsHitTesting(true)
                        labelerLikeButton
                            .allowsHitTesting(true)
                    }
                } else {
                    HStack(spacing: 8) {
                        followButton
                            .allowsHitTesting(true)
                        if canSubscribeToActivity {
                            activitySubscriptionControl
                        }
                    }
                }
            }
            .padding(.top, 4)

            if let activitySubscriptionError {
                Text(activitySubscriptionError)
                    .appCaption()
                    .foregroundStyle(.red)
                    .padding(.top, 2)
            }
            
            // Display name and handle
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text(profile.displayName ?? profile.handle.description)
                        .enhancedAppHeadline()
                        .fontWeight(.bold)
                        .lineLimit(nil)
                        .fixedSize(horizontal: false, vertical: true)

                    if let badgeKind = VerificationBadge.kind(for: profile.verification, did: profile.did) {
                        VerificationBadgeView(kind: badgeKind) {
                            verificationInfoKind = badgeKind
                        }
                        .enhancedAppHeadline()
                    }
                    
                    if let pronouns = profile.pronouns, !pronouns.isEmpty {
                        Text(pronouns)
                            .appFont(AppTextRole.subheadline)
                            .foregroundStyle(.secondary)
                            .opacity(0.9)
                            .textScale(.secondary)
                            .padding(1)
                            .padding(.horizontal, 4)
                            .padding(.bottom, 2)
                            .background(
                                RoundedRectangle(cornerRadius: 12)
                                    .fill(Color.secondary.opacity(0.1))
                            )

                    }

                }
                HStack(spacing: 8) {
                    Text("@\(profile.handle)")
                        .enhancedAppSubheadline()
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    
                    NewskieBadge(
                        profile: profile,
                        isSelf: viewModel.isCurrentUser,
                        path: $path
                    )

                    if profile.viewer?.followedBy != nil {
                        FollowsBadgeView()
                    }
                }
            }
            
            // Bio
            if let attributedBio = bioAttributedString(for: profile) {
                TappableTextView(attributedString: attributedBio)
                    .padding(.top, 2)
            } else if let description = profile.description, !description.isEmpty {
                Text(description)
                    .enhancedAppBody()
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // Website
            if let website = profile.website {
                let urlString = website.uriString()
                Button {
                    if let url = URL(string: urlString) {
                        #if os(iOS)
                        UIApplication.shared.open(url)
                        #elseif os(macOS)
                        NSWorkspace.shared.open(url)
                        #endif
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "link")
                            .font(.caption)
                        Text(urlString.replacingOccurrences(of: "https://", with: "").replacingOccurrences(of: "http://", with: ""))
                            .lineLimit(1)
                    }
                    .appFont(AppTextRole.subheadline)
                    .foregroundStyle(Color("AccentTextColor"))
                }
                .buttonStyle(.plain)
            }
            
            // Stats
            HStack(spacing: 24) {

                // Following
                Button(action: {
                    
                    path.append(ProfileNavigationDestination.following(profile.did.didString()))
                    
                }) {
                    HStack(spacing: 6) {
                        
                        Text("\(profile.followsCount?.formatted ?? "0")")
                            .appFont(AppTextRole.subheadline)
                            .fontWeight(.semibold)
                        
                        Text("Following")
                            .appFont(AppTextRole.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
                
                // Followers
                Button(action: {
                    path.append(ProfileNavigationDestination.followers(profile.did.didString()))
                }) {
                    HStack(spacing: 6) {
                        Text("\(profile.followersCount?.formatted ?? "0")")
                            .appFont(AppTextRole.subheadline)
                            .fontWeight(.semibold)
                        
                        Text("Followers")
                            .appFont(AppTextRole.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
                
                // Posts
                if let postsCount = profile.postsCount {
                    HStack(spacing: 6) {
                        Text("\(postsCount.formatted)")
                            .appFont(AppTextRole.subheadline)
                            .fontWeight(.semibold)

                        Text("Posts")
                            .appFont(AppTextRole.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()
            }
        }
    }

    // MARK: - Bio Helpers

    private func bioAttributedString(for profile: AppBskyActorDefs.ProfileViewDetailed) -> AttributedString? {
        guard let description = profile.description, !description.isEmpty else {
            return nil
        }

        let attributedBio = NSMutableAttributedString(string: description)

        applyDetectedLinks(in: description, to: attributedBio)
        applyDetectedHandles(in: description, to: attributedBio)

        return AttributedString(attributedBio)
    }

    private func applyDetectedLinks(in text: String, to attributedText: NSMutableAttributedString) {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else {
            return
        }

        let nsText = text as NSString
        let fullRange = NSRange(location: 0, length: nsText.length)
        let trailingPunctuation: Set<Character> = [".", ",", ")", "!", "?", ";", ":"]

        detector.enumerateMatches(in: text, options: [], range: fullRange) { match, _, _ in
            guard let match, let url = match.url else { return }

            var adjustedRange = match.range
            var adjustedURL = url

            // Strip trailing punctuation that NSDataDetector over-eagerly includes.
            // e.g. "josh.uno." at end of sentence — the trailing "." is sentence
            // punctuation, not part of the domain.
            let matchedText = nsText.substring(with: match.range)
            if let lastChar = matchedText.last, trailingPunctuation.contains(lastChar) {
                // Only strip if the match has no explicit scheme (NSDataDetector
                // inferred "http://") — real URLs with schemes are intentional.
                let hasExplicitScheme = matchedText.lowercased().hasPrefix("http://")
                    || matchedText.lowercased().hasPrefix("https://")
                if !hasExplicitScheme {
                    adjustedRange.length -= 1

                    // Rebuild URL without trailing punctuation
                    let trimmedText = String(matchedText.dropLast())
                    if let scheme = adjustedURL.scheme,
                       let rebuilt = URL(string: "\(scheme)://\(trimmedText)") {
                        adjustedURL = rebuilt
                    }
                }
            }

            // Reject matches that are too short to be real domains (e.g. "a.b")
            let finalText = nsText.substring(with: adjustedRange)
            let domainPart = finalText.replacingOccurrences(of: "http://", with: "")
                .replacingOccurrences(of: "https://", with: "")
            if domainPart.count < 4 { return }

            guard !hasLinkAttribute(in: attributedText, range: adjustedRange) else { return }
            applyLinkAttributes(url: adjustedURL, range: adjustedRange, on: attributedText)
        }
    }

    private func applyDetectedHandles(in text: String, to attributedText: NSMutableAttributedString) {
        let pattern = "(?<![\\w@])@[A-Za-z0-9][A-Za-z0-9.-]*"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return
        }

        let nsText = text as NSString
        let fullRange = NSRange(location: 0, length: nsText.length)

        regex.enumerateMatches(in: text, options: [], range: fullRange) { match, _, _ in
            guard let match else { return }
            guard !hasLinkAttribute(in: attributedText, range: match.range) else { return }

            let handleWithPrefix = nsText.substring(with: match.range)
            let handle = String(handleWithPrefix.dropFirst())
            guard !handle.isEmpty else { return }

            let encodedHandle = handle.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? handle
            guard let url = URL(string: "mention://\(encodedHandle)") else { return }
            applyLinkAttributes(url: url, range: match.range, on: attributedText, underline: false)
        }
    }

    private func applyLinkAttributes(
        url: URL,
        range: NSRange,
        on attributedText: NSMutableAttributedString,
        underline: Bool = true
    ) {
        var attributes: [NSAttributedString.Key: Any] = [
            .link: url,
            .foregroundColor: PlatformColor.platformLink
        ]

        if underline {
            attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
        }

        attributedText.addAttributes(attributes, range: range)
    }

    private func hasLinkAttribute(in attributedText: NSMutableAttributedString, range: NSRange) -> Bool {
        var hasLink = false
        attributedText.enumerateAttribute(.link, in: range, options: []) { value, _, stop in
            if value != nil {
                hasLink = true
                stop.pointee = true
            }
        }
        return hasLink
    }
    
    private var editProfileButton: some View {
        Button(action: {
            isEditingProfile = true
        }) {
            Text("Edit Profile")
                .appFont(AppTextRole.subheadline)
                .fontWeight(.medium)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .foregroundColor(Color("AccentTextColor"))
        }
        .background(
            Capsule()
                .stroke(Color.accentColor, lineWidth: 1.5)
        )
    }
    
    @ViewBuilder
    private var followButton: some View {
        if isFollowButtonLoading {
            ProgressView()
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
        } else if profile.viewer?.blocking != nil || profile.viewer?.blockedBy == true {
            // Show blocked state instead of follow button. Neutral styling —
            // direction (you blocked them / they blocked you / mutual) is
            // carried by the block relationship banner's text, not this pill.
            Button(action: {
                // Do nothing - blocking handled in parent view
            }) {
                HStack {
                    Image(systemName: "person.crop.circle.badge.xmark")
                        .appFont(AppTextRole.footnote)
                    Text("Blocked")
                        .fixedSize(horizontal: true, vertical: false)
                }
                .appFont(AppTextRole.subheadline)
                .fontWeight(.medium)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .foregroundColor(.secondary)
                .cornerRadius(16)
            }
            .background(
                Capsule()
                    .stroke(Color.secondary, lineWidth: 1.5)
            )
        } else if profile.viewer?.muted == true {
            // Show muted state
            Button(action: {
                // Do nothing - muting handled in parent view
            }) {
                HStack {
                    Image(systemName: "speaker.slash")
                        .appFont(AppTextRole.footnote)
                    Text("Muted")
                        .fixedSize(horizontal: true, vertical: false)
                }
                .appFont(AppTextRole.subheadline)
                .fontWeight(.medium)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .foregroundColor(.orange)
                .cornerRadius(16)
            }
            .background(
                Capsule()
                    .stroke(Color.orange, lineWidth: 1.5)
            )
        } else if localIsFollowing {
            Button(action: {
                if DestructiveActionConfirmation.shouldConfirm(
                    isEnabled: appState.appSettings.confirmBeforeActions
                ) {
                    showUnfollowConfirmation = true
                } else {
                    performUnfollow()
                }
            }) {
                HStack {
                    Image(systemName: "checkmark")
                        .appFont(AppTextRole.footnote)
                    Text("Following")
                        .fixedSize(horizontal: true, vertical: false)
                }
                .appFont(AppTextRole.subheadline)
                .fontWeight(.medium)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .foregroundColor(Color("AccentTextColor"))
                .cornerRadius(16)
            }
            .background(
                Capsule()
                    .stroke(Color.accentColor, lineWidth: 1.5)
            )
            
        } else {
            Button(action: {
                Task(priority: .userInitiated) {  // Explicit priority
                    isFollowButtonLoading = true
                    
                    // Optimistically update UI
                    localIsFollowing = true
                    
                    do {
                        // Perform follow operation
                        let success = try await appState.follow(did: profile.did.didString())
                        
                        if success {
                            showingSuggestedFollows = true
                            // Add a small delay before reloading
                            try? await Task.sleep(for: .seconds(0.5))
                            await viewModel.loadProfile()
                        } else {
                            localIsFollowing = false
                        }
                    } catch {
                        // Log error and revert local state
                        logger.debug("Error following: \(error.localizedDescription)")
                        localIsFollowing = false
                    }
                    
                    isFollowButtonLoading = false
                }
            }) {
                HStack {
                    Image(systemName: "plus")
                        .appFont(AppTextRole.footnote)
                    Text("Follow")
                }
                .appFont(AppTextRole.subheadline)
                .fontWeight(.medium)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(Color.accentColor)
                .foregroundColor(.white)
                .cornerRadius(16)
            }
        }
    }
    
    // MARK: - Labeler Buttons
    
    @State private var isSubscribeButtonLoading = false
    @State private var isLikeButtonLoading = false
    
    @ViewBuilder
    private var subscribeButton: some View {
        Group {
            if isSubscribeButtonLoading {
                ProgressView()
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
            } else if viewModel.isSubscribedToLabeler {
                Button(action: {
                    Task(priority: .userInitiated) {
                        isSubscribeButtonLoading = true
                        do {
                            try await viewModel.unsubscribeFromLabeler()
                        } catch {
                            logger.error("Error unsubscribing from labeler: \(error.localizedDescription)")
                        }
                        isSubscribeButtonLoading = false
                    }
                }) {
                    HStack {
                        Image(systemName: "checkmark")
                            .appFont(AppTextRole.footnote)
                        Text("Subscribed")
                            .fixedSize(horizontal: true, vertical: false)
                    }
                    .appFont(AppTextRole.subheadline)
                    .fontWeight(.medium)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .foregroundColor(Color("AccentTextColor"))
                    .cornerRadius(16)
                }
                .background(
                    Capsule()
                        .stroke(Color.accentColor, lineWidth: 1.5)
                )
            } else {
                Button(action: {
                    Task(priority: .userInitiated) {
                        isSubscribeButtonLoading = true
                        do {
                            try await viewModel.subscribeToLabeler()
                        } catch {
                            logger.error("Error subscribing to labeler: \(error.localizedDescription)")
                        }
                        isSubscribeButtonLoading = false
                    }
                }) {
                    HStack {
                        Image(systemName: "plus")
                            .appFont(AppTextRole.footnote)
                        Text("Subscribe")
                    }
                    .appFont(AppTextRole.subheadline)
                    .fontWeight(.medium)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(Color.accentColor)
                    .foregroundColor(.white)
                    .cornerRadius(16)
                }
            }
        }
    }
    @ViewBuilder
    private var labelerLikeButton: some View {
        HStack(spacing: 8) {
            Button(action: {
                Task(priority: .userInitiated) {
                    isLikeButtonLoading = true
                    do {
                        if viewModel.isLabelerLiked {
                            try await viewModel.unlikeLabeler()
                        } else {
                            try await viewModel.likeLabeler()
                        }
                    } catch {
                        logger.error("Error toggling labeler like: \(error.localizedDescription)")
                    }
                    isLikeButtonLoading = false
                }
            }) {
                HStack(spacing: 6) {
                    if isLikeButtonLoading {
                        ProgressView()
                            .frame(width: 16, height: 16)
                    } else {
                        Image(systemName: viewModel.isLabelerLiked ? "heart.fill" : "heart")
                            .foregroundStyle(viewModel.isLabelerLiked ? .red : .primary)
                    }
                }
                .padding(8)
                .background(
                    Circle()
                        .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
            .disabled(isLikeButtonLoading)
            .accessibilityLabel(viewModel.isLabelerLiked ? "Unlike labeler" : "Like labeler")
            
            if viewModel.labelerLikeCount > 0, let labelerUri = viewModel.labelerDetails?.uri {
                Button {
                    path.append(NavigationDestination.postLikes(labelerUri.uriString()))
                } label: {
                    Text("\(viewModel.labelerLikeCount)")
                        .appCaption()
                        .foregroundColor(.secondary)
                        .padding(.vertical, 6)
                        .padding(.horizontal, 10)
                        .background(
                            Capsule()
                                .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
                .accessibilityLabel("View subscribers")
                .accessibilityHint("Opens list of users who subscribed to or liked this labeler")
            }
        }
    }
    private func getAvatarModerationState(_ labels: [ComAtprotoLabelDefs.Label]?) -> AvatarModerationState {
        guard let labels = labels, !labels.isEmpty else { return .show }
        
        // Check if any adult content labels present
        let hasAdultLabels = labels.contains { label in
            let lowercasedValue = label.val.lowercased()
            return ["porn", "nsfw", "nudity", "sexual"].contains(lowercasedValue)
        }
        
        guard hasAdultLabels else { return .show }
        
        // CRITICAL: If user is a minor (adult content disabled), HIDE the avatar completely
        if !appState.isAdultContentEnabled {
            return .hide
        }
        
        // User is an adult - check their granular preferences
        if let preferences = try? appState.preferencesManager.getLocalPreferences() {
            // Find the most restrictive setting among adult labels
            var mostRestrictive: ContentVisibility = .show
            
            for label in labels {
                let labelValue = label.val.lowercased()
                guard ["porn", "nsfw", "nudity", "sexual"].contains(labelValue) else { continue }
                
                // Map label to preference key
                let preferenceKey: String
                switch labelValue {
                case "porn", "nsfw", "sexual":
                    preferenceKey = "nsfw"
                case "nudity":
                    preferenceKey = "nudity"
                default:
                    preferenceKey = labelValue
                }
                
                // Get visibility for this label
                let visibility = ContentFilterManager.getVisibilityForLabel(
                    label: preferenceKey,
                    labelerDid: label.src,
                    preferences: preferences.contentLabelPrefs
                )
                
                // Track most restrictive
                switch (mostRestrictive, visibility) {
                case (_, .hide):
                    mostRestrictive = .hide
                case (.show, .warn):
                    mostRestrictive = .warn
                default:
                    break
                }
            }
            
            // Convert ContentVisibility to AvatarModerationState
            switch mostRestrictive {
            case .hide:
                return .hide
            case .warn:
                return .blur
            case .show:
                return .show
            }
        }
        
        // Fallback: if preferences unavailable for adult, blur by default (conservative)
        return .blur
    }
}

