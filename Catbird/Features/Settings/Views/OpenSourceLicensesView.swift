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
              name: "LazyPager",
              author: "gh123man",
              version: "1.1.7",
              url: "https://github.com/gh123man/LazyPager",
              license: "MIT"
            )

            LicenseRow(
              name: "GRDB",
              author: "groue",
              version: "7.8.0",
              url: "https://github.com/groue/GRDB.swift.git",
              license: "MIT"
            )
            
            LicenseRow(
              name: "Mantis",
              author: "guoyingtao",
              version: "1.7.5",
              url: "https://github.com/guoyingtao/Mantis",
              license: "MIT"
            )

            LicenseRow(
              name: "EmojiKit",
              author: "Daniel Saidi",
              version: "2.2.1",
              url: "https://github.com/danielsaidi/EmojiKit",
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
              name: "OpenMLS",
              author: "OpenMLS",
              version: "0.6.0",
              url: "https://github.com/openmls/openmls",
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
              name: "Sentry",
              author: "getsentry",
              version: "8.56.1",
              url: "https://github.com/getsentry/sentry-cocoa",
              license: "MIT"
            )
            
            LicenseRow(
              name: "SQLCipher",
              author: "ZETETIC LLC",
              version: "4.11.0",
              url: "https://github.com/sqlcipher/SQLCipher.swift.git",
              license: "Community Edition"
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
    @Previewable @Environment(AppState.self) var appState
  OpenSourceLicensesView()
}
