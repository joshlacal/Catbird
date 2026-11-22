import SwiftUI
import Petrel
import PetrelCatbird

/// Whether a Circle row in the audience picker can be chosen (spec §9).
enum CircleAudienceRowState: Equatable {
  case selectable
  /// An encrypted Circle without service support or a locally held key.
  case keysUnavailable

  /// The disabled row's one-line title: the Circle's name and the reason.
  func disabledTitle(circleName: String) -> String {
    guard let message else { return circleName }
    return String(
      localized: "\(circleName) — \(message)",
      comment: "Disabled Circle row in composer audience picker — %1$@ is the Circle name, %2$@ is the unavailability reason."
    )
  }

  var message: String? {
    switch self {
    case .selectable:
      return nil
    case .keysUnavailable:
      return String(
        localized: "Encryption keys not available yet",
        comment: "Reason shown when an encrypted Circle cannot be selected in the composer audience picker."
      )
    }
  }
}

/// Audience selector for the post composer.
/// Displays "Public" first, followed by active Circles only.
/// Expired, removed, unsupported, or pending Circles are excluded from selection.
/// An encrypted Circle without a key is listed disabled, with a Refresh.
struct CircleAudiencePicker: View {
  @Binding var selectedDestination: CircleDestination
  var circles: [CircleSummary] = []
  var isReplyLocked: Bool = false
  var isSubmitting: Bool = false
  var rowState: (CircleSummary) -> CircleAudienceRowState = { _ in .selectable }
  /// Evaluates the listed encrypted Circles (and the current destination's).
  var evaluate: ([CircleSummary]) async -> Void = { _ in }
  /// One key refresh for a disabled encrypted Circle, then re-evaluation.
  var refresh: (CircleSummary) async -> Void = { _ in }

  @Environment(AppState.self) private var appState
  @State private var loadedCircles: [CircleSummary] = []

  /// Every Circle the AppView returns is already membership-scoped server-side,
  /// so there is no client-side access filter. Per-Circle runtime state
  /// (expired / removed) is tracked by `CircleFeedModel`, not by filtering here.
  private var activeCircles: [CircleSummary] {
    guard appState.circlesEnabled else { return [] }
    return !circles.isEmpty ? circles : loadedCircles
  }

  var body: some View {
    HStack {
      Menu {
        Button {
          selectedDestination = .public
        } label: {
          Label("Public", systemImage: "globe")
        }

        if !activeCircles.isEmpty {
          Divider()
          ForEach(activeCircles, id: \.uri) { circle in
            let state = rowState(circle)
            if state == .selectable {
              Button {
                selectedDestination = .circle(circle)
              } label: {
                Label(circle.name, systemImage: circle.isEncrypted ? "lock.fill" : "person.2.fill")
              }
            } else {
              Section {
                // I10: iOS 27 menus drop a label's secondary text, so the
                // reason rides in the row's single title.
                Button {} label: {
                  Label(state.disabledTitle(circleName: circle.name), systemImage: "lock.fill")
                }
                .disabled(true)
                .accessibilityLabel(state.disabledTitle(circleName: circle.name))
                Button {
                  Task { await refresh(circle) }
                } label: {
                  Label("Refresh", systemImage: "arrow.clockwise")
                }
              }
            }
          }
        }
      } label: {
        HStack(spacing: 6) {
          switch selectedDestination {
          case .public:
            Image(systemName: "globe")
            Text("Public")
          case .circle(let circle):
            Image(systemName: "person.2.fill")
            Text(circle.name)
          }

          if !isReplyLocked && !isSubmitting {
            Image(systemName: "chevron.down")
              .font(.system(size: 10, weight: .semibold))
          }
        }
        .font(.subheadline)
        .foregroundStyle(selectedDestination == .public ? Color.secondary : Color.accentColor)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Color.secondarySystemBackground)
        .clipShape(Capsule())
      }
      .disabled(isReplyLocked || isSubmitting)
      .accessibilityIdentifier("composer.audiencePicker")
      .accessibilityLabel(accessibilityLabelText)
      .accessibilityHint(accessibilityHintText)
      if !appState.circlesEnabled, selectedDestination != .public {
        Text("Circles unavailable. Your post is still private.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      Spacer()
    }
    .task(id: "\(appState.userDID):\(appState.circlesEnabled)") {
      loadedCircles = []
      if appState.circlesEnabled && circles.isEmpty {
        do {
          let page = try await appState.circleService.listCircles()
          guard !Task.isCancelled, appState.circlesEnabled,
                AppStateManager.shared.lifecycle.appState === appState else { return }
          self.loadedCircles = page.circles
        } catch {
          // Failure to list circles leaves empty list, public stays selected
        }
      }
      var toEvaluate = activeCircles
      if case .circle(let current) = selectedDestination, !toEvaluate.contains(where: { $0.uri == current.uri }) {
        toEvaluate.append(current)
      }
      await evaluate(toEvaluate)
    }
  }

  private var accessibilityLabelText: LocalizedStringResource {
    switch selectedDestination {
    case .public:
      return LocalizedStringResource("Audience: Public", comment: "Accessibility label for post audience picker when Public is selected.")
    case .circle(let circle):
      return LocalizedStringResource(
        "Audience: Circle \(circle.name)",
        comment: "Accessibility label for post audience picker when a private Circle is selected — %1$@ is the Circle name."
      )
    }
  }

  private var accessibilityHintText: LocalizedStringResource {
    if isReplyLocked {
      return LocalizedStringResource("Audience is locked to this Circle for replies", comment: "Accessibility hint when replying inside a Circle locks the audience.")
    } else if isSubmitting {
      return LocalizedStringResource("Post is currently submitting", comment: "Accessibility hint on audience picker while the post is submitting.")
    } else {
      return LocalizedStringResource("Double tap to change post audience", comment: "Accessibility hint on post audience picker.")
    }
  }
}
