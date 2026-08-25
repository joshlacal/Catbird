import SwiftUI
import Petrel
import PetrelCatbird

/// Audience selector for the post composer.
/// Displays "Public" first, followed by active Circles only.
/// Expired, removed, unsupported, or pending Circles are excluded from selection.
struct CircleAudiencePicker: View {
  @Binding var selectedDestination: CircleDestination
  var circles: [CircleSummary] = []
  var isReplyLocked: Bool = false
  var isSubmitting: Bool = false

  @Environment(AppState.self) private var appState
  @State private var loadedCircles: [CircleSummary] = []

  /// Filters an array of Circles to only those in the active access state.
  public static func filterActiveCircles(_ circles: [CircleSummary]) -> [CircleSummary] {
    circles.filter { $0.accessState == .value_active }
  }

  private var activeCircles: [CircleSummary] {
    let source = !circles.isEmpty ? circles : loadedCircles
    return Self.filterActiveCircles(source)
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
            Button {
              selectedDestination = .circle(circle)
            } label: {
              Label(circle.name, systemImage: "person.2.fill")
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
      .accessibilityLabel(accessibilityLabelText)
      .accessibilityHint(accessibilityHintText)

      Spacer()
    }
    .task {
      if circles.isEmpty && loadedCircles.isEmpty {
        do {
          let page = try await appState.circleService.listCircles()
          self.loadedCircles = page.circles
        } catch {
          // Failure to list circles leaves empty list, public stays selected
        }
      }
    }
  }

  private var accessibilityLabelText: String {
    switch selectedDestination {
    case .public:
      return "Audience: Public"
    case .circle(let circle):
      return "Audience: Circle \(circle.name)"
    }
  }

  private var accessibilityHintText: String {
    if isReplyLocked {
      return "Audience is locked to this Circle for replies"
    } else if isSubmitting {
      return "Post is currently submitting"
    } else {
      return "Double tap to change post audience"
    }
  }
}
