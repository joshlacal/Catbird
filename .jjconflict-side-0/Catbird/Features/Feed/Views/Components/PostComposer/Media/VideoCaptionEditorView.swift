//
//  VideoCaptionEditorView.swift
//  Catbird
//
//  Created by Josh LaCalamito on 8/24/26.
//

import Foundation
import Petrel
import SwiftUI
import UniformTypeIdentifiers

/// Sheet for importing, validating, previewing, and attaching a WebVTT caption file to a video.
public struct VideoCaptionEditorView: View {
  @Environment(\.dismiss) private var dismiss

  public let initialCaption: VideoCaption?
  public let onSave: (VideoCaption) -> Void
  public let onRemove: () -> Void

  @State private var selectedLanguage: LanguageCodeContainer
  @State private var filename: String = ""
  @State private var vttContent: String = ""
  @State private var byteCount: Int = 0
  @State private var characterCount: Int = 0
  @State private var showingFileImporter: Bool = false
  @State private var errorMessage: String? = nil

  private let availableLanguages: [LanguageCodeContainer]

  public init(
    caption: VideoCaption?,
    initialLanguage: LanguageCodeContainer? = nil,
    onSave: @escaping (VideoCaption) -> Void,
    onRemove: @escaping () -> Void
  ) {
    self.initialCaption = caption
    self.onSave = onSave
    self.onRemove = onRemove
    self.availableLanguages = getAvailableLanguages()

    let defaultLang: LanguageCodeContainer
    if let captionLang = caption?.lang {
      defaultLang = captionLang
    } else if let initialLang = initialLanguage {
      defaultLang = initialLang
    } else {
      let code = Locale.current.language.languageCode?.identifier ?? "en"
      defaultLang = LanguageCodeContainer(languageCode: code)
    }

    self._selectedLanguage = State(initialValue: defaultLang)
    self._filename = State(initialValue: caption?.filename ?? "")
    self._vttContent = State(initialValue: caption?.content ?? "")
    let count = caption?.content.count ?? 0
    let bytes = caption?.content.utf8.count ?? 0
    self._characterCount = State(initialValue: count)
    self._byteCount = State(initialValue: bytes)
  }

  private var hasFile: Bool {
    !vttContent.isEmpty && !filename.isEmpty
  }

  public var body: some View {
    NavigationStack {
      Form {
        // MARK: - Language Section
        Section(header: Text("Caption Language")) {
          Picker("Language", selection: $selectedLanguage) {
            ForEach(availableLanguages, id: \.self) { lang in
              let langCode = lang.lang.languageCode?.identifier ?? lang.lang.minimalIdentifier
              let localized = Locale.current.localizedString(forLanguageCode: langCode) ?? lang.lang.minimalIdentifier
              Text("\(localized) (\(lang.lang.minimalIdentifier))")
                .tag(lang)
            }
          }
          .pickerStyle(.menu)
        }

        // MARK: - File Attachment Section
        Section(header: Text("WebVTT File (.vtt)")) {
          if hasFile {
            VStack(alignment: .leading, spacing: 6) {
              HStack {
                Image(systemName: "doc.text.fill")
                  .foregroundStyle(.tint)
                Text(filename)
                  .font(.subheadline)
                  .fontWeight(.medium)
                  .lineLimit(1)
                  .truncationMode(.middle)
              }

              HStack(spacing: 12) {
                Text("\(byteCount) bytes / \(VideoCaption.maxByteSize) max")
                  .font(.caption)
                  .foregroundStyle(byteCount > VideoCaption.maxByteSize ? .red : .secondary)

                Text("\(characterCount) chars")
                  .font(.caption)
                  .foregroundStyle(characterCount > VideoCaption.maxCharacterLength ? .red : .secondary)
              }

              if !vttContent.isEmpty {
                DisclosureGroup("Preview Content") {
                  ScrollView {
                    Text(vttContent.prefix(500) + (vttContent.count > 500 ? "\n…" : ""))
                      .font(.system(.caption, design: .monospaced))
                      .frame(maxWidth: .infinity, alignment: .leading)
                      .padding(8)
                      .background(Color(platformColor: .platformSystemGray6))
                      .cornerRadius(8)
                  }
                  .frame(maxHeight: 120)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
              }
            }
            .padding(.vertical, 4)

            Button(role: nil) {
              showingFileImporter = true
            } label: {
              Label("Replace .vtt File", systemImage: "arrow.triangle.2.circlepath")
            }
          } else {
            Button {
              showingFileImporter = true
            } label: {
              Label("Import .vtt File", systemImage: "plus.circle")
            }
          }
        }

        // MARK: - Error Message Section
        if let error = errorMessage {
          Section {
            HStack(spacing: 8) {
              Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
              Text(error)
                .font(.caption)
                .foregroundStyle(.red)
            }
          }
        }

        // MARK: - Remove Caption Section
        if initialCaption != nil || hasFile {
          Section {
            Button(role: .destructive) {
              onRemove()
              dismiss()
            } label: {
              Label("Remove Captions", systemImage: "trash")
                .foregroundStyle(.red)
            }
          }
        }
      }
      .navigationTitle("Video Captions")
      #if os(iOS)
      .navigationBarTitleDisplayMode(.inline)
      #endif
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") {
            dismiss()
          }
        }
        ToolbarItem(placement: .confirmationAction) {
          Button("Done") {
            saveCaption()
          }
          .disabled(!hasFile)
        }
      }
      .fileImporter(
        isPresented: $showingFileImporter,
        allowedContentTypes: [
          UTType(filenameExtension: "vtt") ?? .plainText,
          UTType.plainText,
          UTType.text,
          UTType.item
        ],
        allowsMultipleSelection: false
      ) { result in
        handleFileImport(result)
      }
    }
  }

  private func handleFileImport(_ result: Result<[URL], Error>) {
    errorMessage = nil
    switch result {
    case .success(let urls):
      guard let url = urls.first else { return }
      let accessed = url.startAccessingSecurityScopedResource()
      defer {
        if accessed {
          url.stopAccessingSecurityScopedResource()
        }
      }

      do {
        let data = try Data(contentsOf: url)
        guard let text = String(data: data, encoding: .utf8) else {
          throw VideoCaption.ValidationError.invalidEncoding
        }

        guard VideoCaption.isValidWebVTTHeader(text) else {
          throw VideoCaption.ValidationError.invalidHeader
        }

        guard data.count <= VideoCaption.maxByteSize else {
          throw VideoCaption.ValidationError.exceedsByteLimit(actualBytes: data.count)
        }

        guard text.count <= VideoCaption.maxCharacterLength else {
          throw VideoCaption.ValidationError.exceedsCharacterLimit(actualCharacters: text.count)
        }

        self.filename = url.lastPathComponent
        self.vttContent = text
        self.byteCount = data.count
        self.characterCount = text.count
        self.errorMessage = nil
      } catch {
        self.errorMessage = error.localizedDescription
      }

    case .failure(let error):
      self.errorMessage = error.localizedDescription
    }
  }

  private func saveCaption() {
    errorMessage = nil
    do {
      let caption = try VideoCaption.validate(
        content: vttContent,
        filename: filename,
        lang: selectedLanguage
      )
      onSave(caption)
      dismiss()
    } catch {
      self.errorMessage = error.localizedDescription
    }
  }
}
