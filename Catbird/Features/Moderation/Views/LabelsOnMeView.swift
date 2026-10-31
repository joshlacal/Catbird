import SwiftUI
import Petrel

/// Shared inspector for labels on owned and other subjects. Appeals require ownership.
struct LabelsOnMeView: View {
  @Environment(\.dismiss) private var dismiss
  @Environment(AppState.self) private var appState

  let labels: [ComAtprotoLabelDefs.Label]
  let targetDescription: String
  let viewerDID: String
  let reportingService: ReportingService
  /// Inject published definitions for previews/fixtures; nil loads from the current client.
  var labelers: [AppBskyLabelerDefs.LabelerViewDetailed]? = nil

  @State private var loadedLabelers: [String: AppBskyLabelerDefs.LabelerViewDetailed] = [:]
  @State private var metadataError: String?
  @State private var appealingLabel: ComAtprotoLabelDefs.Label?
  @State private var appealDetails = ""
  @State private var submission = LabelAppealSubmission()
  @State private var showingSuccessAlert = false

  private var isCurrentViewer: Bool {
    AppStateManager.shared.lifecycle.appState === appState && appState.userDID == viewerDID
      && !AppStateManager.shared.authentication.isSwitchingAccount
  }

  private var activeLabels: [ComAtprotoLabelDefs.Label] {
    var seen = Set<String>()
    return labels.filter { ReportingService.isLabelActive($0) && seen.insert($0.id).inserted }
  }

  private func presentation(for label: ComAtprotoLabelDefs.Label) -> AccountLabelPresentation {
    let labeler = labelers?.first { $0.creator.did == label.src } ?? loadedLabelers[label.src.didString()]
    return AccountLabelPresentation(label: label, labeler: labeler)
  }

  var body: some View {
    NavigationStack {
      List {
        Section {
          VStack(alignment: .leading, spacing: 4) {
            Text("Labels Applied To").font(.caption).foregroundStyle(.secondary)
            Text(targetDescription).font(.headline)
          }
        }
        if let metadataError {
          Section {
            Text(metadataError).font(.caption).foregroundStyle(.secondary)
            Button("Retry Label Details") { Task { await loadMetadata() } }
          }
        }
        if activeLabels.isEmpty {
          Section {
            ContentUnavailableView("No Active Labels", systemImage: "tag", description: Text("There are no active labels to show."))
          }
        } else {
          Section("Active Labels (\(activeLabels.count))") {
            ForEach(activeLabels) { label in labelRow(for: label) }
          }
        }
      }
      .navigationTitle("Applied Labels")
      .toolbar {
        ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
      }
      .task { await loadMetadata() }
      .sheet(item: $appealingLabel, onDismiss: cancelSubmission) { label in appealSheet(for: label) }
      .alert("Appeal Submitted", isPresented: $showingSuccessAlert) { Button("OK", role: .cancel) { } } message: {
        Text("Your appeal was sent to the service that issued this label.")
      }
      .onChange(of: submission.successCount) { _, _ in
        guard isCurrentViewer else { return }
        appealingLabel = nil
        showingSuccessAlert = true
      }
      .onChange(of: isCurrentViewer) { _, isCurrent in
        if !isCurrent { cancelSubmission(); dismiss() }
      }
      .onDisappear { cancelSubmission() }
    }
  }

  private func labelRow(for label: ComAtprotoLabelDefs.Label) -> some View {
    let info = presentation(for: label)
    return VStack(alignment: .leading, spacing: 8) {
      Label(info.name, systemImage: info.severity == .warning ? "exclamationmark.triangle" : "info.circle")
        .font(.headline)
        .foregroundStyle(info.severity == .warning ? Color.orange : Color.primary)
      if let description = info.description, !description.isEmpty {
        Text(description).font(.subheadline).fixedSize(horizontal: false, vertical: true)
      }
      Text(info.attribution).font(.caption).foregroundStyle(.secondary)
        .textSelection(.enabled)
      if info.severity == .information {
        Text("Informational label").font(.caption).foregroundStyle(.secondary)
      }
      Text(label.subjectSummary).font(.caption).foregroundStyle(.secondary)
      Text("Applied \(label.cts.date, style: .date)").font(.caption).foregroundStyle(.secondary)
      if let expiration = label.exp?.date {
        Text("Expires \(expiration, style: .date)").font(.caption).foregroundStyle(.secondary)
      }
      if label.src.didString() == ReportingService.subjectOwnerDID(label) {
        Text("Self-applied").font(.caption).foregroundStyle(.secondary)
      } else if ReportingService.canAppeal(label, viewerDID: viewerDID), isCurrentViewer {
        Button("Appeal Label") { beginAppeal(label) }.buttonStyle(.bordered)
      }
    }
    .padding(.vertical, 6)
  }

  private func appealSheet(for label: ComAtprotoLabelDefs.Label) -> some View {
    let presentedLabelBinding = $appealingLabel
    return AppealLabelSheet(
      label: label,
      info: presentation(for: label),
      presentedLabel: presentedLabelBinding,
      appealDetails: $appealDetails,
      submission: submission,
      isCurrentViewer: { self.isCurrentViewer },
      onSubmit: { reason in self.startSubmission(label, reason: reason, presentation: presentedLabelBinding) },
      onCancel: {
        guard presentedLabelBinding.wrappedValue?.id == label.id else { return }
        self.cancelSubmission()
        presentedLabelBinding.wrappedValue = nil
      }
    )
  }

  private func beginAppeal(_ label: ComAtprotoLabelDefs.Label) {
    guard isCurrentViewer, ReportingService.canAppeal(label, viewerDID: viewerDID) else { return }
    appealDetails = ""
    submission.reset()
    appealingLabel = label
  }

  private func cancelSubmission() { submission.cancel() }

  private func startSubmission(_ label: ComAtprotoLabelDefs.Label, reason: String, presentation: Binding<ComAtprotoLabelDefs.Label?>) {
    guard isCurrentViewer, presentation.wrappedValue?.id == label.id else { return }
    submission.submit {
      guard isCurrentViewer, presentation.wrappedValue?.id == label.id else { throw LabelAppealError.accountChanged }
      return try await reportingService.submitAppeal(label: label, viewerDID: viewerDID, details: reason)
    }
  }

  private func loadMetadata() async {
    guard labelers == nil, isCurrentViewer, let client = appState.atProtoClient else { return }
    metadataError = nil
    do {
      let issuers = Array(Set(activeLabels.map(\.src)))
      var loaded: [String: AppBskyLabelerDefs.LabelerViewDetailed] = [:]
      for start in stride(from: 0, to: issuers.count, by: 20) {
        let batch = Array(issuers[start..<min(start + 20, issuers.count)])
        let (status, output) = try await client.app.bsky.labeler.getServices(input: .init(dids: batch, detailed: true))
        guard !Task.isCancelled, isCurrentViewer else { return }
        guard status == 200, let output else { throw URLError(.badServerResponse) }
        for view in output.views {
          if case .appBskyLabelerDefsLabelerViewDetailed(let labeler) = view { loaded[labeler.creator.did.didString()] = labeler }
        }
      }
      loadedLabelers = loaded
    } catch is CancellationError {
      return
    } catch {
      guard isCurrentViewer else { return }
      metadataError = "Label names could not be loaded. Label identifiers and issuing services are shown below."
    }
  }
}

/// The presented form owns its focus scope; the inspector retains reason and attempt state.
private struct AppealLabelSheet: View {
  let label: ComAtprotoLabelDefs.Label
  let info: AccountLabelPresentation
  @Binding var presentedLabel: ComAtprotoLabelDefs.Label?
  @Binding var appealDetails: String
  let submission: LabelAppealSubmission
  let isCurrentViewer: @MainActor () -> Bool
  let onSubmit: @MainActor (String) -> Void
  let onCancel: @MainActor () -> Void

  @FocusState private var isAppealReasonFocused: Bool

  var body: some View {
    NavigationStack {
      ScrollViewReader { scroll in
        Form {
          Section("Label Details") {
            Text(info.name).font(.headline)
            Text("Issued by \(info.issuer)").font(.subheadline)
            Text("Applies to: \(label.subjectSummary.lowercased())").font(.caption)
          }
          Section {
            TextField("Explain why this label was applied in error", text: $appealDetails, axis: .vertical)
              .lineLimit(4...8)
              .focused($isAppealReasonFocused)
              .accessibilityIdentifier("appealReason")
            Text("\(appealDetails.count)/300 characters").font(.caption).foregroundStyle(.secondary)
          } header: { Text("Reason for Appeal") } footer: {
            Text("Your appeal will be sent to the service that issued this label.")
          }
          Section {
            if let errorMessage = submission.errorMessage {
              Text(errorMessage).foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("appealSubmissionError")
            }
            Button {
              guard isCurrentPresentation else { return }
              isAppealReasonFocused = false
              onSubmit(appealDetails)
            } label: {
              HStack {
                if submission.isSubmitting { ProgressView() }
                Text(appealSubmissionTitle)
              }
              .frame(maxWidth: .infinity)
            }
            .accessibilityIdentifier("appealSubmit")
            .disabled(submission.isSubmitting || appealDetails.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
              || appealDetails.count > 300 || !isCurrentPresentation)
          }
          .id("appealSubmission")
        }
        .onChange(of: submission.errorMessage) { _, errorMessage in
          guard errorMessage != nil, isCurrentPresentation else { return }
          isAppealReasonFocused = false
          withAnimation { scroll.scrollTo("appealSubmission", anchor: .bottom) }
        }
      }
      .navigationTitle("Appeal Label")
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") {
            isAppealReasonFocused = false
            onCancel()
          }
        }
      }
    }
  }

  private var isCurrentPresentation: Bool {
    isCurrentViewer() && presentedLabel?.id == label.id
  }

  private var appealSubmissionTitle: LocalizedStringKey {
    if submission.isSubmitting { return "Submitting…" }
    return submission.errorMessage == nil ? "Submit Appeal" : "Retry Appeal"
  }
}

private extension ComAtprotoLabelDefs.Label {
  /// What the label is attached to, in plain words.
  var subjectSummary: String {
    let subjectURI = uri.uriString()
    if subjectURI.hasSuffix("/app.bsky.actor.profile/self") { return "Profile" }
    if cid == nil { return "Whole account" }
    if subjectURI.contains("/app.bsky.feed.post/") { return "Post" }
    return "Content"
  }
}

extension ComAtprotoLabelDefs.Label: @retroactive Identifiable {
  public var id: String { "\(src.didString())-\(uri.uriString())-\(val)-\(cid?.description ?? "none")" }
}
