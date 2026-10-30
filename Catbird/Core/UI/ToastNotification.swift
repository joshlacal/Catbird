//
//  ToastNotification.swift
//  Catbird
//
//  Toast notification system with Liquid Glass styling
//

import SwiftUI
import OSLog
import Accessibility

// MARK: - Toast Model

@Observable
final class ToastManager {
  private let logger = Logger(subsystem: "blue.catbird", category: "Toast")
  
  var currentToast: ToastItem?
  /// Toast hosts (the root scene content plus any sheet that installs one), in
  /// presentation order. Only the most recently presented host draws the toast,
  /// so a toast raised while a sheet is up appears on the sheet, not behind it.
  private(set) var containerStack: [UUID] = []
  @ObservationIgnored private var dismissTask: Task<Void, Never>?
  
  func show(_ toast: ToastItem) {
    // Re-showing the toast that is already visible just restarts its timer.
    if let current = currentToast,
       current.message == toast.message,
       current.icon == toast.icon {
      logger.debug("🍞 Extending duplicate toast: \(toast.message)")
      scheduleDismiss(for: current)
      return
    }
    
    logger.debug("🍞 ToastManager.show() called: \(toast.message)")
    currentToast = toast
    scheduleDismiss(for: toast)
    announce(toast.message)
  }
  
  func dismiss() {
    dismissTask?.cancel()
    dismissTask = nil
    currentToast = nil
  }

  func registerContainer(_ id: UUID) {
    containerStack.removeAll { $0 == id }
    containerStack.append(id)
  }

  func unregisterContainer(_ id: UUID) {
    containerStack.removeAll { $0 == id }
  }

  func isActiveContainer(_ id: UUID) -> Bool {
    containerStack.last == id
  }

  private func scheduleDismiss(for item: ToastItem) {
    dismissTask?.cancel()
    dismissTask = Task { @MainActor in
      // A cancelled sleep means a newer toast (or a manual dismiss) took over.
      guard (try? await Task.sleep(for: .seconds(item.duration))) != nil else { return }
      if currentToast?.id == item.id {
        currentToast = nil
        logger.debug("🍞 Toast auto-dismissed")
      }
    }
  }

  private func announce(_ message: String) {
    Task { @MainActor in
      // Give VoiceOver a moment to finish reading the control that triggered the toast.
      try? await Task.sleep(for: .milliseconds(150))
      AccessibilityNotification.Announcement(message).post()
    }
  }
}

struct ToastItem: Identifiable, Equatable {
  let id = UUID()
  let message: String
  let icon: String
  let duration: TimeInterval
  
  init(message: String, icon: String = "checkmark.circle.fill", duration: TimeInterval = 3.0) {
    self.message = message
    self.icon = icon
    self.duration = duration
  }
}

// MARK: - Toast View

struct ToastView: View {
  let toast: ToastItem
  let onDismiss: () -> Void
  @State private var dragOffset: CGFloat = 0
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
  
  private let toastMinHeight: CGFloat = 52
  
  var body: some View {
    HStack(spacing: 12) {
      Image(systemName: toast.icon)
        .appFont(AppTextRole.headline)
        .foregroundStyle(.white)
        .accessibilityHidden(true)
      
      Text(toast.message)
        .appFont(AppTextRole.subheadline)
        .fontWeight(.medium)
        .foregroundStyle(.white)
        .lineLimit(3)
        .multilineTextAlignment(.leading)
        .fixedSize(horizontal: false, vertical: true)
    }
    .padding(.horizontal, 20)
    .padding(.vertical, 10)
    .frame(minHeight: toastMinHeight)
    .background(
      Group {
        // Only iOS 26+/macOS 26+ has the real glass effect; older OSes need a visible fallback.
        if #available(iOS 26.0, macOS 26.0, *) {
          Color.clear
        } else if reduceTransparency {
          Capsule()
            .fill(Color.accentColor)
        } else {
          Capsule()
            .fill(.ultraThinMaterial)
            .overlay(
              Capsule()
                .fill(Color.accentColor.opacity(0.5))
            )
        }
      }
    )
    .clipShape(Capsule())
    .glassEffectCompatibility(reduceTransparency: reduceTransparency)
    .shadow(color: .black.opacity(0.1), radius: 8, x: 0, y: 4)
    .offset(y: dragOffset)
    .animation(.spring(response: 0.3, dampingFraction: 0.9), value: dragOffset)
    .accessibilityElement(children: .combine)
    .accessibilityAddTraits(.isStaticText)
    .accessibilityAction(named: "Dismiss") { onDismiss() }
    .onTapGesture { onDismiss() }
    .gesture(
      DragGesture()
        .onChanged { value in
          if value.translation.height < 0 {  // Swipe up to dismiss
            dragOffset = value.translation.height
          }
        }
        .onEnded { value in
          if value.translation.height < -30 || value.predictedEndTranslation.height < -80 {
            onDismiss()
          } else {
            dragOffset = 0
          }
        }
    )
  }
}

// MARK: - Toast Container View Modifier

/// Draws the current toast at the top of the content it is applied to. Apply it once at
/// the scene root and once on each sheet that can raise toasts while it is open; only the
/// most recently presented container draws, so a toast never shows twice.
struct ToastContainerModifier: ViewModifier {
  let manager: ToastManager?
  @Environment(\.toastManager) private var environmentManager
  @State private var containerID = UUID()

  private var toastManager: ToastManager { manager ?? environmentManager }
  
  func body(content: Content) -> some View {
    content
      .overlay(alignment: .top) {
        if let toast = toastManager.currentToast, toastManager.isActiveContainer(containerID) {
          ToastView(toast: toast) {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
              toastManager.dismiss()
            }
          }
          .padding(.horizontal, 16)
          .padding(.top, 8)
          .transition(.move(edge: .top).combined(with: .opacity))
          .id(toast.id)
        }
      }
      .animation(.spring(response: 0.4, dampingFraction: 0.85), value: toastManager.currentToast?.id)
      .onAppear { toastManager.registerContainer(containerID) }
      .onDisappear { toastManager.unregisterContainer(containerID) }
  }
}

extension View {
  /// Hosts toasts from the `toastManager` in the environment.
  func toastContainer() -> some View {
    modifier(ToastContainerModifier(manager: nil))
  }

  /// Hosts toasts from an explicit manager, for sheets presented above the view that
  /// injects `toastManager` into the environment.
  func toastContainer(using manager: ToastManager) -> some View {
    modifier(ToastContainerModifier(manager: manager))
  }
}

// MARK: - Environment Key

private struct ToastManagerKey: EnvironmentKey {
  static let defaultValue = ToastManager()
}

extension EnvironmentValues {
  var toastManager: ToastManager {
    get { self[ToastManagerKey.self] }
    set { self[ToastManagerKey.self] = newValue }
  }
}

// MARK: - Helper Extensions

extension View {
  @ViewBuilder
  func `if`<Content: View>(_ condition: Bool, transform: (Self) -> Content) -> some View {
    if condition {
      transform(self)
    } else {
      self
    }
  }
}

private extension View {
  // Applies the new glassEffect when available; otherwise returns self.
  // Reduce Transparency swaps the clear glass for `.regular` so the white text keeps its contrast.
  @ViewBuilder
  func glassEffectCompatibility(reduceTransparency: Bool) -> some View {
    if #available(iOS 26.0, macOS 26.0, *) {
      if reduceTransparency {
        self.glassEffect(.regular.tint(.accentColor).interactive(), in: .capsule)
      } else {
        self.glassEffect(.clear.tint(.accentColor).interactive(), in: .capsule)
      }
    } else {
      self
    }
  }
}

#if os(iOS)
private let toastPreviewBackgroundColor = Color(.systemBackground)
#elseif os(macOS)
private let toastPreviewBackgroundColor = Color(.windowBackgroundColor)
#endif

#Preview("Toast Notification") {
  ZStack {
    toastPreviewBackgroundColor.ignoresSafeArea()
    ToastView(
      toast: ToastItem(message: "Post published successfully"),
      onDismiss: {}
    )
  }
}

#Preview("Toast - Warning") {
  ZStack {
    toastPreviewBackgroundColor.ignoresSafeArea()
    ToastView(
      toast: ToastItem(message: "Connection lost", icon: "wifi.slash"),
      onDismiss: {}
    )
  }
}
