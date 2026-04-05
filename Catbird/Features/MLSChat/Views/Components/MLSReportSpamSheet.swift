import CatbirdMLSCore
//
//  MLSReportSpamSheet.swift
//  Catbird
//
//  Simple spam report sheet for MLS conversations
//

import SwiftUI
import Petrel
import OSLog

@Observable
final class MLSReportSpamViewModel {
  // MARK: - Properties

  private(set) var isSubmitting = false
  private(set) var didSucceed = false
  private(set) var errorMessage: String?

  let conversationId: String
  let reportedDid: String
  let reportedDisplayName: String

  // MARK: - Dependencies

  private let apiClient: MLSAPIClient
  private let logger = Logger(subsystem: "blue.catbird", category: "MLSReportSpam")

  // MARK: - Initialization

  init(
    conversationId: String,
    reportedDid: String,
    reportedDisplayName: String,
    apiClient: MLSAPIClient
  ) {
    self.conversationId = conversationId
    self.reportedDid = reportedDid
    self.reportedDisplayName = reportedDisplayName
    self.apiClient = apiClient
  }

  // MARK: - Actions

  @MainActor
  func submitReport(reason: String?) async {
    guard !isSubmitting else { return }

    isSubmitting = true
    errorMessage = nil

    do {
      let did = try DID(didString: reportedDid)
      let input = BlueCatbirdMlsChatReportSpam.Input(
        convoId: conversationId,
        reportedDid: did,
        reason: reason?.isEmpty == true ? nil : reason
      )

      let (responseCode, _) = try await apiClient.client.blue.catbird.mlschat.reportSpam(
        input: input
      )

      guard (200...299).contains(responseCode) else {
        logger.error("Report spam failed with HTTP \(responseCode)")
        errorMessage = "Failed to submit report. Please try again."
        isSubmitting = false
        return
      }

      logger.info("Successfully reported spam for \(self.reportedDid) in convo \(self.conversationId)")
      didSucceed = true
    } catch {
      logger.error("Report spam error: \(error.localizedDescription)")
      errorMessage = "Failed to submit report. Please try again."
    }

    isSubmitting = false
  }
}

struct MLSReportSpamSheet: View {
  // MARK: - Dependencies

  let conversationId: String
  let reportedDid: String
  let reportedDisplayName: String
  let apiClient: MLSAPIClient

  @Environment(\.dismiss) private var dismiss

  // MARK: - State

  @State private var viewModel: MLSReportSpamViewModel?
  @State private var reason = ""

  private let reasonCharacterLimit = 1000

  // MARK: - Body

  var body: some View {
    NavigationStack {
      Form {
        Section {
          HStack(spacing: 12) {
            Circle()
              .fill(Color.red.gradient)
              .frame(width: 44, height: 44)
              .overlay {
                Image(systemName: "exclamationmark.bubble.fill")
                  .foregroundStyle(.white)
              }

            VStack(alignment: .leading, spacing: 2) {
              Text("Report as Spam")
                .font(.headline)
              Text(reportedDisplayName)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }
          }
          .padding(.vertical, 4)
        }

        Section {
          ZStack(alignment: .topLeading) {
            if reason.isEmpty {
              Text("Why are you reporting this account? (optional)")
                .foregroundStyle(.tertiary)
                .padding(.top, 8)
                .padding(.leading, 4)
            }

            TextEditor(text: $reason)
              .frame(minHeight: 100)
              .onChange(of: reason) { _, newValue in
                if newValue.count > reasonCharacterLimit {
                  reason = String(newValue.prefix(reasonCharacterLimit))
                }
              }
          }

          HStack {
            Spacer()
            Text("\(reason.count)/\(reasonCharacterLimit)")
              .font(.caption)
              .foregroundStyle(
                reason.count >= reasonCharacterLimit ? .red : .secondary
              )
          }
        } header: {
          Text("Reason")
        }

        if let errorMessage = viewModel?.errorMessage {
          Section {
            Label(errorMessage, systemImage: "exclamationmark.triangle")
              .foregroundStyle(.red)
              .font(.callout)
          }
        }
      }
      .navigationTitle("Report as Spam")
      #if os(iOS)
      .navigationBarTitleDisplayMode(.inline)
      #endif
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") {
            dismiss()
          }
          .disabled(viewModel?.isSubmitting == true)
        }

        ToolbarItem(placement: .confirmationAction) {
          Button("Report") {
            Task {
              await submitReport()
            }
          }
          .fontWeight(.semibold)
          .disabled(viewModel?.isSubmitting == true)
        }
      }
      .disabled(viewModel?.isSubmitting == true)
      .overlay {
        if viewModel?.isSubmitting == true {
          ZStack {
            Color.black.opacity(0.3)
              .ignoresSafeArea()

            VStack(spacing: 16) {
              ProgressView()
                .tint(.white)
              Text("Submitting...")
                .font(.subheadline)
                .foregroundStyle(.white)
            }
            .padding(24)
            .background(Color.black.opacity(0.7))
            .clipShape(RoundedRectangle(cornerRadius: 16))
          }
        }
      }
      .alert("Report Submitted", isPresented: successBinding) {
        Button("OK") {
          dismiss()
        }
      } message: {
        Text("Thank you for your report. We will review it and take appropriate action.")
      }
      .onAppear {
        if viewModel == nil {
          viewModel = MLSReportSpamViewModel(
            conversationId: conversationId,
            reportedDid: reportedDid,
            reportedDisplayName: reportedDisplayName,
            apiClient: apiClient
          )
        }
      }
    }
  }

  // MARK: - Helpers

  private var successBinding: Binding<Bool> {
    Binding(
      get: { viewModel?.didSucceed == true },
      set: { _ in }
    )
  }

  @MainActor
  private func submitReport() async {
    if viewModel == nil {
      viewModel = MLSReportSpamViewModel(
        conversationId: conversationId,
        reportedDid: reportedDid,
        reportedDisplayName: reportedDisplayName,
        apiClient: apiClient
      )
    }
    await viewModel?.submitReport(reason: reason)
  }
}
