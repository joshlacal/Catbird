import SwiftUI
import Petrel
import OSLog

struct FeedDiscoveryHeaderView: View {
  @Environment(AppState.self) private var appState
  let feed: AppBskyFeedDefs.GeneratorView
  let isSubscribed: Bool
  let onSubscriptionToggle: () async -> Void
  
  @State private var isTogglingSubscription = false
  @State private var showingDescription = false
  
  private let logger = Logger(subsystem: "blue.catbird", category: "FeedDiscoveryHeaderView")
  
  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      headerRow
      descriptionSection
      actionButtons
    }
    .padding(20)
    .background(
      // Simplified background for debugging - removed shadow that might block touches
      Rectangle()
        .fill(Color(.systemBackground))
    )
    .overlay(
      Rectangle()
        .stroke(Color(.separator).opacity(0.1), lineWidth: 0.5)
    )
    // Removed explicit hit testing configurations - let SwiftUI handle naturally
  }
  
  private var headerRow: some View {
    HStack(alignment: .top, spacing: 16) {
      feedAvatar
      feedInfo
      Spacer()
      subscribeButton
    }
  }
  
  private var feedAvatar: some View {
    AsyncImage(url: URL(string: feed.avatar?.uriString() ?? "")) { image in
      image
        .resizable()
        .scaledToFill()
    } placeholder: {
      feedPlaceholder
    }
    .frame(width: 56, height: 56)
    .clipShape(RoundedRectangle(cornerRadius: 12))
    .overlay(
      RoundedRectangle(cornerRadius: 12)
        .stroke(Color(.separator).opacity(0.2), lineWidth: 0.5)
    )
  }
  
  private var feedPlaceholder: some View {
    ZStack {
      LinearGradient(
        colors: [Color.accentColor.opacity(0.7), Color.accentColor.opacity(0.5)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
      )
      
      Text(feed.displayName.prefix(1).uppercased())
        .appFont(AppTextRole.title2)
        .fontWeight(.bold)
        .foregroundColor(.white)
    }
  }
  
  private var feedInfo: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(feed.displayName)
        .appFont(AppTextRole.headline)
        .fontWeight(.semibold)
        .lineLimit(2)
      
      Text("by @\(feed.creator.handle.description)")
        .appFont(AppTextRole.subheadline)
        .foregroundColor(.secondary)
      
      if let likeCount = feed.likeCount {
        HStack(spacing: 4) {
          Image(systemName: "heart.fill")
            .foregroundColor(.pink)
            .appFont(AppTextRole.caption)
          Text(formatCount(likeCount))
            .appFont(AppTextRole.caption)
            .foregroundColor(.secondary)
        }
      }
    }
  }
  
  private var subscribeButton: some View {
    Button {
      Task { await toggleSubscription() }
    } label: {
      HStack(spacing: 6) {
        if isTogglingSubscription {
          ProgressView()
            .scaleEffect(0.8)
        } else {
          Text(isSubscribed ? "Subscribed" : "Subscribe")
            .appFont(AppTextRole.subheadline)
            .fontWeight(.semibold)
        }
      }
      .foregroundColor(isSubscribed ? .green : .white)
      .padding(.horizontal, 16)
      .padding(.vertical, 8)
      .background(
        RoundedRectangle(cornerRadius: 20)
          .fill(isSubscribed ? 
                Color.green.opacity(0.15) : 
                Color.accentColor)
      )
      .overlay(
        RoundedRectangle(cornerRadius: 20)
          .stroke(isSubscribed ? Color.green.opacity(0.3) : Color.clear, lineWidth: 1)
      )
    }
    .disabled(isTogglingSubscription)
    .buttonStyle(.plain)
  }
  
  private var descriptionSection: some View {
    Group {
      if let description = feed.description, !description.isEmpty {
        VStack(alignment: .leading, spacing: 8) {
          Text(description)
            .appFont(AppTextRole.body)
            .lineLimit(showingDescription ? nil : 3)
            .animation(.easeInOut(duration: 0.2), value: showingDescription)
          
          if description.count > 120 {
            Button(showingDescription ? "Show less" : "Show more") {
              withAnimation(.easeInOut(duration: 0.2)) {
                showingDescription.toggle()
              }
            }
            .appFont(AppTextRole.caption)
            .foregroundColor(.accentColor)
            .buttonStyle(.plain)
          }
        }
      }
    }
  }
  
  private var actionButtons: some View {
    HStack(spacing: 24) {
      // Like button
      Button {
        likeFeed()
      } label: {
        HStack(spacing: 4) {
          Image(systemName: "heart")
          Text("Like")
        }
        .appFont(AppTextRole.caption)
        .foregroundColor(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
      }
      .buttonStyle(.plain)
      .frame(minWidth: 44, minHeight: 44)
      .contentShape(Rectangle())
      
      // Share button
      Button {
        shareFeed()
      } label: {
        HStack(spacing: 4) {
          Image(systemName: "square.and.arrow.up")
          Text("Share")
        }
        .appFont(AppTextRole.caption)
        .foregroundColor(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
      }
      .buttonStyle(.plain)
      .frame(minWidth: 44, minHeight: 44)
      .contentShape(Rectangle())
      
      // Report button
      Button {
        reportFeed()
      } label: {
        HStack(spacing: 4) {
          Image(systemName: "exclamationmark.circle")
          Text("Report")
        }
        .appFont(AppTextRole.caption)
        .foregroundColor(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
      }
      .buttonStyle(.plain)
      .frame(minWidth: 44, minHeight: 44)
      .contentShape(Rectangle())
      
      Spacer()
    }
  }
  
  // MARK: - Actions
  
  private func toggleSubscription() async {
    guard !isTogglingSubscription else { return }
    
    isTogglingSubscription = true
    defer { isTogglingSubscription = false }
    
    await onSubscriptionToggle()
    
    // Notify state invalidation bus that feeds have changed
    await appState.stateInvalidationBus.notify(.feedListChanged)
  }
  
  private func likeFeed() {
    logger.info("Like button tapped for feed: \(feed.uri)")
    
    let impactFeedback = UIImpactFeedbackGenerator(style: .light)
    impactFeedback.impactOccurred()
    
    Task {
      do {
        guard let client = appState.atProtoClient else { 
          logger.warning("No AT Protocol client available for like action")
          return 
        }
        
        logger.info("Like feed: \(feed.uri)")
        
        let postRef = ComAtprotoRepoStrongRef(
          uri: feed.uri,
          cid: feed.cid
        )
        
        let likeRecord = AppBskyFeedLike(
          subject: postRef,
          createdAt: ATProtocolDate(date: Date()),
          via: nil
        )
        
        let did = try await client.getDid()
        let input = ComAtprotoRepoCreateRecord.Input(
          repo: try ATIdentifier(string: did),
          collection: try NSID(nsidString: "app.bsky.feed.like"),
          record: .knownType(likeRecord)
        )
        
        let (responseCode, _) = try await client.com.atproto.repo.createRecord(input: input)
        
        if responseCode == 200 {
          logger.info("Successfully liked feed: \(feed.uri)")
        } else {
          logger.error("Failed to like feed: HTTP \(responseCode)")
        }
      } catch {
        logger.error("Error liking feed: \(error)")
      }
    }
  }
  
  private func shareFeed() {
    logger.info("Share button tapped for feed: \(feed.uri)")
    
    let impactFeedback = UIImpactFeedbackGenerator(style: .light)
    impactFeedback.impactOccurred()
    
    guard let url = URL(string: feed.uri.uriString()) else { 
      logger.error("Failed to create URL from feed URI: \(feed.uri.uriString())")
      return 
    }
    
    let activityVC = UIActivityViewController(
      activityItems: [url],
      applicationActivities: nil
    )
    
    if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
       let window = windowScene.windows.first {
      window.rootViewController?.present(activityVC, animated: true)
      logger.info("Presented share sheet for feed")
    } else {
      logger.error("Could not find window to present share sheet")
    }
  }
  
  private func reportFeed() {
    logger.info("Report button tapped for feed: \(feed.uri)")
    
    let impactFeedback = UIImpactFeedbackGenerator(style: .light)
    impactFeedback.impactOccurred()
    
    Task {
      do {
        guard let client = appState.atProtoClient else { 
          logger.warning("No AT Protocol client available for report action")
          return 
        }
        
        let reportInput = ComAtprotoModerationCreateReport.Input(
          reasonType: .comatprotomoderationdefsreasonspam,
          reason: "User reported inappropriate feed content",
          subject: .comAtprotoAdminDefsRepoRef(.init(
            did: try DID(didString: feed.creator.did.didString())
          ))
        )
        
        let (responseCode, _) = try await client.com.atproto.moderation.createReport(input: reportInput)
        
        if responseCode == 200 {
          logger.info("Successfully reported feed: \(feed.uri)")
        } else {
          logger.error("Failed to report feed: HTTP \(responseCode)")
        }
      } catch {
        logger.error("Error reporting feed: \(error)")
      }
    }
  }
  
  private func formatCount(_ count: Int) -> String {
    if count >= 1000000 {
      return String(format: "%.1fM", Double(count) / 1000000)
    } else if count >= 1000 {
      return String(format: "%.1fK", Double(count) / 1000)
    } else {
      return "\(count)"
    }
  }
}
