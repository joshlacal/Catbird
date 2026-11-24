import SwiftUI

/// Toolbar menu that chooses which model answers: On Device or Private Cloud Compute.
struct AskCatbirdRoutePicker: View {
  @Binding var route: CopilotModelRoute
  let cloudStatus: CopilotCloudStatus?
  let isDisabled: Bool

  var body: some View {
    Menu {
      Picker("Model", selection: $route) {
        Label("On Device", systemImage: "iphone")
          .tag(CopilotModelRoute.onDevice)
        Label("Private Cloud Compute", systemImage: "lock.icloud")
          .tag(CopilotModelRoute.privateCloudCompute)
          .selectionDisabled(cloudStatus?.isSelectable != true)
      }
      .pickerStyle(.inline)

      Section {
        Text(footnote)
      }
    } label: {
      Label(route.displayName, systemImage: route.systemImage)
        .labelStyle(.iconOnly)
    }
    .disabled(isDisabled)
    .accessibilityLabel("Model")
    .accessibilityValue(route.displayName)
    .accessibilityHint("Chooses whether Ask Catbird answers on this device or with Private Cloud Compute")
    .accessibilityIdentifier("ask-catbird-route-picker")
  }

  private var footnote: String {
    if let reason = cloudStatus?.unavailableReason { return reason }
    guard cloudStatus != nil else {
      return String(localized: "Checking Private Cloud Compute…", comment: "Ask Catbird route picker: status loading.")
    }
    return String(
      localized: "On Device keeps everything on this device. Private Cloud Compute uses larger Apple models that can research more deeply; Apple states requests are not stored or made accessible to Apple.",
      comment: "Ask Catbird route picker explanation."
    )
  }
}

/// Shown above the composer when Private Cloud Compute usage is near or at its limit.
struct AskCatbirdQuotaNotice: View {
  let quota: CopilotCloudStatus.Quota
  let canRequestMore: Bool
  let onSwitchToDevice: () -> Void
  let onRequestMore: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Label(message, systemImage: isLimitReached ? "exclamationmark.icloud" : "icloud")
        .font(.footnote)
        .foregroundStyle(isLimitReached ? Color.orange : Color.secondary)
        .fixedSize(horizontal: false, vertical: true)
      HStack(spacing: 12) {
        if isLimitReached {
          Button("Use On Device", action: onSwitchToDevice)
        }
        if canRequestMore {
          Button("Request More", action: onRequestMore)
        }
      }
      .font(.footnote.weight(.semibold))
      .buttonStyle(.borderless)
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 10)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(.quaternary.opacity(0.35))
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("ask-catbird-quota-notice")
  }

  private var isLimitReached: Bool {
    if case .limitReached = quota { return true }
    return false
  }

  private var message: String {
    switch quota {
    case .available:
      return ""
    case .approachingLimit:
      return String(localized: "You're close to your Private Cloud Compute limit.",
                    comment: "Ask Catbird: Private Cloud Compute quota nearly used.")
    case .limitReached(let resetDate?):
      return String(localized: "Private Cloud Compute limit reached until \(resetDate.formatted(date: .abbreviated, time: .shortened)).",
                    comment: "Ask Catbird: Private Cloud Compute quota used, with reset time.")
    case .limitReached(nil):
      return String(localized: "Private Cloud Compute limit reached for now.",
                    comment: "Ask Catbird: Private Cloud Compute quota used.")
    }
  }
}

/// Small caption under each answer naming the model that wrote it.
struct AskCatbirdRouteBadge: View {
  let route: CopilotModelRoute

  var body: some View {
    Label(route.displayName, systemImage: route.systemImage)
      .font(.caption2)
      .foregroundStyle(.secondary)
      .accessibilityLabel("Answered with \(route.displayName)")
  }
}

extension CopilotModelRoute {
  var displayName: String {
    switch self {
    case .onDevice:
      String(localized: "On Device", comment: "Ask Catbird model route name.")
    case .privateCloudCompute:
      String(localized: "Private Cloud Compute", comment: "Ask Catbird model route name.")
    }
  }

  var systemImage: String {
    switch self {
    case .onDevice: "iphone"
    case .privateCloudCompute: "lock.icloud"
    }
  }
}

#Preview("Route controls") {
  VStack(alignment: .leading, spacing: 16) {
    AskCatbirdQuotaNotice(quota: .approachingLimit, canRequestMore: false, onSwitchToDevice: {}, onRequestMore: {})
    AskCatbirdQuotaNotice(
      quota: .limitReached(resetDate: Date().addingTimeInterval(3 * 3600)),
      canRequestMore: true, onSwitchToDevice: {}, onRequestMore: {}
    )
    AskCatbirdRouteBadge(route: .onDevice)
    AskCatbirdRouteBadge(route: .privateCloudCompute)
  }
  .padding()
}
