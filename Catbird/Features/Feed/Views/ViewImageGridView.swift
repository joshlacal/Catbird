//
//  ViewImagesGridView.swift
//  Catbird
//
//  Created by Josh LaCalamito on 6/30/24.
//

import Nuke
import NukeUI
import Petrel
import SwiftUI
import OSLog
import VisionKit
import UIKit

#if os(iOS)
  import LazyPager
#endif

// MARK: - Logging Setup
// private let logger = Logger(subsystem: "blue.catbird", category: "ViewImageGridView")

// MARK: - ViewImageGridView Implementation
struct ViewImageGridView: View {
  let viewImages: [AppBskyEmbedImages.ViewImage]
  let shouldBlur: Bool
  @State private var isBlurred: Bool
  @State private var selectedImage: AppBskyEmbedImages.ViewImage? {
    didSet {
//      logger.debug("🖼️ selectedImage changed: was \(String(describing: oldValue?.id)), now \(String(describing: selectedImage?.id))")
    }
  }
  @State private var currentIndex: Int = 0 {
    didSet {
//      logger.debug("📍 currentIndex changed: was \(oldValue), now \(currentIndex), updating transition ID? \(selectedImage != nil)")
      // Keep transition ID in sync with the current index when the image viewer is shown
      if selectedImage != nil {
        activeTransitionID = viewImages[currentIndex].id
      }
    }
  }
  @Namespace private var imageTransition
  
  // Tracking the transition source ID for debugging
  @State private var activeTransitionID: String? {
    didSet {
//      logger.debug("🔄 activeTransitionID changed: was \(String(describing: oldValue)), now \(String(describing: activeTransitionID))")
    }
  }
  
  // Store the last viewed index for proper transition on dismiss
  @State private var lastViewedIndex: Int = 0 {
    didSet {
//      logger.debug("📌 lastViewedIndex changed: was \(oldValue), now \(lastViewedIndex)")
    }
  }

  init(viewImages: [AppBskyEmbedImages.ViewImage], shouldBlur: Bool) {
    self.viewImages = viewImages
    self.shouldBlur = shouldBlur
    self._isBlurred = State(initialValue: shouldBlur)
//    logger.debug("⚙️ ViewImageGridView initialized with \(viewImages.count) images")
//    for (index, image) in viewImages.enumerated() {
//      logger.debug("   Image \(index): ID=\(image.id)")
//    }
  }

  var body: some View {
    VStack(spacing: 0) {  // Use VStack with zero spacing to better control dimensions
      if viewImages.count == 1 {
        singleImageLayout(viewImages[0])
      } else {
        GeometryReader { geometry in
          Group {
            switch viewImages.count {
            case 2:
              twoImageLayout(geometry: geometry)
            case 3:
              threeImageLayout(geometry: geometry)
            case 4:
              fourImageLayout(geometry: geometry)
            default:
              EmptyView()
            }
          }
        }
        // Force a max height for multi-image layouts to prevent large layout jumps
        .aspectRatio(1.667, contentMode: .fit)
      }
    }
    // Use fixed sizing to prevent layout jumps
    .fixedSize(horizontal: false, vertical: true)
    .fullScreenCover(item: $selectedImage) { initialImage in
      NavigationStack {
        EnhancedImageViewer(
          images: viewImages,
          initialImageId: initialImage.id,
          // Create a proper binding to ensure we track index changes
          currentIndex: Binding(
            get: {
//              logger.debug("🔍 EnhancedImageViewer currentIndex getter - returning: \(currentIndex)")
              return currentIndex
            },
            set: { newIndex in
//              logger.debug("🔄 EnhancedImageViewer currentIndex setter - setting to: \(newIndex)")
              currentIndex = newIndex
              lastViewedIndex = newIndex
              // Store the ID of the current image for transitions
              activeTransitionID = viewImages[newIndex].id
            }
          ),
          isPresented: .init(
            get: {
              let isPresented = selectedImage != nil
//              logger.debug("👁️ EnhancedImageViewer isPresented getter - returning: \(isPresented)")
              return isPresented
            },
            set: { newValue in
//              logger.debug("👁️ EnhancedImageViewer isPresented setter - setting to: \(newValue), lastViewedIndex: \(lastViewedIndex)")
              if !newValue {
                // Remember the current transition ID before dismissal
                activeTransitionID = viewImages[lastViewedIndex].id
//                logger.debug("🚫 Dismissing viewer with transition ID: \(String(describing: activeTransitionID))")
                
                // Delay the dismissal slightly to ensure the transition ID is properly set
                DispatchQueue.main.async {
                  selectedImage = nil
                }
              }
            }
          ),
          namespace: imageTransition
        )
//        .onAppear {
//          logger.debug("📱 EnhancedImageViewer appeared with initial index: \(currentIndex)")
//        }
//        .onDisappear {
//          logger.debug("🏁 EnhancedImageViewer disappeared. Final index: \(currentIndex)")
//        }
      }
      .ignoresSafeArea()
      // Use the specific transition ID for navigation transitions
      .navigationTransition(.zoom(sourceID: activeTransitionID ?? initialImage.id, in: imageTransition))
      .onAppear {
//        logger.debug("🔄 Setting initial transition ID to \(initialImage.id) on fullScreenCover appear")
        activeTransitionID = initialImage.id
      }
      .onDisappear {
//        logger.debug("🔚 fullScreenCover disappeared. Final transition ID: \(String(describing: activeTransitionID)), lastViewedIndex: \(lastViewedIndex)")
      }
    }
    .onChange(of: selectedImage) { _, _ in
//      logger.debug("✅ selectedImage onChange: was \(String(describing: oldValue?.id)), now \(String(describing: newValue?.id))")
    }
    .onChange(of: currentIndex) { _, _ in
//      logger.debug("✅ currentIndex onChange: was \(oldValue), now \(newValue)")
    }
  }

  @ViewBuilder
  private func imageView(
    for viewImage: AppBskyEmbedImages.ViewImage, width: CGFloat, height: CGFloat
  ) -> some View {
    // let aspectRatio: CGFloat = viewImage.aspectRatio.map { CGFloat($0.width) / CGFloat($0.height) } ?? (16/9)

    ZStack {
      RoundedRectangle(cornerRadius: 10)
        .fill(Color.gray.opacity(0.1))
        .frame(width: width, height: height)

      LazyImage(url: URL(string: viewImage.thumb.uriString())) { state in
        if let image = state.image {
          image
            .resizable()
            .aspectRatio(contentMode: .fill)
            .frame(width: width, height: height)
            .blur(radius: isBlurred ? 30 : 0)
            .modifier(BlurOverlayModifier(isBlurred: isBlurred))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .contentShape(RoundedRectangle(cornerRadius: 10))
            .matchedTransitionSource(id: viewImage.id, in: imageTransition) { source in
              source
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }
        } else if state.error != nil {
          Image(systemName: "photo")
            .aspectRatio(contentMode: .fit)
            .frame(width: width * 0.3, height: height * 0.3)
            .foregroundStyle(.secondary)
        } else {
          ProgressView()
            .scaleEffect(0.7)
        }
      }
      .pipeline(ImageLoadingManager.shared.pipeline)
      .priority(.high)
      .processors([
        ImageProcessors.AsyncImageDownscaling(targetSize: CGSize(width: width, height: height))
      ])
    }
    .frame(width: width, height: height)
    .onTapGesture {
      if shouldBlur {
        isBlurred.toggle()
      } else {
        if let index = viewImages.firstIndex(where: { $0.id == viewImage.id }) {
          // Set both currentIndex and selectedImage directly
//          logger.debug("🖱️ Image tapped: ID=\(viewImage.id), setting index to \(index)")
          currentIndex = index
          lastViewedIndex = index
          selectedImage = viewImage
          activeTransitionID = viewImage.id
        }
      }
    }
  }

  @ViewBuilder
  private func singleImageLayout(_ viewImage: AppBskyEmbedImages.ViewImage) -> some View {
    // Use a more consistent aspect ratio with maximum height to avoid large layout jumps
    let aspectRatio =
      viewImage.aspectRatio.map { CGFloat($0.width) / CGFloat($0.height) } ?? (16 / 9)
    let maxHeight: CGFloat = 800  // Maximum height for any image

    GeometryReader { geometry in
      let calculatedHeight = geometry.size.width / aspectRatio
      let height = min(calculatedHeight, maxHeight)  // Limit height

      ZStack {
        RoundedRectangle(cornerRadius: 10)
          .fill(Color.gray.opacity(0.1))
          .frame(maxWidth: .infinity)
          .frame(height: height)

        LazyImage(url: URL(string: viewImage.thumb.uriString())) { state in
          if let image = state.image {
            image
              .resizable()
              .aspectRatio(contentMode: .fill)
              .frame(maxWidth: .infinity)
              .frame(height: height)
              .blur(radius: isBlurred ? 30 : 0)
              .modifier(BlurOverlayModifier(isBlurred: isBlurred))
              .clipShape(RoundedRectangle(cornerRadius: 10))
              .contentShape(Rectangle())
              .matchedTransitionSource(id: viewImage.id, in: imageTransition) { source in
                source
                  .clipShape(RoundedRectangle(cornerRadius: 10))
              }
          } else if state.error != nil {
            Image(systemName: "photo")
              .aspectRatio(contentMode: .fit)
              .frame(width: geometry.size.width * 0.3, height: height * 0.3)
              .foregroundStyle(.secondary)
          } else {
            ProgressView()
              .scaleEffect(0.7)
          }
        }
        .pipeline(ImageLoadingManager.shared.pipeline)
        .priority(.high)
        .processors([
          ImageProcessors.AsyncImageDownscaling(targetSize: CGSize(width: geometry.size.width, height: height))
        ])
      }
      .frame(maxWidth: .infinity)
      .frame(height: height)
      .onTapGesture {
        if shouldBlur {
          isBlurred.toggle()
        } else {
//          logger.debug("🖱️ Single image tapped: ID=\(viewImage.id)")
          currentIndex = 0
          lastViewedIndex = 0
          selectedImage = viewImage
          activeTransitionID = viewImage.id
        }
      }
    }
    .aspectRatio(aspectRatio, contentMode: .fit)
    .frame(maxHeight: maxHeight)
  }

  @ViewBuilder
  private func twoImageLayout(geometry: GeometryProxy) -> some View {
    let columns = [
      GridItem(.flexible(), spacing: 3),
      GridItem(.flexible(), spacing: 3)
    ]

    LazyVGrid(columns: columns, spacing: 3) {
      ForEach(viewImages.prefix(2), id: \.id) { image in
        imageView(
          for: image,
          width: geometry.size.width / 2 - 1.5,
          height: geometry.size.height
        )
      }
    }
    .layoutPriority(1)
  }
  @ViewBuilder
  private func threeImageLayout(geometry: GeometryProxy) -> some View {
    // let leadingColumn = GridItem(.flexible(), spacing: 3)
    let trailingColumns = [
      GridItem(.flexible(), spacing: 3)
    ]

    HStack(spacing: 3) {
      // Leading large image
      imageView(
        for: viewImages[0],
        width: geometry.size.width / 2 - 1.5,
        height: geometry.size.height
      )

      // Trailing column of two images
      LazyVGrid(columns: trailingColumns, spacing: 3) {
        ForEach(viewImages.dropFirst().prefix(2), id: \.id) { image in
          imageView(
            for: image,
            width: geometry.size.width / 2 - 1.5,
            height: geometry.size.height / 2 - 1.5
          )
        }
      }
    }
    .layoutPriority(1)
  }

  @ViewBuilder
  private func fourImageLayout(geometry: GeometryProxy) -> some View {
    let columns = [
      GridItem(.flexible(), spacing: 3),
      GridItem(.flexible(), spacing: 3)
    ]

    LazyVGrid(columns: columns, spacing: 3) {
      ForEach(viewImages.prefix(4), id: \.id) { image in
        imageView(
          for: image,
          width: geometry.size.width / 2 - 1.5,
          height: geometry.size.height / 2 - 1.5
        )
      }
    }
    .layoutPriority(1)
  }
}

// MARK: - ImageViewerItemView with VisionKit Support
struct ImageViewerItemView: UIViewRepresentable {
  let image: AppBskyEmbedImages.ViewImage
  @Binding var liveTextEnabled: Bool
  var liveTextSupported: Bool
  @Environment(\.displayScale) var displayScale
  
  private let logger = Logger(subsystem: "blue.catbird", category: "ImageViewerItemView")
  
  func makeUIView(context: Context) -> UIView {
    let containerView = UIView()
    containerView.backgroundColor = .clear

    let imageView = UIImageView()
    imageView.contentMode = .scaleAspectFit
    imageView.backgroundColor = .clear
    imageView.translatesAutoresizingMaskIntoConstraints = false

    containerView.addSubview(imageView)
    NSLayoutConstraint.activate([
      imageView.topAnchor.constraint(equalTo: containerView.topAnchor),
      imageView.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
      imageView.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
      imageView.bottomAnchor.constraint(equalTo: containerView.bottomAnchor)
    ])

    // Set up the image analysis interaction if supported
    if liveTextSupported {
      let imageAnalysisInteraction = ImageAnalysisInteraction()
      imageView.addInteraction(imageAnalysisInteraction)
      context.coordinator.imageAnalysisInteraction = imageAnalysisInteraction

      // Configure initial state
      imageAnalysisInteraction.preferredInteractionTypes = .automatic

      // Only set analysis when liveTextEnabled is true
      if liveTextEnabled {
        context.coordinator.enableLiveText()
      }
    }

    // Add long press gesture for share sheet
    let longPressGesture = UILongPressGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleLongPress(_:)))
    containerView.addGestureRecognizer(longPressGesture)

    // Set up accessibility
    containerView.isAccessibilityElement = true
    containerView.accessibilityLabel = image.alt.isEmpty ? "Image" : image.alt
    containerView.accessibilityTraits = .image

    // Add accessibility actions for navigation
    containerView.accessibilityCustomActions = [
      UIAccessibilityCustomAction(
        name: "Next Image",
        target: context.coordinator,
        selector: #selector(Coordinator.nextImage)
      ),
      UIAccessibilityCustomAction(
        name: "Previous Image",
        target: context.coordinator,
        selector: #selector(Coordinator.previousImage)
      ),
      UIAccessibilityCustomAction(
        name: "Close Image Viewer",
        target: context.coordinator,
        selector: #selector(Coordinator.closeViewer)
      )
    ]

    context.coordinator.imageView = imageView
    context.coordinator.containerView = containerView

    // Load the image
    loadImage(into: imageView, context: context)

    return containerView
  }
  
  func updateUIView(_ uiView: UIView, context: Context) {
    // Update live text state if needed
    if liveTextSupported {
      if liveTextEnabled {
        context.coordinator.enableLiveText()
      } else {
        context.coordinator.disableLiveText()
      }
    }
  }
  
  func makeCoordinator() -> Coordinator {
    Coordinator(self)
  }
  
  private func loadImage(into imageView: UIImageView, context: Context) {
    guard let imageUrl = URL(string: image.fullsize.uriString()) else { return }
    
    // Use the shared pipeline to load the image
    ImageLoadingManager.shared.pipeline.loadImage(
      with: imageUrl,
      completion: { result in
        if case .success(let response) = result {
          imageView.image = response.image
          context.coordinator.currentImage = response.image
          
          // If live text is enabled, analyze the image
          if self.liveTextEnabled && self.liveTextSupported {
            context.coordinator.enableLiveText()
          }
        }
      }
    )
  }
  
  class Coordinator: NSObject {
    private let parent: ImageViewerItemView
    var imageView: UIImageView?
    var containerView: UIView?
    var currentImage: UIImage?
    var imageAnalysisInteraction: ImageAnalysisInteraction?
    private var imageAnalyzer = ImageAnalyzer()
    private var isAnalyzing = false

    init(_ parent: ImageViewerItemView) {
      self.parent = parent
    }

    func enableLiveText() {
      guard let currentImage = currentImage,
            let imageAnalysisInteraction = imageAnalysisInteraction,
            !isAnalyzing,
            parent.liveTextSupported else { return }

      isAnalyzing = true

      // Analyze the image on a background thread
      Task {
        do {
          let configuration = ImageAnalyzer.Configuration([.text, .machineReadableCode, .visualLookUp])
          if let analysis = try? await imageAnalyzer.analyze(currentImage, configuration: configuration) {
            await MainActor.run {
              imageAnalysisInteraction.analysis = analysis
              imageAnalysisInteraction.preferredInteractionTypes = .automatic
              isAnalyzing = false
            }
          }
        } catch {
          await MainActor.run {
            parent.logger.error("Error analyzing image: \(error.localizedDescription)")
            isAnalyzing = false
          }
        }
      }
    }

    func disableLiveText() {
      // Disable live text by clearing the analysis
      Task { @MainActor in
        imageAnalysisInteraction?.analysis = nil
      }
    }

    @objc func handleLongPress(_ gestureRecognizer: UILongPressGestureRecognizer) {
      guard gestureRecognizer.state == .began, let currentImage = currentImage else { return }

      shareImage(currentImage)
    }

    // MARK: - Accessibility Actions

    @objc func nextImage() -> Bool {
      // Post a notification that will be handled by the parent view
      NotificationCenter.default.post(
        name: Notification.Name("LazyPagerNextImage"),
        object: nil
      )

      // Announce the navigation to the user
      UIAccessibility.post(
        notification: .announcement,
        argument: "Moving to next image"
      )

      return true
    }

    @objc func previousImage() -> Bool {
      // Post a notification that will be handled by the parent view
      NotificationCenter.default.post(
        name: Notification.Name("LazyPagerPreviousImage"),
        object: nil
      )

      // Announce the navigation to the user
      UIAccessibility.post(
        notification: .announcement,
        argument: "Moving to previous image"
      )

      return true
    }

    @objc func closeViewer() -> Bool {
      // Post a notification that will be handled by the parent view
      NotificationCenter.default.post(
        name: Notification.Name("LazyPagerCloseViewer"),
        object: nil
      )

      UIAccessibility.post(
        notification: .announcement,
        argument: "Closing image viewer"
      )

      return true
    }
    
    func shareImage(_ image: UIImage) {
      // Create temporary URL for the image to share
      if let imageData = image.jpegData(compressionQuality: 0.9) {
        let tempDirectoryURL = FileManager.default.temporaryDirectory
        let imageName = UUID().uuidString
        let imageURL = tempDirectoryURL.appendingPathComponent("\(imageName).jpg")
        
        do {
          try imageData.write(to: imageURL)
          
          // Use UIActivityViewController with the URL
          let activityViewController = UIActivityViewController(
            activityItems: [imageURL],
            applicationActivities: nil
          )
          
          // Find the top-most presented view controller
          if let keyWindow = UIApplication.shared.windows.first(where: { $0.isKeyWindow }),
             let rootViewController = keyWindow.rootViewController {
            
            var topController = rootViewController
            while let presentedVC = topController.presentedViewController {
              // Stop at a specific level - don't try to present from an already presenting controller
              if presentedVC is UINavigationController {
                break
              }
              topController = presentedVC
            }
            
            // Configure for iPad
            if let popoverController = activityViewController.popoverPresentationController {
              if let containerView = containerView {
                popoverController.sourceView = containerView
                popoverController.sourceRect = CGRect(x: containerView.bounds.midX, y: containerView.bounds.midY, width: 0, height: 0)
                popoverController.permittedArrowDirections = []
              }
            }
            
            // Present the share sheet
            DispatchQueue.main.async {
              topController.present(activityViewController, animated: true)
            }
          }
          
          // Clean up the temporary file after a delay
          DispatchQueue.main.asyncAfter(deadline: .now() + 60) {
            try? FileManager.default.removeItem(at: imageURL)
          }
        } catch {
          parent.logger.error("Failed to save image for sharing: \(error.localizedDescription)")
        }
      }
    }
  }
}

// MARK: - EnhancedImageViewer
struct EnhancedImageViewer: View {
  let images: [AppBskyEmbedImages.ViewImage]
  let initialImageId: String // Store the initial image ID
  @Binding var currentIndex: Int
  @Binding var isPresented: Bool
  var namespace: Namespace.ID
  @State private var showAltText = true
  @State private var isAltTextExpanded = false
  @State private var opacity: CGFloat = 1
  @State private var showControls = true
  @State private var liveTextSupported = false
  @State private var liveTextEnabled = false
  @Environment(\.horizontalSizeClass) var horizontalSizeClass
  
  // Log for tracking state changes
  private let logger = Logger(subsystem: "blue.catbird", category: "EnhancedImageViewer")
  
  // Reference to current view controllers
  @State private var pagerViewControllers: [Int: UIViewController] = [:]

  init(images: [AppBskyEmbedImages.ViewImage], initialImageId: String, currentIndex: Binding<Int>, isPresented: Binding<Bool>, namespace: Namespace.ID) {
    self.images = images
    self.initialImageId = initialImageId
    self._currentIndex = currentIndex
    self._isPresented = isPresented
    self.namespace = namespace
    
    // Check if Live Text is supported on this device
    _liveTextSupported = State(initialValue: ImageAnalyzer.isSupported)
    
    // Initialize with the correct index based on the initial image ID
    if let initialIndex = images.firstIndex(where: { $0.id == initialImageId }) {
//      logger.debug("⚙️ EnhancedImageViewer initialized with initialIndex: \(initialIndex) for image ID: \(initialImageId)")
    } else {
//      logger.debug("⚠️ EnhancedImageViewer could not find initial image ID: \(initialImageId)")
    }
  }

  var body: some View {
    GeometryReader { _ in
      ZStack {
        Color.black
          .opacity(opacity)
          .ignoresSafeArea()

        LazyPager(data: images, page: $currentIndex) { image in
          ImageViewerItemView(
            image: image,
            liveTextEnabled: $liveTextEnabled,
            liveTextSupported: liveTextSupported
          )
          .accessibilityElement(children: .contain)
          .accessibilityLabel(image.alt)
          .accessibilityAddTraits(.isImage)
          .accessibilityValue("Image \(currentIndex + 1) of \(images.count)")
          .onAppear {
            // This would be used if we needed to track the current image viewer item
            if let index = images.firstIndex(where: { $0.id == image.id }) {
              // Store reference to this view controller if needed
            }
          }
        }
        .zoomable(min: 1.0, max: 4.0, doubleTapGesture: .scale(2.0))
        .onDismiss(backgroundOpacity: $opacity) {
//          logger.debug("🚪 LazyPager onDismiss called from gesture. currentIndex: \(currentIndex)")
          isPresented = false
        }
        .onTap {
          withAnimation {
            showControls.toggle()
            showAltText = showControls

            if !showAltText {
              isAltTextExpanded = false
            }
          }
        }
        .settings { config in
            config.dismissVelocity = 1.5
            config.dismissTriggerOffset = 1
            config.dismissAnimationLength = 0.3
            config.fullFadeOnDragAt = 0.3
            config.pinchGestureEnableOffset = 15
            config.shouldCancelSwiftUIAnimationsOnDismiss = false
        }
        .id("pager-\(images.count)") // Add ID to ensure proper refresh

        // Invisible navigation buttons for VoiceOver
        VStack {
          HStack {
            // Previous image button
            Button(action: {
              if currentIndex > 0 {
                currentIndex -= 1
              }
            }) {
              Image(systemName: "chevron.left")
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
            }
            .disabled(currentIndex <= 0)
            .accessibilityLabel("Previous image")
            .accessibilityHint(currentIndex > 0 ? "Navigate to previous image" : "This is the first image")

            Spacer()

            // Close button
            Button(action: {
              isPresented = false
            }) {
              Image(systemName: "xmark")
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
            }
            .accessibilityLabel("Close image viewer")

            Spacer()

            // Next image button
            Button(action: {
              if currentIndex < images.count - 1 {
                currentIndex += 1
              }
            }) {
              Image(systemName: "chevron.right")
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
            }
            .disabled(currentIndex >= images.count - 1)
            .accessibilityLabel("Next image")
            .accessibilityHint(currentIndex < images.count - 1 ? "Navigate to next image" : "This is the last image")
          }
          .padding(.horizontal)
          .padding(.top, 44)
        }
        .allowsHitTesting(UIAccessibility.isVoiceOverRunning)
        .opacity(0) // Invisible but available to VoiceOver

        // Header (title, controls, and close button)
        if showControls {
          VStack {
            HStack {
              Text("\(currentIndex + 1) of \(images.count)")
                .foregroundColor(.white)
                .padding(.leading)

              Spacer()

              // Live Text button - only show if supported
              if liveTextSupported {
                Button {
                  liveTextEnabled.toggle()
                } label: {
                  Image(systemName: liveTextEnabled ? "text.viewfinder.fill" : "text.viewfinder")
                    .font(.title2)
                    .foregroundColor(.white)
                    .frame(width: 40, height: 40)
                }
                .padding(.trailing, 8)
              }

              // Share button
              Button {
                shareCurrentImage()
              } label: {
                Image(systemName: "square.and.arrow.up")
                  .font(.title2)
                  .foregroundColor(.white)
                  .offset(y: -3)

                  .frame(width: 40, height: 40)
              }
              .padding(.trailing, 8)

              Button {
                isPresented = false
              } label: {
                Image(systemName: "xmark")
                  .foregroundColor(.white)
                  .font(.title2)
                  .frame(width: 40, height: 40)
              }
              .padding(.trailing, 8)

            }
            .background(
              LinearGradient(
                colors: [.black.opacity(0.6), .clear],
                startPoint: .top,
                endPoint: .bottom
              )
            )
            .opacity(opacity)

            Spacer()
          }
        }
        
        // Alt text view at bottom
        if showAltText && !images[currentIndex].alt.isEmpty {
          VStack {
            Spacer()
            altTextView
              .opacity(opacity)
              .transition(.move(edge: .bottom).combined(with: .opacity))
              .padding(.bottom, 16) // Standard padding since controls are now at the top
          }
        }
        
      }
      .background(Color.black)
      // Use a dynamic sourceID based on the current index
      .navigationTransition(.zoom(sourceID: images[currentIndex].id, in: namespace))
      .task {
        await prefetchFullSizeImages()
      }
      .onAppear {
        setupNotificationHandlers()
      }
      .onDisappear {
        removeNotificationHandlers()
      }
      .onChange(of: currentIndex) { _, newValue in
        // Announce the image change to VoiceOver
        if UIAccessibility.isVoiceOverRunning {
          let imageCount = images.count
          let announcement = "Image \(newValue + 1) of \(imageCount)"

          if let alt = images[safe: newValue]?.alt, !alt.isEmpty {
            UIAccessibility.post(
              notification: .announcement,
              argument: "\(announcement). \(alt)"
            )
          } else {
            UIAccessibility.post(
              notification: .announcement,
              argument: announcement
            )
          }

          // Post page scrolled notification for better VoiceOver feedback
          UIAccessibility.post(
            notification: .pageScrolled,
            argument: "Image \(newValue + 1) of \(imageCount)"
          )
        }
      }
    }
  }

  private var altTextView: some View {
    VStack(spacing: 4) {
      Text(images[currentIndex].alt)
        .font(.caption)
        .lineLimit(isAltTextExpanded ? nil : 2)
        .multilineTextAlignment(.leading)

      if !isAltTextExpanded {
        Button(action: {
          withAnimation(.easeInOut(duration: 0.2)) {
            isAltTextExpanded = true
          }
        }) {
          Text("Show More")
            .font(.caption2)
            .foregroundColor(Color.accentColor)
        }
        .accessibilityLabel("Show more alt text")
      }
    }
    .padding(10)
    .frame(maxWidth: .infinity)
    .background(Material.ultraThin)
    .cornerRadius(10)
    .padding(.horizontal)
    .accessibilityElement(children: isAltTextExpanded ? .contain : .combine)
    .accessibilityLabel(isAltTextExpanded ? "Alt text" : "Alt text (collapsed)")
    .accessibilityValue(images[currentIndex].alt)
    .accessibilityAddTraits(.isButton)
    .accessibilityHint(isAltTextExpanded ? "Double tap to collapse" : "Double tap to expand")
    .onTapGesture {
      withAnimation(.easeInOut(duration: 0.2)) {
        isAltTextExpanded.toggle()
      }
    }
  }

  private func prefetchFullSizeImages() async {
    let urls = images.compactMap { URL(string: $0.fullsize.uriString()) }
    let manager = ImageLoadingManager.shared
    await manager.prefetchImages(urls: urls)
  }
  
  private func shareCurrentImage() {
    // Create and present share sheet using UIKit
    guard let window = UIApplication.shared.windows.first(where: { $0.isKeyWindow }),
          let topVC = window.rootViewController?.topmostPresentedViewController() else { return }
    
    // Load the image to be shared
    let imageUrl = URL(string: images[currentIndex].fullsize.uriString())!
    
    ImageLoadingManager.shared.pipeline.loadImage(
      with: imageUrl,
      completion: { result in
        if case .success(let response) = result {
          // Got the image, now share it
          shareImage(response.image, from: topVC)
        }
      }
    )
  }
  
  private func shareImage(_ image: UIImage, from viewController: UIViewController) {
    guard let imageData = image.jpegData(compressionQuality: 0.9) else { return }

    let tempDirectoryURL = FileManager.default.temporaryDirectory
    let imageName = UUID().uuidString
    let imageURL = tempDirectoryURL.appendingPathComponent("\(imageName).jpg")

    do {
      try imageData.write(to: imageURL)

      // Create share sheet
      let activityVC = UIActivityViewController(
        activityItems: [imageURL],
        applicationActivities: nil
      )

      // Configure for iPad
      if UIDevice.current.userInterfaceIdiom == .pad {
        activityVC.popoverPresentationController?.sourceView = viewController.view
        activityVC.popoverPresentationController?.sourceRect = CGRect(
          x: viewController.view.bounds.midX,
          y: viewController.view.bounds.midY,
          width: 0,
          height: 0
        )
        activityVC.popoverPresentationController?.permittedArrowDirections = []
      }

      // Present the share sheet
      DispatchQueue.main.async {
        viewController.present(activityVC, animated: true)
      }

      // Clean up temp file after sharing
      DispatchQueue.main.asyncAfter(deadline: .now() + 60) {
        try? FileManager.default.removeItem(at: imageURL)
      }
    } catch {
      logger.error("Failed to save image for sharing: \(error.localizedDescription)")
    }
  }

  // MARK: - Notification Handlers

  private func setupNotificationHandlers() {
    // Next image notification handler
    NotificationCenter.default.addObserver(
      forName: Notification.Name("LazyPagerNextImage"),
      object: nil,
      queue: .main
    ) { [self] _ in
      guard currentIndex < images.count - 1 else { return }
      currentIndex += 1
    }

    // Previous image notification handler
    NotificationCenter.default.addObserver(
      forName: Notification.Name("LazyPagerPreviousImage"),
      object: nil,
      queue: .main
    ) { [self] _ in
      guard currentIndex > 0 else { return }
      currentIndex -= 1
    }

    // Close viewer notification handler
    NotificationCenter.default.addObserver(
      forName: Notification.Name("LazyPagerCloseViewer"),
      object: nil,
      queue: .main
    ) { [self] _ in
      isPresented = false
    }
  }

  private func removeNotificationHandlers() {
    NotificationCenter.default.removeObserver(self)
  }
}

// MARK: - View Modifiers
struct BlurOverlayModifier: ViewModifier {
  let isBlurred: Bool

  func body(content: Content) -> some View {
    content.overlay(
      Group {
        if isBlurred {
          Text("Sensitive Content")
            .foregroundColor(.white)
            .padding(6)
            .background(Color.black.opacity(0.7))
            .cornerRadius(10)
        }
      }
    )
  }
}

// MARK: - Helper Extensions

extension AppBskyEmbedImages.ViewImage: @retroactive Identifiable {
  public var id: String {
    fullsize.uriString()
  }
}

// MARK: - Array Extension for Safe Index Access
extension Array {
  subscript(safe index: Index) -> Element? {
    return indices.contains(index) ? self[index] : nil
  }
}
