import SwiftUI
import UIKit

struct SearchBar: UIViewRepresentable {
  @Binding var text: String
  var placeholder: String

  class Coordinator: NSObject, UISearchBarDelegate {
    @Binding var text: String

    init(text: Binding<String>) {
      self._text = text
    }

    func searchBar(_ searchBar: UISearchBar, textDidChange searchText: String) {
      text = searchText
    }

    func searchBarSearchButtonClicked(_ searchBar: UISearchBar) {
      searchBar.resignFirstResponder()
    }
  }

  func makeCoordinator() -> Coordinator {
    return Coordinator(text: $text)
  }

  func makeUIView(context: Context) -> UISearchBar {
    let searchBar = UISearchBar(frame: .zero)
    searchBar.delegate = context.coordinator
    searchBar.placeholder = placeholder
    searchBar.searchBarStyle = .minimal
    searchBar.autocapitalizationType = .none
    searchBar.autocorrectionType = .no
    return searchBar
  }

  func updateUIView(_ uiView: UISearchBar, context: Context) {
    uiView.text = text
  }
}

// Preview provider
#Preview {
  SearchBar(text: .constant(""), placeholder: "Search feeds...")
    .padding()
}
