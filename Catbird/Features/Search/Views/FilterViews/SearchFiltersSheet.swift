import SwiftUI

/// Structured sheet for the API-supported post search filters (G02).
public struct SearchFiltersSheet: View {
  @Environment(\.dismiss) private var dismiss

  public let initialState: SearchFilterState
  public let onApply: (SearchFilterState) -> Void
  @State private var draft: SearchFilterState

  public init(initialState: SearchFilterState, onApply: @escaping (SearchFilterState) -> Void) {
    self.initialState = initialState
    self.onApply = onApply
    _draft = State(initialValue: initialState)
  }

  private var sortedLanguages: [LanguageOption] {
    LanguageOption.supportedLanguages.sorted {
      if $0.isPreferred != $1.isPreferred { return $0.isPreferred }
      return $0.name < $1.name
    }
  }

  public var body: some View {
    NavigationStack {
      Form {
        // MARK: - Authors & Mentions
        Section("People & Accounts") {
          VStack(alignment: .leading, spacing: 4) {
            TextField("Author (handle or DID)", text: Binding(
              get: { draft.author ?? "" },
              set: { draft.author = $0.isEmpty ? nil : $0 }
            ))
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)

            if let error = draft.authorValidationError {
              Text(error)
                .appFont(AppTextRole.caption2)
                .foregroundStyle(.red)
            }
          }

          VStack(alignment: .leading, spacing: 4) {
            TextField("Mentions (handle or DID)", text: Binding(
              get: { draft.mentions ?? "" },
              set: { draft.mentions = $0.isEmpty ? nil : $0 }
            ))
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)

            if let error = draft.mentionsValidationError {
              Text(error)
                .appFont(AppTextRole.caption2)
                .foregroundStyle(.red)
            }
          }

          VStack(alignment: .leading, spacing: 4) {
            TextField("Exclude Author", text: Binding(
              get: { draft.excludeAuthor ?? "" },
              set: { draft.excludeAuthor = $0.isEmpty ? nil : $0 }
            ))
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)

            if let error = draft.excludeAuthorValidationError {
              Text(error)
                .appFont(AppTextRole.caption2)
                .foregroundStyle(.red)
            }
          }

          VStack(alignment: .leading, spacing: 4) {
            TextField("Exclude Mentions", text: Binding(
              get: { draft.excludeMentions ?? "" },
              set: { draft.excludeMentions = $0.isEmpty ? nil : $0 }
            ))
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)

            if let error = draft.excludeMentionsValidationError {
              Text(error)
                .appFont(AppTextRole.caption2)
                .foregroundStyle(.red)
            }
          }
        }

        // MARK: - Domain & Links
        Section("Domain & Links") {
          VStack(alignment: .leading, spacing: 4) {
            TextField("Domain (e.g. nytimes.com)", text: Binding(
              get: { draft.domain ?? "" },
              set: { draft.domain = $0.isEmpty ? nil : $0 }
            ))
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)

            if let error = draft.domainValidationError {
              Text(error)
                .appFont(AppTextRole.caption2)
                .foregroundStyle(.red)
            }
          }

          VStack(alignment: .leading, spacing: 4) {
            TextField("Exact URL (e.g. https://...)", text: Binding(
              get: { draft.url ?? "" },
              set: { draft.url = $0.isEmpty ? nil : $0 }
            ))
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)

            if let error = draft.urlValidationError {
              Text(error)
                .appFont(AppTextRole.caption2)
                .foregroundStyle(.red)
            }
          }

          VStack(alignment: .leading, spacing: 4) {
            TextField("Exclude Domain", text: Binding(
              get: { draft.excludeDomain ?? "" },
              set: { draft.excludeDomain = $0.isEmpty ? nil : $0 }
            ))
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)

            if let error = draft.excludeDomainValidationError {
              Text(error)
                .appFont(AppTextRole.caption2)
                .foregroundStyle(.red)
            }
          }

          VStack(alignment: .leading, spacing: 4) {
            TextField("Exclude URL", text: Binding(
              get: { draft.excludeURL ?? "" },
              set: { draft.excludeURL = $0.isEmpty ? nil : $0 }
            ))
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)

            if let error = draft.excludeURLValidationError {
              Text(error)
                .appFont(AppTextRole.caption2)
                .foregroundStyle(.red)
            }
          }
        }

        // MARK: - Hashtags
        Section("Hashtags") {
          TextField("Hashtag (e.g. swift)", text: Binding(
            get: { draft.hashtag ?? "" },
            set: { draft.hashtag = $0.isEmpty ? nil : $0 }
          ))
          .autocorrectionDisabled()
          .textInputAutocapitalization(.never)

          TextField("Exclude Hashtag", text: Binding(
            get: { draft.excludeHashtag ?? "" },
            set: { draft.excludeHashtag = $0.isEmpty ? nil : $0 }
          ))
          .autocorrectionDisabled()
          .textInputAutocapitalization(.never)
        }

        // MARK: - Date Range
        Section("Date range") {
          Picker("Date range", selection: $draft.dateRange) {
            ForEach(SearchDateRange.allCases) { range in
              Text(range.displayName).tag(range)
            }
          }
          .onChange(of: draft.dateRange) { _, range in
            draft.selectDateRange(range)
          }

          if draft.dateRange == .custom {
            DatePicker("Start date", selection: Binding(
              get: { draft.customStartDate ?? Date() },
              set: { draft.customStartDate = $0 }
            ), displayedComponents: .date)
            DatePicker("End date", selection: Binding(
              get: { draft.customEndDate ?? Date() },
              set: { draft.customEndDate = $0 }
            ), displayedComponents: .date)
          }
        }

        // MARK: - Language
        Section("Language") {
          Picker("Language", selection: $draft.language) {
            Text("Any language").tag(String?.none)
            ForEach(sortedLanguages) { language in
              Text(language.name).tag(String?.some(language.code))
            }
          }
        }

        // MARK: - Replies
        Section("Replies") {
          Picker("Replies", selection: $draft.replyMode) {
            ForEach(SearchReplyMode.allCases) { mode in
              Text(mode.displayName).tag(mode)
            }
          }
        }

        // MARK: - Media & Audience
        Section("Content & Audience") {
          Toggle("Media only", isOn: $draft.hasMedia)
          Toggle("Video only", isOn: $draft.hasVideo)
          Toggle("From following only", isOn: $draft.following)
        }

        // MARK: - Reset
        Section {
          Button("Reset filters") {
            draft.reset()
          }
          .disabled(draft.activeFilterCount == 0)
          .frame(maxWidth: .infinity)
        }
      }
      .navigationTitle("Filters")
      #if os(iOS)
      .toolbarTitleDisplayMode(.inline)
      #endif
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") { dismiss() }
        }
        ToolbarItem(placement: .confirmationAction) {
          Button("Apply") {
            guard draft.isValid else { return }
            onApply(draft)
            dismiss()
          }
          .disabled(!draft.isValid)
        }
      }
    }
    #if os(iOS)
    .presentationDetents([.medium, .large])
    .presentationDragIndicator(.visible)
    #endif
  }
}
