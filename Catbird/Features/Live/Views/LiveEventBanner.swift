import SwiftUI
import Petrel

struct LiveEventBanner: View {
    enum Style {
        case wide
        case compact
    }

    let event: LiveEventFeed
    let style: Style
    @Environment(AppState.self) private var appState
    @State private var showingUndo = false
    @State private var showErrorAlert = false
    @State private var errorMessage: String? = nil
    @State private var retryHideAll = false

    init(event: LiveEventFeed, style: Style = .wide) {
        self.event = event
        self.style = style
    }

    private var layout: LiveEventFeedLayout? {
        style == .wide ? (event.wideLayout ?? event.compactLayout) : (event.compactLayout ?? event.wideLayout)
    }

    var body: some View {
        if showingUndo {
            undoView
        } else {
            bannerContent
        }
    }

    private var undoView: some View {
        HStack(spacing: 12) {
            Image(systemName: "eye.slash")
                .foregroundColor(.secondary)
            Text(retryHideAll ? "All live events hidden" : "Live event hidden")
                .font(.subheadline)
                .foregroundColor(.primary)
            Spacer()
            Button {
                Task { await undoHide() }
            } label: {
                Text("Undo")
                    .font(.subheadline.bold())
                    .foregroundColor(.accentColor)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .frame(height: style == .wide ? 60 : 44)
        .background(Color(uiColor: .secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding(.horizontal)
    }

    private var bannerContent: some View {
        Button {
            openEventFeed()
        } label: {
            ZStack(alignment: .bottomLeading) {
                // Background image or gradient
                if let imageStr = layout?.image, let imageURL = URL(string: imageStr) {
                    AsyncImage(url: imageURL) { phase in
                        switch phase {
                        case .success(let image):
                            image
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                        default:
                            fallbackBackground
                        }
                    }
                } else {
                    fallbackBackground
                }

                // Gradient overlay
                LinearGradient(
                    colors: [Color.black.opacity(0.1), Color.black.opacity(0.75)],
                    startPoint: .top,
                    endPoint: .bottom
                )

                // Content
                HStack(alignment: .bottom) {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Circle()
                                .fill(Color.red)
                                .frame(width: 8, height: 8)
                            Text("LIVE")
                                .font(.caption2.bold())
                                .foregroundColor(.white)
                        }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.black.opacity(0.6))
                        .clipShape(Capsule())

                        Text(layout?.title ?? event.title)
                            .font(style == .wide ? .headline.bold() : .subheadline.bold())
                            .foregroundColor(.white)
                            .lineLimit(2)
                    }

                    Spacer()

                    Menu {
                        Button {
                            Task { await hideThisEvent() }
                        } label: {
                            Label("Hide this event", systemImage: "eye.slash")
                        }

                        Button(role: .destructive) {
                            Task { await hideAllEvents() }
                        } label: {
                            Label("Hide all live events", systemImage: "xmark.circle")
                        }
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 20))
                            .foregroundColor(.white.opacity(0.8))
                    } primaryAction: {
                        Task { await hideThisEvent() }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Dismiss live event")
                }
                .padding(style == .wide ? 14 : 10)
            }
            .frame(height: style == .wide ? 120 : 80)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .padding(.horizontal)
        .alert("Error", isPresented: $showErrorAlert) {
            Button("Retry") {
                Task {
                    if retryHideAll {
                        await hideAllEvents()
                    } else {
                        await hideThisEvent()
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "Failed to update live event preferences.")
        }
    }

    private var fallbackBackground: some View {
        LinearGradient(
            colors: [Color.blue.opacity(0.8), Color.purple.opacity(0.8)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private func openEventFeed() {
        if let url = URL(string: event.url) {
            _ = appState.urlHandler.handle(url)
        }
    }

    private func hideThisEvent() async {
        retryHideAll = false
        errorMessage = nil
        do {
            try await appState.liveEventService.hideEvent(id: event.id)
            withAnimation {
                showingUndo = true
            }
            appState.toastManager.show(
                ToastItem(message: "Live event hidden", icon: "eye.slash", duration: 3.0)
            )
            Task {
                try? await Task.sleep(for: .seconds(5))
                if showingUndo {
                    withAnimation {
                        showingUndo = false
                    }
                }
            }
        } catch {
            errorMessage = error.localizedDescription
            showErrorAlert = true
            appState.toastManager.show(
                ToastItem(message: "Failed to hide live event: \(error.localizedDescription)", icon: "exclamationmark.triangle.fill")
            )
        }
    }

    private func hideAllEvents() async {
        retryHideAll = true
        errorMessage = nil
        do {
            try await appState.liveEventService.hideAllEvents()
            withAnimation {
                showingUndo = true
            }
            appState.toastManager.show(
                ToastItem(message: "All live events hidden", icon: "xmark.circle", duration: 3.0)
            )
            Task {
                try? await Task.sleep(for: .seconds(5))
                if showingUndo {
                    withAnimation {
                        showingUndo = false
                    }
                }
            }
        } catch {
            errorMessage = error.localizedDescription
            showErrorAlert = true
            appState.toastManager.show(
                ToastItem(message: "Failed to hide live events: \(error.localizedDescription)", icon: "exclamationmark.triangle.fill")
            )
        }
    }

    private func undoHide() async {
        do {
            try await appState.liveEventService.undoLastHide()
            withAnimation {
                showingUndo = false
            }
            appState.toastManager.show(
                ToastItem(message: "Live event restored", icon: "arrow.uturn.backward.circle.fill", duration: 3.0)
            )
        } catch {
            errorMessage = error.localizedDescription
            showErrorAlert = true
            appState.toastManager.show(
                ToastItem(message: "Failed to undo: \(error.localizedDescription)", icon: "exclamationmark.triangle.fill")
            )
        }
    }
}
