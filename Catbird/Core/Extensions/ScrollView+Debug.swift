//import SwiftUI
//import Combine
//
//// Global settings for scroll debugging
//enum ScrollDebugSettings {
//    static var isEnabled = true
//    static var logEvents = true
//    static var stabilizeContentShifts = true
//    static var captureStackTraces = false
//    
//    // Records of significant events
//    static var contentShiftEvents: [ContentShiftEvent] = []
//    
//    struct ContentShiftEvent: Identifiable {
//        let id = UUID()
//        let timestamp = Date()
//        let viewDescription: String
//        let oldHeight: CGFloat
//        let newHeight: CGFloat
//        let delta: CGFloat
//        let stackTrace: [String]?
//        
//        static func record(viewDescription: String, oldHeight: CGFloat, newHeight: CGFloat) {
//            let event = ContentShiftEvent(
//                viewDescription: viewDescription,
//                oldHeight: oldHeight,
//                newHeight: newHeight,
//                delta: newHeight - oldHeight,
//                stackTrace: captureStackTraces ? Thread.callStackSymbols : nil
//            )
//            
//            DispatchQueue.main.async {
//                contentShiftEvents.append(event)
//                // Keep the history manageable
//                if contentShiftEvents.count > 50 {
//                    contentShiftEvents.removeFirst(10)
//                }
//            }
//        }
//    }
//}
//
//// Create a dedicated DebugScrollView instead of extending ScrollView
//struct DebugScrollView<Content: View>: View {
//    let axes: Axis.Set
//    let showsIndicators: Bool
//    let viewName: String
//    let content: Content
//    
//    init(
//        _ axes: Axis.Set = .vertical,
//        showsIndicators: Bool = true,
//        debugName viewName: String,
//        @ViewBuilder content: () -> Content
//    ) {
//        self.axes = axes
//        self.showsIndicators = showsIndicators
//        self.viewName = viewName
//        self.content = content()
//    }
//    
//    var body: some View {
//        ScrollView(axes, showsIndicators: showsIndicators) {
//            if ScrollDebugSettings.isEnabled {
//                ScrollViewDebugWrapper(
//                    viewName: viewName,
//                    content: content
//                )
//            } else {
//                content
//            }
//        }
//    }
//}
//
///// Internal wrapper to monitor scroll view content for significant size changes
//private struct ScrollViewDebugWrapper<Content: View>: View {
//    let viewName: String
//    let content: Content
//    
//    @State private var contentHeight: CGFloat = 0
//    @State private var contentWidth: CGFloat = 0
//    @State private var isInitialMeasurement = true
//    @State private var fixedContentSize: CGSize?
//    @State private var lastUpdateTime = Date()
//    @State private var updateLock = false
//    
//    // Cooldown to prevent rapid updates causing scroll jumps
//    private let updateCooldownSeconds: TimeInterval = 0.5
//    private let significantHeightChangeDelta: CGFloat = 20
//    
//    var body: some View {
//        content
//            .background(
//                GeometryReader { proxy in
//                    Color.clear
//                        .onAppear {
//                            // Initial measurement
//                            contentHeight = proxy.size.height
//                            contentWidth = proxy.size.width
//                            isInitialMeasurement = false
//                            
//                            if ScrollDebugSettings.logEvents {
//                                print("📜 DEBUG ScrollView '\(viewName)' - Initial content size: \(contentWidth) x \(contentHeight)")
//                            }
//                        }
//                        .onChange(of: proxy.size) { oldSize, newSize in
//                            let now = Date()
//                            let timeSinceLastUpdate = now.timeIntervalSince(lastUpdateTime)
//                            let heightDelta = newSize.height - oldSize.height
//                            
//                            // Monitor for significant height changes
//                            if !isInitialMeasurement && abs(heightDelta) > significantHeightChangeDelta {
//                                if ScrollDebugSettings.logEvents {
//                                    print("⚠️ DEBUG ScrollView '\(viewName)' - Significant content height change:")
//                                    print("   Old: \(oldSize.height)px, New: \(newSize.height)px (Δ\(heightDelta)px)")
//                                    print("   Time since last update: \(timeSinceLastUpdate)s")
//                                }
//                                
//                                // Record the content shift event
//                                ScrollDebugSettings.ContentShiftEvent.record(
//                                    viewDescription: viewName,
//                                    oldHeight: oldSize.height,
//                                    newHeight: newSize.height
//                                )
//                                
//                                // Apply size stabilization if enabled
//                                if ScrollDebugSettings.stabilizeContentShifts && !updateLock {
//                                    if timeSinceLastUpdate < updateCooldownSeconds {
//                                        // Too soon after last update - apply temporary lock
//                                        updateLock = true
//                                        
//                                        // Use the previous size to prevent scroll jump
//                                        fixedContentSize = oldSize
//                                        
//                                        if ScrollDebugSettings.logEvents {
//                                            print("🔒 DEBUG ScrollView '\(viewName)' - Stabilizing content size temporarily")
//                                        }
//                                        
//                                        // Schedule release of lock after cooldown
//                                        DispatchQueue.main.asyncAfter(deadline: .now() + updateCooldownSeconds) {
//                                            updateLock = false
//                                            fixedContentSize = nil
//                                            lastUpdateTime = Date()
//                                            
//                                            if ScrollDebugSettings.logEvents {
//                                                print("🔓 DEBUG ScrollView '\(viewName)' - Releasing size stabilization")
//                                            }
//                                        }
//                                    }
//                                }
//                            }
//                            
//                            // Update tracking properties
//                            if !updateLock {
//                                contentHeight = newSize.height
//                                contentWidth = newSize.width
//                                lastUpdateTime = now
//                            }
//                        }
//                }
//            )
//            // Apply size stabilization during rapid content changes
//            .frame(
//                width: fixedContentSize?.width,
//                height: fixedContentSize?.height,
//                alignment: .top
//            )
//    }
//}
//
//// Preview for the debug overlay
//#Preview {
//    VStack {
//        Text("Scroll Debugging Test")
//            .font(.headline)
//        
//        DebugScrollView(debugName: "TestScrollView") {
//            VStack(spacing: 20) {
//                ForEach(1..<10) { i in
//                    Text("Item \(i)")
//                        .frame(maxWidth: .infinity)
//                        .frame(height: 60)
//                        .background(Color.blue.opacity(0.1))
//                        .cornerRadius(8)
//                }
//                
//                Button("Add Content") {
//                    // This would simulate content being added
//                }
//                .padding()
//            }
//            .padding()
//        }
//    }
//}
