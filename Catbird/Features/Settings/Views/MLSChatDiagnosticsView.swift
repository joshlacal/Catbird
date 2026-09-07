//
//  MLSChatDiagnosticsView.swift
//  Catbird
//
//  Diagnostics view for encrypted chat events, failures, and coordinates.
//

import CatbirdMLSCore
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// View displaying recent MLS encrypted chat diagnostic records
struct MLSChatDiagnosticsView: View {
  @Environment(AppState.self) private var appState
  @State private var records: [MLSDiagnosticRecord] = []
  @State private var isLoading = false
  @State private var showingCopiedToast = false

  var body: some View {
    ResponsiveContentView {
      List {
        headerSection

        if records.isEmpty && !isLoading {
          emptyStateSection
        } else {
          recordsSection
        }
      }
    }
    .navigationTitle("Chat Diagnostics")
    #if os(iOS)
    .navigationBarTitleDisplayMode(.inline)
    #endif
    .toolbar {
      ToolbarItem(placement: .primaryAction) {
        Menu {
          ShareLink(item: exportText) {
            Label("Share Diagnostics", systemImage: "square.and.arrow.up")
          }
          .disabled(records.isEmpty)

          Button {
            copyToClipboard()
          } label: {
            Label("Copy Trail", systemImage: "doc.on.doc")
          }
          .disabled(records.isEmpty)

          Divider()

          Button {
            loadRecords()
          } label: {
            Label("Refresh", systemImage: "arrow.clockwise")
          }

          Button(role: .destructive) {
            clearRecords()
          } label: {
            Label("Clear Trail", systemImage: "trash")
          }
          .disabled(records.isEmpty)
        } label: {
          Image(systemName: "ellipsis.circle")
        }
      }
    }
    .overlay(alignment: .bottom) {
      if showingCopiedToast {
        toastView
          .transition(.move(edge: .bottom).combined(with: .opacity))
      }
    }
    .task {
      loadRecords()
    }
  }

  // MARK: - Sections

  private var headerSection: some View {
    Section {
      VStack(alignment: .leading, spacing: 6) {
        Text("Recent encrypted chat activity, recovery events, and delivery errors. No message content, keys, or tokens are ever recorded.")
          .foregroundStyle(.secondary)
          .appFont(AppTextRole.caption)

        if !records.isEmpty {
          HStack {
            Text("\(records.count) event\(records.count == 1 ? "" : "s") recorded")
              .font(.caption2)
              .foregroundStyle(.tertiary)
            Spacer()
            ShareLink(item: exportText) {
              Label("Export", systemImage: "square.and.arrow.up")
                .font(.caption2)
            }
          }
          .padding(.top, 2)
        }
      }
      .padding(.vertical, 2)
    }
  }

  private var emptyStateSection: some View {
    Section {
      VStack(spacing: 12) {
        Image(systemName: "checkmark.shield.fill")
          .font(.system(size: 36))
          .foregroundStyle(.green)
          .padding(.top, 16)

        Text("No Diagnostic Events")
          .appFont(AppTextRole.headline)

        Text("Encrypted chat is healthy. No delivery failures, coordination errors, or recovery pauses have been recorded.")
          .multilineTextAlignment(.center)
          .foregroundStyle(.secondary)
          .appFont(AppTextRole.caption)
          .padding(.horizontal)
          .padding(.bottom, 16)
      }
      .frame(maxWidth: .infinity)
      .listRowBackground(Color.clear)
    }
  }

  private var recordsSection: some View {
    Section("Recent Events") {
      ForEach(records.indices, id: \.self) { index in
        let record = records[index]
        DiagnosticRecordRow(record: record)
      }
    }
  }

  // MARK: - Toast

  private var toastView: some View {
    Text("Copied to clipboard")
      .font(.subheadline.bold())
      .foregroundStyle(.white)
      .padding(.horizontal, 16)
      .padding(.vertical, 10)
      .background(.black.opacity(0.8), in: Capsule())
      .padding(.bottom, 24)
  }

  // MARK: - Data Operations (Off Main-Actor Buffer Read)

  private var exportText: String {
    MLSDiagnostics.exportText()
  }

  private func loadRecords() {
    isLoading = true
    // Non-blocking read from UserDefaults ring buffer
    Task.detached(priority: .userInitiated) {
      let fetched = MLSDiagnostics.recent(limit: 100)
      await MainActor.run {
        self.records = fetched
        self.isLoading = false
      }
    }
  }

  private func clearRecords() {
    MLSDiagnostics.clear()
    records = []
  }

  private func copyToClipboard() {
    #if canImport(UIKit)
    UIPasteboard.general.string = exportText
    #endif
    withAnimation {
      showingCopiedToast = true
    }
    Task {
      try? await Task.sleep(nanoseconds: 2_000_000_000)
      withAnimation {
        showingCopiedToast = false
      }
    }
  }
}

// MARK: - Row View

private struct DiagnosticRecordRow: View {
  let record: MLSDiagnosticRecord

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      // Top line: Status Icon + Event Name + Time
      HStack(alignment: .center, spacing: 6) {
        eventIcon
          .font(.caption)

        Text(eventTitle)
          .font(.subheadline.weight(.semibold))
          .foregroundStyle(eventColor)

        Spacer()

        Text(record.occurredAt, style: .time)
          .font(.caption2)
          .foregroundStyle(.secondary)
      }

      // Code / Reason
      HStack(alignment: .top, spacing: 4) {
        Text("Code:")
          .font(.caption2.weight(.medium))
          .foregroundStyle(.secondary)
        Text(friendlyCode)
          .font(.system(.caption2, design: .monospaced))
          .foregroundStyle(.primary)
          .textSelection(.enabled)
      }

      // Metadata Grid / Badges
      let tags = metadataTags
      if !tags.isEmpty {
        FlowLayout(horizontalSpacing: 6, verticalSpacing: 4) {
          ForEach(tags, id: \.label) { tag in
            HStack(spacing: 3) {
              Text(tag.label)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
              Text(tag.value)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(.primary)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 4))
          }
        }
      }
    }
    .padding(.vertical, 4)
    .accessibilityElement(children: .combine)
    .accessibilityLabel("\(eventTitle), code \(friendlyCode), at \(record.occurredAt.formatted(date: .omitted, time: .shortened))")
  }

  // MARK: - Presentation Helpers

  private var eventTitle: String {
    switch record.event {
    case .sendFailed:
      return "Send Failed"
    case .sendRecovered:
      return "Send Recovered"
    case .streamPaused:
      return "Stream Paused"
    case .streamResumed:
      return "Stream Resumed"
    case .rejoinWaiting:
      return "Rejoin Waiting"
    case .conversationLoadFailed:
      return "Load Failed"
    case .decryptRefused:
      return "Decryption Refused"
    }
  }

  private var eventColor: Color {
    switch record.event {
    case .sendFailed, .conversationLoadFailed, .decryptRefused:
      return .red
    case .streamPaused, .rejoinWaiting:
      return .orange
    case .sendRecovered, .streamResumed:
      return .green
    }
  }

  @ViewBuilder
  private var eventIcon: some View {
    switch record.event {
    case .sendFailed:
      Image(systemName: "exclamationmark.circle.fill")
        .foregroundStyle(.red)
    case .sendRecovered:
      Image(systemName: "checkmark.circle.fill")
        .foregroundStyle(.green)
    case .streamPaused:
      Image(systemName: "pause.circle.fill")
        .foregroundStyle(.orange)
    case .streamResumed:
      Image(systemName: "play.circle.fill")
        .foregroundStyle(.green)
    case .rejoinWaiting:
      Image(systemName: "clock.arrow.circlepath")
        .foregroundStyle(.orange)
    case .conversationLoadFailed:
      Image(systemName: "xmark.octagon.fill")
        .foregroundStyle(.red)
    case .decryptRefused:
      Image(systemName: "lock.slash.fill")
        .foregroundStyle(.red)
    }
  }

  private var friendlyCode: String {
    // Show non-engineer-friendly translation if recognized, with original code
    switch record.code {
    case "400 StaleCoordinates", "StaleCoordinates":
      return "Stale Coordinates (outdated group state)"
    case "429 RateLimited", "RateLimited":
      return "Rate Limited (gateway busy)"
    case "502 UpstreamTimeout", "502":
      return "Gateway Timeout (502)"
    case "RecipientNotReady":
      return "Recipient Not Ready (peer device key missing)"
    case "ConversationAlreadyExists":
      return "Conversation Already Exists"
    case "SecretReuse":
      return "Secret Reuse (stream desync)"
    case "GenerationMismatch":
      return "Generation Mismatch (sequence collision)"
    default:
      return record.code
    }
  }

  private struct MetadataTag {
    let label: String
    let value: String
  }

  private var metadataTags: [MetadataTag] {
    var tags: [MetadataTag] = []

    if let convo = record.conversationIDPrefix, !convo.isEmpty {
      tags.append(MetadataTag(label: "convo", value: String(convo.prefix(8))))
    }
    if let epoch = record.epoch {
      tags.append(MetadataTag(label: "epoch", value: "\(epoch)"))
    }
    if let gen = record.generation {
      tags.append(MetadataTag(label: "gen", value: "\(gen)"))
    }
    if let sv = record.stateVersion {
      tags.append(MetadataTag(label: "stateVer", value: "\(sv)"))
    }
    if let attempt = record.attempt {
      tags.append(MetadataTag(label: "attempt", value: "#\(attempt)"))
    }
    if let retry = record.retryAfter, retry > 0 {
      tags.append(MetadataTag(label: "retryIn", value: String(format: "%.1fs", retry)))
    }

    return tags
  }
}

