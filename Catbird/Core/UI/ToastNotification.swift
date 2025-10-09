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
        if #available(iOS 18.0, macOS 15.0, *) {
          Color.clear
        } else {
          // Fallback for pre-iOS 18 / macOS 15
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
    .offset(x: isVisible ? 0 : 300)
    .animation(.spring(response: 0.4, dampingFraction: 0.8), value: isVisible)
    .animation(.spring(response: 0.3, dampingFraction: 0.9), value: dragOffset)
    .gesture(
      DragGesture()
        .onChanged { value in
          if value.translation.width > 0 {
            dragOffset = value.translation.width
          }
        }
        .onEnded { value in
          if value.translation.width > 50 || value.predictedEndTranslation.width > 100 {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
              dragOffset = 300
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
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
    content
      .overlay(alignment: .bottomTrailing) {
        if let toast = toastManager.currentToast {
          ToastView(toast: toast) {
            toastManager.dismiss()
          }
          .padding(.trailing, 16)
          .padding(.bottom, calculateBottomPadding())
          .transition(.move(edge: .trailing).combined(with: .opacity))
          .zIndex(999)
        }
      }
  }
  
  private func calculateBottomPadding() -> CGFloat {
    #if os(iOS)
    // Position above FAB: tab bar (49) + spacing (30) + FAB height (62) + spacing (12)
    return 49 + 30 + 62 + 12
    #else
    // macOS: position above FAB with spacing
    return 20 + 62 + 12
    #endif
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
