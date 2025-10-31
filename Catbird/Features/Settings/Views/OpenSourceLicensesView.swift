import SwiftUI

@available(iOS 18.0, macOS 13.0, *)
struct OpenSourceLicensesView: View {
  var body: some View {
    NavigationStack {
      ResponsiveContentView {
        List {
          Section {
            Text("Catbird is built with love using these amazing open source packages:")
              .appBody()
              .foregroundStyle(.secondary)
          }
          
          Section("Dependencies") {
            LicenseRow(
              name: "Chat",
              author: "exyte",
              version: "2.6.3",
              url: "https://github.com/exyte/Chat.git",
              license: "MIT"
            )
            
            LicenseRow(
              name: "FaultOrdering",
              author: "getsentry",
              version: "1.0.0",
              url: "https://github.com/getsentry/FaultOrdering",
              license: "MIT"
            )
            
            LicenseRow(
              name: "LazyPager",
              author: "gh123man",
              version: "1.1.7",
              url: "https://github.com/gh123man/LazyPager",
              license: "MIT"
            )

            LicenseRow(
              name: "Mantis",
              author: "guoyingtao",
              version: "2.24.0",
              url: "https://github.com/guoyingtao/Mantis",
              license: "MIT"
            )

            LicenseRow(
              name: "MCEmojiPicker",
              author: "izyumkin",
              version: "1.2.3",
              url: "https://github.com/izyumkin/MCEmojiPicker",
              license: "MIT"
            )
            
            LicenseRow(
              name: "Nuke",
              author: "kean",
              version: "12.8.0",
              url: "https://github.com/kean/Nuke.git",
              license: "MIT"
            )
            
            LicenseRow(
              name: "Petrel",
              author: "joshlacal",
              version: "1.0.0",
              url: "https://github.com/joshlacal/Petrel",
              license: "MIT"
            )
            
            LicenseRow(
              name: "swift-collections",
              author: "Apple",
              version: "1.1.4",
              url: "https://github.com/apple/swift-collections.git",
              license: "Apache 2.0"
            )
          }
          
          Section {
            Text("We're grateful to all the maintainers and contributors of these projects.")
              .appCaption()
              .foregroundStyle(.secondary)
          }
        }
      }
      .navigationTitle("Open Source Licenses")
      #if os(iOS)
      .toolbarTitleDisplayMode(.inline)
      #endif
    }
  }
}

private struct LicenseRow: View {
  let name: String
  let author: String
  let version: String
  let url: String?
  let license: String
  
  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack {
        Text(name)
          .appHeadline()
        
        Spacer()
        
        Text(license)
          .appCaption()
          .padding(.horizontal, 8)
          .padding(.vertical, 2)
          .background(.secondary.opacity(0.1))
          .clipShape(Capsule())
      }
      
      HStack {
        Text("by \(author)")
          .appSubheadline()
          .foregroundStyle(.secondary)
        
        Spacer()
        
        Text("v\(version)")
          .appCaption()
          .foregroundStyle(.secondary)
      }
      
      if let url = url {
        Link(url, destination: URL(string: url)!)
          .appCaption()
          .foregroundStyle(.blue)
      }
    }
    .padding(.vertical, 2)
  }
}

#Preview {
  OpenSourceLicensesView()
}