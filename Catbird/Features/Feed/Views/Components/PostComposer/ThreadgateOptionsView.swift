import Petrel
import SwiftUI

struct ThreadgateOptionsView: View {
  @Binding var settings: ThreadgateSettings
  @Environment(\.dismiss) private var dismiss
  @ObservationIgnored @Environment(AppState.self) private var appState

  // For UI state
  @State private var selectedOption: ThreadgateSettings.ReplyOption
  @State private var combinedOptions: [ThreadgateSettings.ReplyOption] = []
  @State private var userLists: [AppBskyGraphDefs.ListView] = []
  @State private var isLoadingLists = false

  // Initialize with current settings
  init(settings: Binding<ThreadgateSettings>) {
    self._settings = settings

    // Set initial selected option based on settings
    let initialOption = settings.wrappedValue.primaryOption
    _selectedOption = State(initialValue: initialOption)

    // Initialize combined options
    _combinedOptions = State(initialValue: settings.wrappedValue.enabledOptions)
  }

  var body: some View {
    NavigationStack {
      VStack(spacing: 0) {
        ScrollView {
          VStack(spacing: 16) {
            // Main options group
            VStack(spacing: 0) {
              Text("Allow replies from:")
                .appFont(AppTextRole.headline)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()

              // Everybody / Nobody options
              Group {
                Button(action: {
                  selectedOption = .everybody
                  combinedOptions = []
                  updateSettings()
                }) {
                  let isEverybodySelected = selectedOption == .everybody && combinedOptions.isEmpty
                  let backgroundSelected: Color = isEverybodySelected ? Color.accentColor.opacity(0.1) : Color.clear
                  
                  HStack {
                    Image(systemName: ThreadgateSettings.ReplyOption.everybody.iconName)
                      .frame(width: 24)

                    Text(ThreadgateSettings.ReplyOption.everybody.rawValue)
                      .foregroundColor(.primary)
                    Spacer()

                    if isEverybodySelected {
                      Image(systemName: "checkmark")
                        .foregroundColor(.accentColor)
                    }
                  }
                  .padding()
                  .background(backgroundSelected)
                  .contentShape(.rect)

                }
                .buttonStyle(PlainButtonStyle())

                Divider()
                  .padding(.horizontal)

                Button(action: {
                  selectedOption = .nobody
                  combinedOptions = []
                  updateSettings()
                }) {
                  let isNobodySelected = selectedOption == .nobody && combinedOptions.isEmpty
                  let backgroundSelected: Color = isNobodySelected ? Color.accentColor.opacity(0.1) : Color.clear
                  
                  HStack {
                    Image(systemName: ThreadgateSettings.ReplyOption.nobody.iconName)
                      .frame(width: 24)

                    Text(ThreadgateSettings.ReplyOption.nobody.rawValue)
                      .foregroundColor(.primary)
                    Spacer()

                    if isNobodySelected {
                      Image(systemName: "checkmark")
                        .foregroundColor(.accentColor)
                    }
                  }
                  .padding()
                  .background(backgroundSelected)
                  .contentShape(.rect)

                }
                .buttonStyle(PlainButtonStyle())
              }
            }

            Divider()
              .padding(.vertical)

            // Combined options
            VStack(spacing: 0) {
              Text("Or combine these options:")
                .appFont(AppTextRole.headline)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal)

              VStack(spacing: 0) {
                ForEach(
                  ThreadgateSettings.ReplyOption.allCases.filter {
                    $0 != .everybody && $0 != .nobody
                  }
                ) { option in
                  Button(action: {
                    toggleOption(option)
                  }) {
                    let isOptionSelected = combinedOptions.contains(option)
                    let backgroundSelected: Color = isOptionSelected ? Color.accentColor.opacity(0.1) : Color.clear
                    
                    HStack {
                      Image(systemName: option.iconName)
                        .frame(width: 24)

                      Text(option.rawValue)
                        .foregroundColor(.primary)
                      Spacer()

                      if isOptionSelected {
                        Image(systemName: "checkmark")
                          .foregroundColor(.accentColor)
                      }
                    }
                    .padding()
                    .background(backgroundSelected)
                    .contentShape(.rect)

                  }
                  .buttonStyle(PlainButtonStyle())

                  if option != ThreadgateSettings.ReplyOption.allCases.last {
                    Divider()
                      .padding(.horizontal)
                  }
                }
              }
              .background(Color(platformColor: .platformSecondarySystemBackground))
              .cornerRadius(12)
              .padding()
            }
            
            // Lists section
            VStack(spacing: 0) {
              HStack {
                Text("Members of lists:")
                  .appFont(AppTextRole.headline)
                Spacer()
                if isLoadingLists {
                  ProgressView()
                    .scaleEffect(0.8)
                }
              }
              .frame(maxWidth: .infinity, alignment: .leading)
              .padding(.horizontal)
              
              if userLists.isEmpty {
                Text("No lists available")
                  .font(.footnote)
                  .foregroundStyle(.secondary)
                  .padding()
              } else {
                VStack(spacing: 0) {
                  ForEach(userLists, id: \.uri) { list in
                    Button(action: {
                      toggleList(list)
                    }) {
                      let isListSelected = settings.selectedLists.contains(list.uri.uriString())
                      let backgroundSelected: Color = isListSelected ? Color.accentColor.opacity(0.1) : Color.clear
                      
                      HStack {
                        Image(systemName: "list.bullet")
                          .frame(width: 24)
                        
                        VStack(alignment: .leading, spacing: 2) {
                          Text(list.name)
                            .foregroundColor(.primary)
                          if let description = list.description, !description.isEmpty {
                            Text(description)
                              .font(.caption)
                              .foregroundStyle(.secondary)
                              .lineLimit(1)
                          }
                        }
                        
                        Spacer()
                        
                        if isListSelected {
                          Image(systemName: "checkmark")
                            .foregroundColor(.accentColor)
                        }
                      }
                      .padding()
                      .background(backgroundSelected)
                      .contentShape(.rect)
                    }
                    .buttonStyle(PlainButtonStyle())
                    
                    if list.uri != userLists.last?.uri {
                      Divider()
                        .padding(.horizontal)
                    }
                  }
                }
                .background(Color(platformColor: .platformSecondarySystemBackground))
                .cornerRadius(12)
                .padding()
              }
            }
          }
        }
      }
      .navigationTitle("Reply Settings")
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel", systemImage: "xmark") { dismiss() }
        }

        ToolbarItem(placement: .confirmationAction) {
            Button {
                updateSettings()

                dismiss()
            } label: {
                Image(systemName: "checkmark")
            }

        }
      }
      .task {
        await loadUserLists()
      }
    }
  }

  private func toggleOption(_ option: ThreadgateSettings.ReplyOption) {
    // If we're toggling a combined option
    if option != .everybody && option != .nobody {
      // Reset everybody/nobody selections
      if selectedOption == .everybody || selectedOption == .nobody {
        selectedOption = option
        combinedOptions = [option]
      } else {
        // Toggle this option in our combined options
        if combinedOptions.contains(option) {
          combinedOptions.removeAll { $0 == option }
        } else {
          combinedOptions.append(option)
        }

        // If we ended up with no options, default to everybody
        if combinedOptions.isEmpty && !settings.allowLists {
          selectedOption = .everybody
        }
      }

      updateSettings()
    }
  }
  
  private func toggleList(_ list: AppBskyGraphDefs.ListView) {
    let listURI = list.uri.uriString()
    
    // Toggle list selection
    settings.toggleList(listURI)
    
    // If we're selecting a list for the first time, exit everybody/nobody mode
    if settings.allowLists && (selectedOption == .everybody || selectedOption == .nobody) {
      selectedOption = .mentioned  // Default to mentioned when transitioning
      combinedOptions = []
    }
    
    updateSettings()
  }
  
  private func loadUserLists() async {
    
    isLoadingLists = true
    defer { isLoadingLists = false }
    
    userLists = appState.listManager.userLists
  }

  private func updateSettings() {
    // Reset all settings
    settings.allowEverybody = false
    settings.allowNobody = false
    settings.allowMentioned = false
    settings.allowFollowing = false
    settings.allowFollowers = false

    // Apply selected option if it's everybody/nobody
    if selectedOption == .everybody && combinedOptions.isEmpty && !settings.allowLists {
      settings.allowEverybody = true
    } else if selectedOption == .nobody && combinedOptions.isEmpty && !settings.allowLists {
      settings.allowNobody = true
    } else {
      // Apply all combined options
      for option in combinedOptions {
        switch option {
        case .mentioned:
          settings.allowMentioned = true
        case .following:
          settings.allowFollowing = true
        case .followers:
          settings.allowFollowers = true
        default:
          break
        }
      }

      // If somehow no options are selected (including lists), default to everybody
      if !settings.allowMentioned && !settings.allowFollowing && !settings.allowFollowers && !settings.allowLists {
        settings.allowEverybody = true
      }
    }
  }
}
