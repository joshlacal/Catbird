import SwiftUI

@available(iOS 18.0, macOS 13.0, *)
struct OpenSourceLicensesView: View {
  var body: some View {
    ResponsiveContentView {
      List {
        Section {
          Text("Catbird is built with these open source packages. Thank you to their maintainers and contributors.")
            .appBody()
            .foregroundStyle(.secondary)
        }

        Section("Packages") {
          ForEach(OpenSourceLicenseCatalog.all) { package in
            NavigationLink {
              OpenSourceLicenseDetailView(package: package)
            } label: {
              LicenseRow(package: package)
            }
          }
        }
      }
    }
    .navigationTitle("Open Source Licenses")
    #if os(iOS)
    .toolbarTitleDisplayMode(.inline)
    #endif
  }
}

private struct LicenseRow: View {
  let package: OpenSourceLicense

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack {
        Text(package.name)
          .appHeadline()

        Spacer()

        Text(package.license)
          .appCaption()
          .padding(.horizontal, 8)
          .padding(.vertical, 2)
          .background(.secondary.opacity(0.1))
          .clipShape(Capsule())
      }

      HStack {
        Text(package.author)
          .appSubheadline()
          .foregroundStyle(.secondary)

        Spacer()

        if let version = package.version {
          Text("Version \(version)")
            .appCaption()
            .foregroundStyle(.secondary)
        }
      }
    }
    .padding(.vertical, 2)
    .accessibilityElement(children: .combine)
  }
}

private struct OpenSourceLicenseDetailView: View {
  let package: OpenSourceLicense

  var body: some View {
    List {
      Section {
        LabeledContent("License", value: package.license)
        if let version = package.version {
          LabeledContent("Version", value: version)
        }
        Link("View Project Website", destination: package.url)
      }

      Section("License Text") {
        Text(package.text)
          .appFont(AppTextRole.footnote)
          .textSelection(.enabled)
      }
    }
    .navigationTitle(package.name)
    #if os(iOS)
    .toolbarTitleDisplayMode(.inline)
    #endif
  }
}

#Preview {
  AsyncPreviewContent { appState in
    NavigationStack {
      OpenSourceLicensesView()
    }
  }
}
