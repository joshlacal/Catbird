import SwiftUI
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
  SearchBar(text: .constant(""), placeholder: "Search feeds...")
    .padding()
}
