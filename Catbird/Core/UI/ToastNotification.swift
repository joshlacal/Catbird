//
//  ToastNotification.swift
//  Catbird
//
//  Toast notification system with Liquid Glass styling
//

import SwiftUI

// MARK: - Toast Model

@Observable
final class ToastManager {
  var currentToast: ToastItem?
  
  func show(_ toast: ToastItem) {
    currentToast = toast
    
    Task { @MainActor in
      try? await Task.sleep(for: .seconds(toast.duration))
      if currentToast?.id == toast.id {
        currentToast = nil
      }
    }
  }
  
  func dismiss() {
    currentToast = nil
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
  @State private var isVisible = false
  @State private var dragOffset: CGFloat = 0
  
  private let toastHeight: CGFloat = 62  // Same as FAB height
  
  var body: some View {
    HStack(spacing: 12) {
      Image(systemName: toast.icon)
        .font(.system(size: 20, weight: .medium))
        .foregroundStyle(.white)
      
      Text(toast.message)
        .font(.system(size: 15, weight: .medium))
        .foregroundStyle(.white)
        .lineLimit(1)
    }
    .padding(.horizontal, 20)
    .frame(height: toastHeight)
    .background(
      Group {
        // Only iOS 26+/macOS 15+ has the real glass effect; older OSes need a visible fallback.
        if #available(iOS 26.0, macOS 15.0, *) {
          Color.clear
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
    .glassEffectCompatibility()
    .shadow(color: .black.opacity(0.1), radius: 8, x: 0, y: 4)
    .offset(x: dragOffset)
    .offset(x: isVisible ? 0 : -300)  // Slide from left instead of right
    .animation(.spring(response: 0.4, dampingFraction: 0.8), value: isVisible)
    .animation(.spring(response: 0.3, dampingFraction: 0.9), value: dragOffset)
    .gesture(
      DragGesture()
        .onChanged { value in
          if value.translation.width < 0 {  // Swipe left to dismiss
            dragOffset = value.translation.width
          }
        }
        .onEnded { value in
          if value.translation.width < -50 || value.predictedEndTranslation.width < -100 {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
              dragOffset = -300  // Dismiss to the left
            }
            Task { @MainActor in
              try? await Task.sleep(for: .milliseconds(300))
              onDismiss()
            }
          } else {
            dragOffset = 0
          }
        }
    )
    .onAppear {
      withAnimation {
        isVisible = true
      }
    }
  }
}

// MARK: - Toast Container View Modifier

struct ToastContainerModifier: ViewModifier {
  @Environment(\.toastManager) private var toastManager
  
  func body(content: Content) -> some View {
    // Toast display is now handled by FAB component
    // This modifier just ensures the environment is set up
    content
  }
}

extension View {
  func toastContainer() -> some View {
    modifier(ToastContainerModifier())
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
  @ViewBuilder
  func glassEffectCompatibility() -> some View {
      if #available(iOS 26.0, macOS 15.0, *) {
      self.glassEffect(.regular.tint(.accentColor).interactive(), in: .capsule)
    } else {
      self
    }
  }
}
