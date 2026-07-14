import SwiftUI

/// One compact sheet for the API-supported post filters.
struct SearchFiltersSheet: View {
  @Environment(\.dismiss) private var dismiss

  let initialState: SearchFilterState
  let onApply: (SearchFilterState) -> Void
  @State private var draft: SearchFilterState

  init(initialState: SearchFilterState, onApply: @escaping (SearchFilterState) -> Void) {
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

  var body: some View {
    NavigationStack {
      Form {
        Section("Date range") {
          Picker("Date range", selection: $draft.dateRange) {
            ForEach(SearchDateRange.allCases) { range in
              Text(range.displayName).tag(range)
            }
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

        Section("Language") {
          Picker("Language", selection: $draft.language) {
            Text("Any language").tag(String?.none)
            ForEach(sortedLanguages) { language in
              Text(language.name).tag(String?.some(language.code))
            }
          }
        }

        Section {
          Button("Reset filters") {
            draft.dateRange = .anytime
            draft.customStartDate = nil
            draft.customEndDate = nil
            draft.language = nil
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
            onApply(draft)
            dismiss()
          }
        }
      }
    }
    #if os(iOS)
    .presentationDetents([.medium, .large])
    .presentationDragIndicator(.visible)
    #endif
  }
}
