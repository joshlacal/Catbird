import SwiftUI
#if os(iOS)
import UIKit

struct SearchBar: UIViewRepresentable {
  @Binding var text: String
  var placeholder: String
  var autoFocus: Bool = false

  class Coordinator: NSObject, UISearchBarDelegate {
    @Binding var text: String
    let autoFocus: Bool

    init(text: Binding<String>, autoFocus: Bool) {
      self._text = text
      self.autoFocus = autoFocus
    }

    func searchBar(_ searchBar: UISearchBar, textDidChange searchText: String) {
      text = searchText
    }

    func searchBarSearchButtonClicked(_ searchBar: UISearchBar) {
      searchBar.resignFirstResponder()
    }
  }

  func makeCoordinator() -> Coordinator {
    return Coordinator(text: $text, autoFocus: autoFocus)
  }

  func makeUIView(context: Context) -> UISearchBar {
    let searchBar = UISearchBar(frame: .zero)
    searchBar.delegate = context.coordinator
    searchBar.placeholder = placeholder
    searchBar.searchBarStyle = .minimal
    searchBar.autocapitalizationType = .none
    searchBar.autocorrectionType = .no

    // Add search icon
    searchBar.setImage(UIImage(systemName: "magnifyingglass"), for: .search, state: .normal)

    return searchBar
  }

  func updateUIView(_ uiView: UISearchBar, context: Context) {
    uiView.text = text

    // Auto focus if needed
    if context.coordinator.autoFocus && !uiView.isFirstResponder {
      DispatchQueue.main.async {
        uiView.becomeFirstResponder()
      }
    }
  }
}

// Preview provider
#Preview {
    @Previewable @Environment(AppState.self) var appState
  SearchBar(text: .constant(""), placeholder: "Search feeds...")
    .padding()
}

#else

// macOS stub - use native TextField with search styling
struct SearchBar: View {
  @Binding var text: String
  var placeholder: String
  var autoFocus: Bool = false
  
  var body: some View {
    HStack {
      Image(systemName: "magnifyingglass")
        .foregroundColor(.secondary)
      TextField(placeholder, text: $text)
        .textFieldStyle(.plain)
    }
    .padding(8)
    .background(Color(.controlBackgroundColor))
    .cornerRadius(8)
  }
}

#Preview {
    @Previewable @Environment(AppState.self) var appState
  SearchBar(text: .constant(""), placeholder: "Search feeds...")
    .padding()
}

#endif
