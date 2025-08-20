import SwiftUI

struct OutlineTagsView: View {
  @Binding var tags: [String]
  @State private var newTag: String = ""
  @State private var isAddingTag: Bool = false
  @FocusState private var isTextFieldFocused: Bool
  
  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Text("Tags")
          .font(.headline)
          .foregroundColor(.primary)
        
        Spacer()
        
        Button(action: {
          isAddingTag = true
          isTextFieldFocused = true
        }) {
          Image(systemName: "plus.circle.fill")
            .foregroundColor(.blue)
            .font(.title2)
        }
      }
      
      if !tags.isEmpty || isAddingTag {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 80))], spacing: 8) {
          ForEach(tags, id: \.self) { tag in
            TagChip(tag: tag) {
              removeTag(tag)
            }
          }
          
          if isAddingTag {
            HStack {
              TextField("Add tag", text: $newTag)
                .focused($isTextFieldFocused)
                .textFieldStyle(RoundedBorderTextFieldStyle())
                .onSubmit {
                  addTag()
                }
              
              Button("Add") {
                addTag()
              }
              .buttonStyle(.borderedProminent)
              .disabled(newTag.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
              
              Button("Cancel") {
                cancelAddingTag()
              }
              .buttonStyle(.bordered)
            }
            .frame(maxWidth: .infinity)
          }
        }
      } else {
        Text("No tags added")
          .foregroundColor(.secondary)
          .font(.caption)
      }
    }
    .padding()
    .background(Color(platformColor: PlatformColor.platformSystemGray6))
    .cornerRadius(12)
  }
  
  private func addTag() {
    let trimmedTag = newTag.trimmingCharacters(in: .whitespacesAndNewlines)
    
    guard !trimmedTag.isEmpty else { return }
    
    // Remove # if user added it
    let cleanTag = trimmedTag.hasPrefix("#") ? String(trimmedTag.dropFirst()) : trimmedTag
    
    // Check if tag already exists
    guard !tags.contains(cleanTag.lowercased()) else {
      cancelAddingTag()
      return
    }
    
    // Add the tag
    tags.append(cleanTag.lowercased())
    
    // Reset state
    cancelAddingTag()
  }
  
  private func removeTag(_ tag: String) {
    tags.removeAll { $0 == tag }
  }
  
  private func cancelAddingTag() {
    newTag = ""
    isAddingTag = false
    isTextFieldFocused = false
  }
}

struct TagChip: View {
  let tag: String
  let onRemove: () -> Void
  
  var body: some View {
    HStack(spacing: 4) {
      Text("#\(tag)")
        .font(.caption)
        .foregroundColor(.blue)
      
      Button(action: onRemove) {
        Image(systemName: "xmark.circle.fill")
          .foregroundColor(.gray)
          .font(.caption)
      }
    }
    .padding(.horizontal, 8)
    .padding(.vertical, 4)
    .background(Color.blue.opacity(0.1))
    .cornerRadius(12)
  }
}

#Preview {
  @Previewable @State var tags: [String] = ["swift", "ios", "development"]
  
  return OutlineTagsView(tags: $tags)
    .padding()
}
