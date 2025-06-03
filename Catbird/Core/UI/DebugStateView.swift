import SwiftUI
import OSLog

/// Debug view for runtime state inspection and monitoring
/// Shows StateInvalidationBus activity, app state, and system health
struct DebugStateView: View {
  // MARK: - Properties
  
  @Environment(AppState.self) private var appState
  @State private var isExpanded = false
  @State private var selectedTab = 0
  @State private var refreshTimer: Timer?
  @State private var eventHistory: [StateInvalidationEvent] = []
  @State private var subscriberCount = 0
  
  // MARK: - Body
  
  var body: some View {
    VStack {
      // Header with toggle
      HStack {
        Text("🔧 Debug State Monitor")
          .appFont(AppTextRole.headline)
          .foregroundColor(.primary)
        
        Spacer()
        
        Button(action: { isExpanded.toggle() }) {
          Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
            .foregroundColor(.secondary)
        }
      }
      .padding()
      .background(Color(.systemGray6))
      .onTapGesture { isExpanded.toggle() }
      
      if isExpanded {
        debugContent
      }
    }
    .background(Color(.systemBackground))
    .cornerRadius(12)
    .shadow(radius: 4)
    .onAppear(perform: startMonitoring)
    .onDisappear(perform: stopMonitoring)
  }
  
  // MARK: - Debug Content
  
  private var debugContent: some View {
    VStack(spacing: 0) {
      // Tab picker
      Picker("Debug Category", selection: $selectedTab) {
        Text("Events").tag(0)
        Text("State").tag(1)
        Text("Performance").tag(2)
      }
      .pickerStyle(SegmentedPickerStyle())
      .padding()
      
      // Tab content
      switch selectedTab {
      case 0:
        eventsTab
      case 1:
        stateTab
      case 2:
        performanceTab
      default:
        eventsTab
      }
    }
  }
  
  // MARK: - Events Tab
  
  private var eventsTab: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Text("State Invalidation Events")
          .appFont(AppTextRole.subheadline)
          .fontWeight(.semibold)
        
        Spacer()
        
        Text("\(subscriberCount) subscribers")
          .appFont(AppTextRole.caption)
          .foregroundColor(.secondary)
      }
      
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 4) {
          ForEach(Array(eventHistory.enumerated().reversed()), id: \.offset) { index, event in
            eventRow(event: event, index: eventHistory.count - index)
          }
        }
      }
      .frame(maxHeight: 200)
      
      HStack {
        Button("Clear History") {
          clearEventHistory()
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        
        Spacer()
        
        Button("Refresh") {
          refreshEventHistory()
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.small)
      }
    }
    .padding()
  }
  
  // MARK: - State Tab
  
  private var stateTab: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("App State Overview")
        .appFont(AppTextRole.subheadline)
        .fontWeight(.semibold)
      
      ScrollView {
        VStack(alignment: .leading, spacing: 8) {
          stateItem("Authentication", appState.isAuthenticated ? "✅ Authenticated" : "❌ Unauthenticated")
          stateItem("Current User", appState.currentUserDID ?? "None")
          stateItem("Client Status", appState.atProtoClient != nil ? "✅ Connected" : "❌ Disconnected")
          stateItem("Auth State", "\(appState.authState)")
          
          Divider()
          
          Text("Component Status")
            .appFont(AppTextRole.caption)
            .fontWeight(.semibold)
            .foregroundColor(.secondary)
          
          stateItem("Post Manager", postManagerStatus)
          stateItem("Preferences", preferencesStatus)
          stateItem("Notifications", notificationStatus)
        }
      }
      .frame(maxHeight: 200)
    }
    .padding()
  }
  
  // MARK: - Performance Tab
  
  private var performanceTab: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Performance Metrics")
        .appFont(AppTextRole.subheadline)
        .fontWeight(.semibold)
      
      ScrollView {
        VStack(alignment: .leading, spacing: 8) {
          performanceItem("Memory Usage", memoryUsage)
          performanceItem("Thermal State", thermalState)
          performanceItem("Battery State", batteryState)
          
          Divider()
          
          Text("State Bus Performance")
            .appFont(AppTextRole.caption)
            .fontWeight(.semibold)
            .foregroundColor(.secondary)
          
          performanceItem("Event Queue", "Real-time")
          performanceItem("Subscriber Count", "\(subscriberCount)")
          performanceItem("Event History", "\(eventHistory.count)/50")
        }
      }
      .frame(maxHeight: 200)
    }
    .padding()
  }
  
  // MARK: - Helper Views
  
  private func eventRow(event: StateInvalidationEvent, index: Int) -> some View {
    HStack {
      Text("\(index)")
        .appFont(AppTextRole.caption)
        .foregroundColor(.secondary)
        .frame(width: 30, alignment: .trailing)
      
      VStack(alignment: .leading, spacing: 2) {
        Text(eventDescription(event))
          .appFont(AppTextRole.caption)
          .monospaced()
        
        Text(eventTimestamp)
          .appFont(AppTextRole.caption2)
          .foregroundColor(.secondary)
      }
      
      Spacer()
      
      eventIcon(for: event)
    }
    .padding(.vertical, 2)
  }
  
  private func stateItem(_ title: String, _ value: String) -> some View {
    HStack {
      Text(title)
        .appFont(AppTextRole.caption)
        .foregroundColor(.secondary)
      
      Spacer()
      
      Text(value)
        .appFont(AppTextRole.caption)
        .monospaced()
    }
  }
  
  private func performanceItem(_ title: String, _ value: String) -> some View {
    HStack {
      Text(title)
        .appFont(AppTextRole.caption)
        .foregroundColor(.secondary)
      
      Spacer()
      
      Text(value)
        .appFont(AppTextRole.caption)
        .monospaced()
    }
  }
  
  // MARK: - Helper Methods
  
  private func startMonitoring() {
    refreshTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
      refreshEventHistory()
    }
  }
  
  private func stopMonitoring() {
    refreshTimer?.invalidate()
    refreshTimer = nil
  }
  
  private func refreshEventHistory() {
    eventHistory = appState.stateInvalidationBus.getEventHistory()
    subscriberCount = appState.stateInvalidationBus.subscriberCount
  }
  
  private func clearEventHistory() {
    appState.stateInvalidationBus.clearHistory()
    refreshEventHistory()
  }
  
  private func eventDescription(_ event: StateInvalidationEvent) -> String {
    switch event {
    case .postCreated(_):
      return "Post Created"
    case .replyCreated(_, _):
      return "Reply Created"
    case .accountSwitched:
      return "Account Switched"
    case .feedUpdated(let fetchType):
      return "Feed Updated: \(fetchType.identifier)"
    case .profileUpdated(_):
      return "Profile Updated"
    case .threadUpdated(_):
      return "Thread Updated"
    case .chatMessageReceived:
      return "Chat Message"
    case .notificationsUpdated:
      return "Notifications Updated"
    case .postLiked(_):
      return "Post Liked"
    case .postUnliked(_):
      return "Post Unliked"
    case .postReposted(_):
      return "Post Reposted"
    case .postUnreposted(_):
      return "Post Unreposted"
    case .feedListChanged:
      return "Feed List Changed"
    }
  }
  
  private func eventIcon(for event: StateInvalidationEvent) -> some View {
    let (icon, color): (String, Color) = {
      switch event {
      case .postCreated(_):
        return ("plus.circle.fill", .green)
      case .replyCreated(_, _):
        return ("bubble.left.fill", .blue)
      case .accountSwitched:
        return ("person.2.fill", .orange)
      case .feedUpdated(_):
        return ("list.bullet", .purple)
      case .profileUpdated(_):
        return ("person.fill", .blue)
      case .threadUpdated(_):
        return ("bubble.middle.bottom.fill", .indigo)
      case .chatMessageReceived:
        return ("message.fill", .green)
      case .notificationsUpdated:
        return ("bell.fill", .red)
      case .postLiked(_):
        return ("heart.fill", .red)
      case .postUnliked(_):
        return ("heart", .gray)
      case .postReposted(_):
        return ("repeat", .green)
      case .postUnreposted(_):
        return ("repeat", .gray)
      case .feedListChanged:
        return ("list.dash", .blue)
      }
    }()
    
    return Image(systemName: icon)
      .foregroundColor(color)
      .appFont(AppTextRole.caption)
  }
  
  // MARK: - Computed Properties
  
  private var eventTimestamp: String {
    let formatter = DateFormatter()
    formatter.timeStyle = .medium
    return formatter.string(from: Date())
  }
  
  private var postManagerStatus: String {
    switch appState.postManager.status {
    case .idle:
      return "✅ Idle"
    case .posting:
      return "🔄 Posting"
    case .success:
      return "✅ Success"
    case .error(let message):
      return "❌ Error: \(message)"
    }
  }
  
  private var preferencesStatus: String {
    // This would need to be exposed from PreferencesManager
    return "✅ Ready"
  }
  
  private var notificationStatus: String {
    // This would need to be exposed from NotificationManager
    return "✅ Ready"
  }
  
  private var memoryUsage: String {
    let used = mach_task_basic_info()
    let usedMB = used.resident_size / 1024 / 1024
    return "\(usedMB) MB"
  }
  
  private var thermalState: String {
    switch ProcessInfo.processInfo.thermalState {
    case .nominal:
      return "✅ Normal"
    case .fair:
      return "⚠️ Fair"
    case .serious:
      return "🔥 Serious"
    case .critical:
      return "🚨 Critical"
    @unknown default:
      return "❓ Unknown"
    }
  }
  
  private var batteryState: String {
    if !UIDevice.current.isBatteryMonitoringEnabled {
      UIDevice.current.isBatteryMonitoringEnabled = true
    }
    
    let level = UIDevice.current.batteryLevel
    let state = UIDevice.current.batteryState
    
    if level < 0 {
      return "❓ Unknown"
    }
    
    let percentage = Int(level * 100)
    let stateIcon = state == .charging ? "🔌" : "🔋"
    
    return "\(stateIcon) \(percentage)%"
  }
}

// MARK: - Memory Helper

private func mach_task_basic_info() -> mach_task_basic_info_data_t {
  var info = mach_task_basic_info_data_t()
  var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size)/4
  
  let kerr: kern_return_t = withUnsafeMutablePointer(to: &info) {
    $0.withMemoryRebound(to: integer_t.self, capacity: 1) {
      task_info(mach_task_self_,
                task_flavor_t(MACH_TASK_BASIC_INFO),
                $0,
                &count)
    }
  }
  
  if kerr == KERN_SUCCESS {
    return info
  } else {
    return mach_task_basic_info_data_t()
  }
}

// MARK: - Preview

#Preview {
  DebugStateView()
    .environment(AppState.shared)
    .padding()
}
