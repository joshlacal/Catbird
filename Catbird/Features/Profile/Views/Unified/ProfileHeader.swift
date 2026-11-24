import Combine
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
    @Environment(\.moderationPolicy) private var moderationPolicy
    @Environment(\.displayScale) private var displayScale

    private static let bioLinkDetector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
    private static let bioHandleRegex = try? NSRegularExpression(pattern: "(?<![\\w@])@[A-Za-z0-9][A-Za-z0-9.-]*", options: [.caseInsensitive])
    /// What the Follow button shows. It flips on tap; `viewModel.followWrites` keeps it from
    /// flipping back while the write and the AppView catch up.
    @State private var localIsFollowing = false
    @State private var localActivitySubscription: AppBskyNotificationDefs.ActivitySubscription?
    @State private var isActivitySubscriptionLoading = false
    @State private var activitySubscriptionError: String?
    @State private var isShowingProfileImageViewer = false
    @State private var verificationInfoKind: VerificationBadgeKind?
    @State private var showUnfollowConfirmation = false
    @State private var showingSuggestedFollows = false
    @State private var suggestedFollows: [AppBskyActorDefs.ProfileView] = []
    @State private var showingAccountLabels = false
    @State private var selectedAccountLabelID: String?
    @State private var chatOpeningTask: Task<Void, Never>?
    @State private var isOpeningChat = false
    @State private var chatOpenError: String?
    @State private var chatOperationID: UUID?
    @Environment(SceneNavigationContext.self) private var sceneContext
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
            }
        }
#if os(iOS)
        .fullScreenCover(isPresented: $isShowingProfileImageViewer) {
            if let profile = viewModel.profile, !isAvatarConcealed {
                ProfileImageViewerView(avatar: profile.avatar, isPresented: $isShowingProfileImageViewer, namespace: imageTransition)
                    .navigationTransition(.zoom(sourceID: profile.avatar?.uriString() ?? "", in: imageTransition))
            }
        }
        .presentationBackground(.black)
#elseif os(macOS)
        .sheet(isPresented: $isShowingProfileImageViewer) {
            if let profile = viewModel.profile, !isAvatarConcealed {
                ProfileImageViewerView(avatar: profile.avatar, isPresented: $isShowingProfileImageViewer, namespace: imageTransition)
            }
        }
#endif
        .onChange(of: isAvatarConcealed) { _, isConcealed in
            if isConcealed { isShowingProfileImageViewer = false }
        }
        .sheet(item: $verificationInfoKind) { kind in
            VerificationInfoSheet(
                kind: kind,
                displayName: profile.displayName ?? profile.handle.description,
                verifications: profile.verification?.verifications ?? []
            )
        }
        .sheet(isPresented: $showingAccountLabels) {
            if let client = appState.atProtoClient {
                LabelsOnMeView(
                    labels: inspectedAccountLabels,
                    targetDescription: String(
                        localized: "Account @\(profile.handle)",
                        comment: "Target description in the account moderation labels sheet — %1$@ is the account handle (without @)."
                    ),
                    viewerDID: appState.userDID,
                    reportingService: ReportingService(client: client)
                )
            }
        }
        .alert("Bluesky Chat", isPresented: Binding(
            get: { chatOpenError != nil },
            set: { if !$0 { chatOpenError = nil } }
        )) {
            Button("OK", role: .cancel) { chatOpenError = nil }
        } message: {
            Text(chatOpenError ?? "")
        }
        .onReceive(NotificationCenter.default.publisher(for: ProfileLabelRefresh.notificationName).receive(on: DispatchQueue.main)) { notification in
            guard ProfileLabelRefresh.matches(
                notification, preferencesManager: appState.preferencesManager,
                viewerDID: appState.userDID, isActiveViewer: isActiveProfileViewer
            ) else { return }
            Task { @MainActor in
                guard isActiveProfileViewer else { return }
                await viewModel.loadProfile()
            }
        }
        .onChange(of: isActiveProfileViewer) { _, isActive in
            if !isActive {
                cancelChatOpening()
                showingAccountLabels = false
                selectedAccountLabelID = nil
            }
        }
        .onAppear {
            localIsFollowing = viewModel.followWrites.isFollowing(serverSays: profile.viewer?.following != nil)
            updateLocalActivitySubscription()
        }
        .onChange(of: profile) { _, newProfile in
            localIsFollowing = viewModel.followWrites.isFollowing(serverSays: newProfile.viewer?.following != nil)
            updateLocalActivitySubscription()
        }
        .onChange(of: viewModel.followWrites.revision) { _, _ in
            localIsFollowing = viewModel.followWrites.isFollowing(serverSays: profile.viewer?.following != nil)
        }
        .onChange(of: activitySubscriptionSnapshot) { _, _ in
            updateLocalActivitySubscription()
        }
        .onChange(of: canOfferChat) { _, canOpen in
            if !canOpen { cancelChatOpening() }
        }
        .onChange(of: profile.did) { _, _ in cancelChatOpening() }
        .onChange(of: AppStateManager.shared.settingsAccountContextRevision) { _, _ in cancelChatOpening() }
        .onDisappear { cancelChatOpening() }
        .alert("Unfollow", isPresented: $showUnfollowConfirmation) {
            Button("Cancel", role: .cancel) { }
            Button("Unfollow", role: .destructive) { performUnfollow() }
        } message: {
            Text(
                "Unfollow @\(profile.handle)? You'll stop seeing their posts in your following feed.",
                comment: "Confirmation message when unfollowing a user — %1$@ is the user's handle (without @)."
            )
        }
        .sheet(isPresented: $showingSuggestedFollows) {
            ContextualSuggestedFollowsSheet(
                actorDID: profile.did.didString(),
                actorHandle: profile.handle.description,
                path: $path,
                initialSuggestions: suggestedFollows
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
    
    private var subscriptionButtonAccessibilityLabel: LocalizedStringResource {
        switch currentActivitySubscriptionState {
        case .none:
            return LocalizedStringResource("Activity notifications off", comment: "Accessibility label when activity notifications for a profile are disabled.")
        case .postsOnly:
            return LocalizedStringResource("Activity notifications for posts", comment: "Accessibility label when activity notifications are enabled for posts only.")
        case .postsAndReplies:
            return LocalizedStringResource("Activity notifications for posts and replies", comment: "Accessibility label when activity notifications are enabled for both posts and replies.")
        case .repliesOnly:
            return LocalizedStringResource("Activity notifications for replies", comment: "Accessibility label when activity notifications are enabled for replies only.")
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
                        .padding(9)
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
                    activitySubscriptionError = String(
                        localized: "Couldn’t update notifications for this account.",
                        comment: "Error message shown on a profile header when updating activity notification preferences fails."
                    )
                }
            }

            await MainActor.run {
                isActivitySubscriptionLoading = false
            }
        }
    }

    /// Follows at once: the button shows Following on tap, suggestions load alongside the
    /// write, and the header reloads its counts afterwards without holding the button.
    private func performFollow() {
        let writes = viewModel.followWrites
        guard writes.begin(following: true) else { return }
        localIsFollowing = true
        let did = profile.did.didString()
        let suggestions = Task { await fetchSuggestedFollows() }

        Task(priority: .userInitiated) {
            let success: Bool
            do {
                success = try await appState.follow(did: did)
            } catch {
                logger.debug("Error following: \(error.localizedDescription)")
                success = false
            }
            writes.end(success: success)
            localIsFollowing = success

            guard success else {
                suggestions.cancel()
                return
            }
            viewModel.refreshHeaderAfterFollowWrite()

            let found = await suggestions.value
            if !found.isEmpty {
                suggestedFollows = found
                showingSuggestedFollows = true
            }
        }
    }

    /// Unfollows at once. It deletes the follow record GraphManager last created for this
    /// account when it has one (after Follow > Unfollow > Follow that is newer than the
    /// profile's `viewer.following`), then the one the profile names, then looks it up.
    private func performUnfollow() {
        let writes = viewModel.followWrites
        guard writes.begin(following: false) else { return }
        localIsFollowing = false
        let did = profile.did.didString()
        let followURI = appState.graphManager.followingCache[did] ?? profile.viewer?.following

        Task(priority: .userInitiated) {
            let success: Bool
            do {
                if let followURI {
                    success = try await appState.graphManager.unfollowByUri(followingUri: followURI)
                } else {
                    success = try await appState.unfollow(did: did)
                }
            } catch {
                logger.debug("Error unfollowing: \(error.localizedDescription)")
                success = false
            }
            writes.end(success: success)
            localIsFollowing = !success

            if success {
                viewModel.refreshHeaderAfterFollowWrite()
            }
        }
    }

    /// Similar accounts to show after a follow; empty when there is nothing to suggest.
    private func fetchSuggestedFollows() async -> [AppBskyActorDefs.ProfileView] {
        guard let client = appState.atProtoClient else { return [] }
        do {
            return try await ContextualSuggestedFollowsSheet.fetchSuggestions(
                client: client,
                actorDID: profile.did.didString(),
                currentUserDID: appState.userDID
            )
        } catch {
            logger.debug("Suggested follows unavailable: \(error.localizedDescription)")
            return []
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
    
    /// Whether the moderation policy blurs this profile's avatar. A blurred
    /// avatar is never loaded and never opens the full-size viewer.
    private var isAvatarConcealed: Bool {
        moderationPolicy.concealsAvatar(did: profile.did.didString(), labels: profile.labels)
    }

    private var avatarView: some View {
        let isConcealed = isAvatarConcealed
        let canOpenAvatarViewer = !isConcealed && profile.avatar != nil
        
        return Group {
            if isLabeler {
                // Square avatar for labelers
                Group {
                    if isConcealed {
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
                        let avatarURL = profile.avatar.flatMap { URL(string: $0.uriString()) }
                        LazyImage(request: ImageRequestFactory.avatar(avatarURL, pointSize: avatarSize, scale: displayScale)) { state in
                            if let image = state.image {
                                image.resizable().aspectRatio(contentMode: .fill)
                            } else {
                                RoundedRectangle(cornerRadius: 12).fill(Color.secondary.opacity(0.3))
                            }
                        }
                        .matchedTransitionSource(id: profile.avatar?.uriString() ?? "", in: imageTransition)
                    }
                }
                .onTapGesture {
                    if canOpenAvatarViewer {
                        isShowingProfileImageViewer = true
                    }
                }
                .modifier(AvatarViewerAccessibility(isEnabled: canOpenAvatarViewer))
                .frame(width: avatarSize, height: avatarSize)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .background(
                    RoundedRectangle(cornerRadius: 16)
                        .fill(Color.dynamicBackground(appState.themeManager, currentScheme: colorScheme))
                        .padding(-4)
                )
                .zIndex(10)
            } else {
                // Circular avatar for regular users
                Group {
                    if isConcealed {
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
                        let avatarURL = profile.avatar.flatMap { URL(string: $0.uriString()) }
                        LazyImage(request: ImageRequestFactory.avatar(avatarURL, pointSize: avatarSize, scale: displayScale)) { state in
                            if let image = state.image {
                                image.resizable().aspectRatio(contentMode: .fill)
                            } else {
                                Circle().fill(Color.secondary.opacity(0.3))
                            }
                        }
                        .matchedTransitionSource(id: profile.avatar?.uriString() ?? "", in: imageTransition)
                    }
                }
                .onTapGesture {
                    if canOpenAvatarViewer {
                        isShowingProfileImageViewer = true
                    }
                }
                .modifier(AvatarViewerAccessibility(isEnabled: canOpenAvatarViewer))
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
                        if canOfferChat {
                            messageButton
                        }
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
                    Text(profile.displayName.flatMap {
                        $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0
                    } ?? profile.handle.description)
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
                    if AutomationBadge.isSelfDeclared(labels: profile.labels, authorDID: profile.did) {
                        AutomationBadgeView(size: 18, relativeTo: .headline)
                            .layoutPriority(1)
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
                    Text(verbatim: "@\(profile.handle)")
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

                    if !viewModel.isCurrentUser && profile.viewer?.muted == true {
                        Label {
                            Text("Muted", comment: "Status badge shown on a profile when the viewer has muted this account.")
                        } icon: {
                            Image(systemName: "speaker.slash")
                        }
                            .appFont(AppTextRole.caption)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(Color.secondary.opacity(0.15))
                            )
                    }
                }
            }
            
            if !visibleAccountLabels.isEmpty {
                if viewModel.isCurrentUser {
                    Button {
                        selectedAccountLabelID = nil
                        showingAccountLabels = true
                    } label: {
                        Label("\(visibleAccountLabels.count) account labels", systemImage: "tag")
                            .font(.subheadline)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
                    .padding(.vertical, 4)
                    .accessibilityHint("Opens label names, issuing services, and eligible appeals")
                } else {
                    ProfileAccountLabelsView(
                        labels: visibleAccountLabels,
                        viewerDID: appState.userDID,
                        isActiveViewer: { isActiveProfileViewer },
                        onSelectLabel: { label in
                            selectedAccountLabelID = label.id
                            showingAccountLabels = true
                        }
                    )
                    .environment(appState)
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
            
            // Keep each count and caption intact; use rows when the group cannot fit.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 24) {
                    profileStatistics
                }
                .fixedSize(horizontal: true, vertical: false)

                VStack(alignment: .leading, spacing: 12) {
                    profileStatistics
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

        }
    }

    @ViewBuilder
    private var profileStatistics: some View {
        Button {
            path.append(ProfileNavigationDestination.following(profile.did.didString()))
        } label: {
            profileStatistic(
                count: profile.followsCount ?? 0,
                title: LocalizedStringResource("Following", comment: "Profile statistic label for the number of accounts this user follows.")
            )
        }
        .buttonStyle(.plain)

        Button {
            path.append(ProfileNavigationDestination.followers(profile.did.didString()))
        } label: {
            profileStatistic(
                count: profile.followersCount ?? 0,
                title: LocalizedStringResource("Followers", comment: "Profile statistic label for the number of accounts following this user.")
            )
        }
        .buttonStyle(.plain)

        if let postsCount = profile.postsCount {
            profileStatistic(
                count: postsCount,
                title: LocalizedStringResource("Posts", comment: "Profile statistic label for the number of posts published by this user.")
            )
        }
    }

    private func profileStatistic(count: Int, title: LocalizedStringResource) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 6) {
                profileStatisticText(count: count, title: title)
            }
            .fixedSize(horizontal: true, vertical: true)

            VStack(alignment: .leading, spacing: 4) {
                profileStatisticText(count: count, title: title)
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func profileStatisticText(count: Int, title: LocalizedStringResource) -> some View {
        Text(count, format: .number.notation(.compactName))
            .appFont(AppTextRole.subheadline)
            .fontWeight(.semibold)
        Text(title)
            .appFont(AppTextRole.subheadline)
            .foregroundStyle(.secondary)
    }

    private var isActiveProfileViewer: Bool {
        viewModel.currentUserDID == appState.userDID
            && AppStateManager.shared.lifecycle.appState === appState
            && !AppStateManager.shared.authentication.isSwitchingAccount
    }

    private var visibleAccountLabels: [ComAtprotoLabelDefs.Label] {
        guard isActiveProfileViewer else { return [] }
        return AccountLabelPresentation.accountLabels(profile.labels ?? [], subjectDID: profile.did.didString(), subscribedIssuers: Set(subscribedLabelerDIDs))
    }

    private var inspectedAccountLabels: [ComAtprotoLabelDefs.Label] {
        guard let selectedAccountLabelID else { return visibleAccountLabels }
        return visibleAccountLabels.filter { $0.id == selectedAccountLabelID }
    }

    private var subscribedLabelerDIDs: [String] {
        let preferences = try? appState.preferencesManager.getLocalPreferences()
        return ((preferences?.labelers.map { $0.did.didString() } ?? []) + [ReportingService.officialBlueskyDID]).sorted()
    }

    private var canOfferChat: Bool {
        guard isActiveProfileViewer, !sceneContext.isInvalidated,
              sceneContext.accountDID == appState.userDID,
              profile.did.didString() != appState.userDID,
              profile.viewer?.blocking == nil,
              profile.viewer?.blockedBy != true,
              profile.viewer?.blockingByList == nil else { return false }
        // Bluesky DM preferences govern only the Bluesky option. They must not
        // hide an existing encrypted chat or the encrypted-chat choice.
        return true
    }

    private func cancelChatOpening() {
        chatOpeningTask?.cancel()
        chatOpeningTask = nil
        chatOperationID = nil
        isOpeningChat = false
        chatOpenError = nil
    }

    private func openChat() {
        guard canOfferChat, !isOpeningChat else { return }
        let sourceAppState = appState
        let chatManager = appState.chatManager
        let context = sceneContext
        let viewerDID = appState.userDID
        let targetDID = profile.did.didString()
        let revision = AppStateManager.shared.settingsAccountContextRevision
        let operationID = UUID()
        chatOperationID = operationID
        isOpeningChat = true
        chatOpenError = nil
        chatOpeningTask = Task { @MainActor in
            defer {
                if chatOperationID == operationID {
                    chatOpeningTask = nil
                    chatOperationID = nil
                    isOpeningChat = false
                }
            }
            guard !Task.isCancelled, chatOperationID == operationID,
                  AppStateManager.shared.lifecycle.appState === sourceAppState,
                  appState === sourceAppState, appState.chatManager === chatManager,
                  appState.userDID == viewerDID,
                  SettingsAccountBoundary.isCurrent(viewerDID, revision: revision),
                  profile.did.didString() == targetDID, canOfferChat,
                  sceneContext === context, !context.isInvalidated,
                  context.accountDID == viewerDID else { return }
            // Read both kinds of existing conversation; nothing is created here.
            let recipient = NewConversationRecipient(profile: profile)
            let blueskyConvo = await chatManager.existingProfileConversation(
                with: targetDID, expectedViewerDID: viewerDID
            )
            let encrypted = await ExistingConversationFinder.encryptedDirect(
                with: targetDID, appState: sourceAppState
            )
            guard !Task.isCancelled, chatOperationID == operationID,
                  AppStateManager.shared.lifecycle.appState === sourceAppState,
                  appState === sourceAppState, appState.chatManager === chatManager,
                  appState.userDID == viewerDID,
                  SettingsAccountBoundary.isCurrent(viewerDID, revision: revision),
                  profile.did.didString() == targetDID, canOfferChat,
                  sceneContext === context, !context.isInvalidated,
                  context.accountDID == viewerDID else { return }
            let destination = ChatEntryRouter.destination(
                for: recipient,
                bluesky: ExistingConversationFinder.blueskyDirect(blueskyConvo),
                encrypted: encrypted
            )
            // The operation is complete before tab selection makes this profile disappear.
            chatOpeningTask = nil
            chatOperationID = nil
            isOpeningChat = false
            let navigation = context.navigationManager
            if case .newConversation(let recipient) = destination {
                navigation.pendingNewConversationRecipient = recipient
                return
            }
            navigation.updateCurrentTab(AppNavigationManager.chatTabIndex)
            navigation.tabSelection?(AppNavigationManager.chatTabIndex)
            // Tab selection can synchronously retire the source account or scene.
            guard !Task.isCancelled,
                  AppStateManager.shared.lifecycle.appState === sourceAppState,
                  SettingsAccountBoundary.isCurrent(viewerDID, revision: revision),
                  profile.did.didString() == targetDID,
                  appState.userDID == viewerDID, canOfferChat,
                  !context.isInvalidated, context.accountDID == viewerDID,
                  sceneContext === context else { return }
            switch destination {
            case .bluesky(let convoID):
                #if os(iOS)
                navigation.navigate(to: .conversation(convoID), in: AppNavigationManager.chatTabIndex)
                #elseif os(macOS)
                navigation.targetConversationId = convoID
                #endif
            case .encrypted(let conversationID):
                ExistingConversationFinder.revealIfHidden(conversationID, accountDID: viewerDID)
                #if os(iOS)
                navigation.navigate(to: .mlsConversation(conversationID), in: AppNavigationManager.chatTabIndex)
                #elseif os(macOS)
                navigation.targetMLSConversationId = conversationID
                #endif
            case .newConversation:
                break
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

        return AttributedString(attributedBio).applyingPostBodyLinkAccent(
            highlightLinks: appState.appSettings.highlightLinks,
            linkStyle: appState.appSettings.linkStyle
        )
    }

    private func applyDetectedLinks(in text: String, to attributedText: NSMutableAttributedString) {
        guard let detector = Self.bioLinkDetector else {
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
        guard let regex = Self.bioHandleRegex else {
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
            applyLinkAttributes(url: url, range: match.range, on: attributedText)
        }
    }

    private func applyLinkAttributes(
        url: URL,
        range: NSRange,
        on attributedText: NSMutableAttributedString
    ) {
        attributedText.addAttribute(.link, value: url, range: range)
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
                .padding(.vertical, 9)
                .foregroundColor(Color("AccentTextColor"))
        }
        .background(
            Capsule()
                .stroke(Color.accentColor, lineWidth: 1.5)
        )
    }
    
    /// Circular chat button that sits to the left of Follow. It, the bell and the
    /// Follow / Following / Edit Profile pills all render 36pt tall.
    private var messageButton: some View {
        Button(action: openChat) {
            Group {
                if isOpeningChat {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: "message")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Color("AccentTextColor"))
                }
            }
            .frame(width: 18, height: 18)
            .padding(9)
            .overlay(
                Circle()
                    .stroke(Color.accentColor, lineWidth: 1.5)
            )
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(isOpeningChat)
        .accessibilityLabel(
            isOpeningChat
                ? Text("Opening chat with @\(profile.handle)", comment: "Accessibility label while opening a chat from a profile — %1$@ is the user's handle (without @).")
                : Text("Message @\(profile.handle)", comment: "Accessibility label for the button to message a user — %1$@ is the user's handle (without @).")
        )
        .accessibilityHint(Text("Opens a conversation without sending a message", comment: "Accessibility hint for the profile message button."))
    }

    @ViewBuilder
    private var followButton: some View {
        if profile.viewer?.blocking != nil || profile.viewer?.blockedBy == true {
            // Show blocked state instead of follow button. Neutral styling —
            // direction (you blocked them / they blocked you / mutual) is
            // carried by the block relationship banner's text, not this pill.
            HStack {
                Image(systemName: "person.crop.circle.badge.xmark")
                    .appFont(AppTextRole.footnote)
                Text("Blocked", comment: "Disabled pill shown in place of the Follow button when a block exists between accounts.")
                    .fixedSize(horizontal: true, vertical: false)
            }
            .appFont(AppTextRole.subheadline)
            .fontWeight(.medium)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .foregroundColor(.secondary)
            .background(
                Capsule()
                    .stroke(Color.secondary, lineWidth: 1.5)
            )
            .accessibilityElement(children: .combine)
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
                    Text("Following", comment: "Active button state indicating the viewer currently follows this profile; tapping unfollows.")
                        .fixedSize(horizontal: true, vertical: false)
                }
                .appFont(AppTextRole.subheadline)
                .fontWeight(.medium)
                .padding(.horizontal, 16)
                .padding(.vertical, 9)
                .foregroundColor(Color("AccentTextColor"))
                .cornerRadius(16)
            }
            .background(
                Capsule()
                    .stroke(Color.accentColor, lineWidth: 1.5)
            )
            
        } else {
            Button(action: {
                performFollow()
            }) {
                HStack {
                    Image(systemName: "plus")
                        .appFont(AppTextRole.footnote)
                    Text("Follow", comment: "Action button verb to start following a user profile.")
                }
                .appFont(AppTextRole.subheadline)
                .fontWeight(.medium)
                .padding(.horizontal, 16)
                .padding(.vertical, 9)
                .foregroundColor(.white)
                .background(Capsule().fill(Color.accentColor))
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
                            appState.toastManager.show(
                                ToastItem(
                                    message: String(localized: "Couldn’t unsubscribe. Try again.", comment: "Toast shown when unsubscribing from a moderation labeler fails."),
                                    icon: "exclamationmark.triangle.fill"
                                )
                            )
                        }
                        isSubscribeButtonLoading = false
                    }
                }) {
                    HStack {
                        Image(systemName: "checkmark")
                            .appFont(AppTextRole.footnote)
                        Text("Subscribed", comment: "Active button state indicating the viewer is subscribed to this moderation labeler.")
                            .fixedSize(horizontal: true, vertical: false)
                    }
                    .appFont(AppTextRole.subheadline)
                    .fontWeight(.medium)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 9)
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
                            appState.toastManager.show(
                                ToastItem(
                                    message: String(localized: "Couldn’t subscribe. Try again.", comment: "Toast shown when subscribing to a moderation labeler fails."),
                                    icon: "exclamationmark.triangle.fill"
                                )
                            )
                        }
                        isSubscribeButtonLoading = false
                    }
                }) {
                    HStack {
                        Image(systemName: "plus")
                            .appFont(AppTextRole.footnote)
                        Text("Subscribe", comment: "Action button verb to subscribe to a moderation labeler.")
                    }
                    .appFont(AppTextRole.subheadline)
                    .fontWeight(.medium)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 9)
                    .foregroundColor(.white)
                    .background(Capsule().fill(Color.accentColor))
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
                        appState.toastManager.show(
                            ToastItem(
                                message: String(localized: "Couldn’t update like. Try again.", comment: "Toast shown when liking or unliking a moderation labeler fails."),
                                icon: "exclamationmark.triangle.fill"
                            )
                        )
                    }
                    isLikeButtonLoading = false
                }
            }) {
                Group {
                    if isLikeButtonLoading {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: viewModel.isLabelerLiked ? "heart.fill" : "heart")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(viewModel.isLabelerLiked ? .red : .primary)
                    }
                }
                .frame(width: 18, height: 18)
                .padding(9)
                .overlay(
                    Circle()
                        .stroke(Color.accentColor, lineWidth: 1.5)
                )
                .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(isLikeButtonLoading)
            .accessibilityLabel(
                viewModel.isLabelerLiked
                    ? Text("Unlike labeler", comment: "Accessibility label for button to remove a like from a moderation labeler.")
                    : Text("Like labeler", comment: "Accessibility label for button to like a moderation labeler.")
            )
            
            if viewModel.labelerLikeCount > 0, let labelerUri = viewModel.labelerDetails?.uri {
                Button {
                    path.append(NavigationDestination.postLikes(labelerUri.uriString()))
                } label: {
                    Text(viewModel.labelerLikeCount, format: .number)
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
}


// MARK: - Avatar Accessibility

private struct AvatarViewerAccessibility: ViewModifier {
    let isEnabled: Bool

    func body(content: Content) -> some View {
        if isEnabled {
            content
                .accessibilityAddTraits(.isButton)
                .accessibilityLabel("View Profile Picture")
        } else {
            content
        }
    }
}
