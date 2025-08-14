import SwiftUI
import AVKit

// MARK: - Enhanced PiP Manager

@Observable
class EnhancedPiPManager {
  static let shared = EnhancedPiPManager()
  
  var isPiPActive: Bool = false
  var currentPiPVideoId: String?
  var pipFrame: CGRect = CGRect(x: 20, y: 100, width: 200, height: 112)
  private var savedPosition: CGPoint?
  
  private init() {
    loadSavedPosition()
  }
  
  func startPiP(withVideoId videoId: String) {
    currentPiPVideoId = videoId
    isPiPActive = true
  }
  
  func stopPiP() {
    currentPiPVideoId = nil
    isPiPActive = false
  }
  
  func updatePiPFrame(_ frame: CGRect) {
    pipFrame = frame
    savePosition(CGPoint(x: frame.midX, y: frame.midY))
  }
  
  private func savePosition(_ position: CGPoint) {
    savedPosition = position
    UserDefaults.standard.set(position.x, forKey: "PiPPositionX")
    UserDefaults.standard.set(position.y, forKey: "PiPPositionY")
  }
  
  private func loadSavedPosition() {
    let x = UserDefaults.standard.double(forKey: "PiPPositionX")
    let y = UserDefaults.standard.double(forKey: "PiPPositionY")
    if x > 0 && y > 0 {
      savedPosition = CGPoint(x: x, y: y)
      pipFrame = CGRect(
        x: x - pipFrame.width/2,
        y: y - pipFrame.height/2,
        width: pipFrame.width,
        height: pipFrame.height
      )
    }
  }
}

// MARK: - Enhanced Global PiP Overlay

struct GlobalPiPOverlay: View {
  @Environment(AppState.self) private var appState
  @State private var pipManager = EnhancedPiPManager.shared
  @State private var dragOffset: CGSize = .zero
  @State private var isDragging: Bool = false
  @State private var showControls: Bool = false
  @State private var hideControlsTask: Task<Void, Never>?
  
  private let cornerRadius: CGFloat = 12
  private let shadowRadius: CGFloat = 8
  
  var body: some View {
    ZStack {
      if pipManager.isPiPActive {
        Color.clear
          .overlay(alignment: .topLeading) {
            pipWindowView
          }
          .allowsHitTesting(true)
          .transition(.opacity.combined(with: .scale))
          .animation(.spring(response: 0.3, dampingFraction: 0.8), value: pipManager.isPiPActive)
      }
    }
  }
  
  @ViewBuilder
  private var pipWindowView: some View {
    VStack(spacing: 0) {
      // PiP Content Area
      RoundedRectangle(cornerRadius: cornerRadius)
        .fill(Color.black)
        .frame(width: pipManager.pipFrame.width, height: pipManager.pipFrame.height)
        .overlay(
          RoundedRectangle(cornerRadius: cornerRadius)
            .stroke(Color.white.opacity(0.3), lineWidth: 1)
        )
        .overlay(
          Group {
            if let videoId = pipManager.currentPiPVideoId {
              pipContentView(for: videoId)
            } else {
              placeholderContent
            }
          }
        )
        .overlay(
          Group {
            if showControls {
              pipControlsOverlay
            }
          }
        )
    }
    .position(
      x: pipManager.pipFrame.midX + dragOffset.width,
      y: pipManager.pipFrame.midY + dragOffset.height
    )
    .shadow(color: .black.opacity(0.3), radius: shadowRadius, x: 0, y: 4)
    .scaleEffect(isDragging ? 1.05 : 1.0)
    .animation(.spring(response: 0.2, dampingFraction: 0.7), value: isDragging)
    .gesture(
      DragGesture()
        .onChanged { value in
          if !isDragging {
            isDragging = true
            showControls = true
          }
          dragOffset = value.translation
        }
        .onEnded { value in
          isDragging = false
          
          // Update the pip frame with the new position
          let newFrame = CGRect(
            x: pipManager.pipFrame.origin.x + value.translation.width,
            y: pipManager.pipFrame.origin.y + value.translation.height,
            width: pipManager.pipFrame.width,
            height: pipManager.pipFrame.height
          )
          
          // Keep within screen bounds
          let clampedFrame = clampToScreenBounds(newFrame)
          pipManager.updatePiPFrame(clampedFrame)
          
          dragOffset = .zero
          scheduleHideControls()
        }
    )
    .onTapGesture {
      withAnimation(.easeInOut(duration: 0.2)) {
        showControls.toggle()
      }
      if showControls {
        scheduleHideControls()
      }
    }
    .zIndex(1000)
  }
  
  @ViewBuilder
  private func pipContentView(for videoId: String) -> some View {
    Text("📺 Video Playing")
      .foregroundColor(.white)
      .font(.caption)
      .multilineTextAlignment(.center)
  }
  
  @ViewBuilder
  private var placeholderContent: some View {
    VStack(spacing: 4) {
      Image(systemName: "play.rectangle.fill")
        .foregroundColor(.white.opacity(0.7))
        .font(.title2)
      Text("PiP Active")
        .foregroundColor(.white.opacity(0.7))
        .font(.caption2)
    }
  }
  
  @ViewBuilder
  private var pipControlsOverlay: some View {
    VStack {
      HStack {
        Spacer()
        
        // Close PiP button
        Button(action: {
          closePiP()
        }) {
          Image(systemName: "xmark.circle.fill")
            .foregroundColor(.white)
            .font(.title3)
            .background(Circle().fill(Color.black.opacity(0.6)))
        }
        .padding(.top, 4)
        .padding(.trailing, 4)
      }
      
      Spacer()
      
      HStack {
        // Restore to fullscreen button
        Button(action: {
          restoreToFullscreen()
        }) {
          Image(systemName: "arrow.up.left.and.arrow.down.right")
            .foregroundColor(.white)
            .font(.caption)
            .padding(6)
            .background(Circle().fill(Color.black.opacity(0.6)))
        }
        
        Spacer()
        
        // Resize button
        Button(action: {
          resizePiP()
        }) {
          Image(systemName: "arrow.up.backward.and.arrow.down.forward")
            .foregroundColor(.white)
            .font(.caption)
            .padding(6)
            .background(Circle().fill(Color.black.opacity(0.6)))
        }
      }
      .padding(.bottom, 4)
      .padding(.horizontal, 4)
    }
    .transition(.opacity)
  }
  
  private func scheduleHideControls() {
    hideControlsTask?.cancel()
    hideControlsTask = Task {
      try? await Task.sleep(nanoseconds: 3_000_000_000) // 3 seconds
      if !Task.isCancelled {
        await MainActor.run {
          withAnimation(.easeInOut(duration: 0.3)) {
            showControls = false
          }
        }
      }
    }
  }
  
  private func clampToScreenBounds(_ frame: CGRect) -> CGRect {
    let screenBounds = UIScreen.main.bounds
    let margin: CGFloat = 20
    
    let clampedX = max(margin, min(screenBounds.width - frame.width - margin, frame.origin.x))
    let clampedY = max(margin, min(screenBounds.height - frame.height - margin, frame.origin.y))
    
    return CGRect(x: clampedX, y: clampedY, width: frame.width, height: frame.height)
  }
  
  private func closePiP() {
    guard let videoId = pipManager.currentPiPVideoId else { return }
    
    // Stop the native PiP
    if let controller = VideoCoordinator.shared.getPiPController(for: videoId) {
      controller.stopPictureInPicture()
    }
    
    pipManager.stopPiP()
  }
  
  private func restoreToFullscreen() {
    guard let videoId = pipManager.currentPiPVideoId else { return }
    
    // Post notification to restore the video interface
    NotificationCenter.default.post(
      name: NSNotification.Name("RestorePiPInterface"),
      object: nil,
      userInfo: ["videoId": videoId]
    )
    
    // Stop PiP
    closePiP()
  }
  
  private func resizePiP() {
    // Cycle through different sizes
    let currentWidth = pipManager.pipFrame.width
    let newSize: CGSize
    
    switch currentWidth {
    case ..<180:
      newSize = CGSize(width: 200, height: 112) // Medium
    case 180..<220:
      newSize = CGSize(width: 280, height: 157) // Large
    default:
      newSize = CGSize(width: 160, height: 90)  // Small
    }
    
    let newFrame = CGRect(
      x: pipManager.pipFrame.midX - newSize.width/2,
      y: pipManager.pipFrame.midY - newSize.height/2,
      width: newSize.width,
      height: newSize.height
    )
    
    let clampedFrame = clampToScreenBounds(newFrame)
    
    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
      pipManager.updatePiPFrame(clampedFrame)
    }
  }
}

// MARK: - PiP Control Extensions

extension View {
    func withPiPSupport() -> some View {
        self.overlay(GlobalPiPOverlay())
    }
}
