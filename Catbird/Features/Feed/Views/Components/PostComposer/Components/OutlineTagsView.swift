import SwiftUI

struct OutlineTagsView: View {
  @Binding var tags: [String]
  @State private var newTag: String = ""
  @State private var isAddingTag: Bool = false
  @State private var showDuplicateWarning: Bool = false
  @FocusState private var isTextFieldFocused: Bool
  
  private let maxTagLength = 25
  private let maxTags = 10
  
  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      headerSection
      
      if !tags.isEmpty {
        tagsDisplaySection
      }
      
      addTagSection
      
      if tags.isEmpty && !isAddingTag {
        emptyStateSection
      }
    }
    .padding(16)
    .background(Color.systemBackground)
    .overlay(
      RoundedRectangle(cornerRadius: 12)
        .stroke(Color.systemGray5, lineWidth: 1)
    )
    .cornerRadius(12)
    .animation(.easeInOut(duration: 0.3), value: tags.count)
    .animation(.easeInOut(duration: 0.2), value: isAddingTag)
  }
  
  // MARK: - Header Section
  
  private var headerSection: some View {
    HStack(alignment: .center, spacing: 8) {
        VStack (alignment: .leading, spacing: 8){
            HStack (alignment:.top, spacing: 8){
                Image(systemName: "number")
                    .appFont(size: 16)
                    .foregroundColor(.accentColor)
                
                Text("Outline Hashtags")
                    .appFont(AppTextRole.subheadline)
                    .fontWeight(.semibold)
                    .foregroundColor(.primary)
            }
            
            Text("These won't be visible on the Bluesky app but will be indexed by feeds.")
                .appFont(AppTextRole.caption)
                .fontWeight(.regular)
                .foregroundColor(.secondary)
            
            
            if !tags.isEmpty {
                Text("\(tags.count)/\(maxTags)")
                    .appFont(AppTextRole.caption)
                    .foregroundColor(.secondary)
            }
        }
      Spacer()
      
      Button(action: {
        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
          toggleAddingTag()
        }
      }) {
        Image(systemName: isAddingTag ? "xmark.circle.fill" : "plus.circle.fill")
          .appFont(size: 20)
          .foregroundColor(.accentColor)
      }
      .disabled(tags.count >= maxTags && !isAddingTag)
      .opacity(tags.count >= maxTags && !isAddingTag ? 0.5 : 1.0)
    }
  }
  
  // MARK: - Tags Display Section
  
  private var tagsDisplaySection: some View {
    FlowLayout(horizontalSpacing: 8, verticalSpacing: 8) {
      ForEach(tags, id: \.self) { tag in
        EnhancedTagChip(
          tag: tag,
          onRemove: {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
              removeTag(tag)
            }
          }
        )
      }
    }
  }
  
  // MARK: - Add Tag Section
  
  private var addTagSection: some View {
    Group {
      if isAddingTag {
        VStack(alignment: .leading, spacing: 12) {
          HStack(spacing: 12) {
            TextField("Add hashtag", text: $newTag)
              .focused($isTextFieldFocused)
              .appFont(AppTextRole.body)
              .padding(.horizontal, 16)
              .padding(.vertical, 12)
              .background(Color.systemGray6)
              .cornerRadius(10)
              .onSubmit {
                addTag()
              }
              .onChange(of: newTag) {
                if showDuplicateWarning {
                  showDuplicateWarning = false
                }
              }
            
            Button(action: addTag) {
              Text("Add")
                .appFont(AppTextRole.subheadline)
                .fontWeight(.semibold)
                .foregroundColor(.white)
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .background(
                  RoundedRectangle(cornerRadius: 10)
                    .fill(canAddTag ? Color.accentColor : Color.systemGray4)
                )
            }
            .disabled(!canAddTag)
          }
          
          // Helper text and warnings
          VStack(alignment: .leading, spacing: 4) {
            if showDuplicateWarning {
              Label("This hashtag already exists", systemImage: "exclamationmark.triangle.fill")
                .appFont(AppTextRole.caption)
                .foregroundColor(.orange)
            } else if newTag.count > maxTagLength {
              Label("Maximum \(maxTagLength) characters", systemImage: "exclamationmark.circle.fill")
                .appFont(AppTextRole.caption)
                .foregroundColor(.red)
            } else {
              Text("Enter a hashtag without the # symbol")
                .appFont(AppTextRole.caption)
                .foregroundColor(.secondary)
            }
            
            if tags.count >= maxTags {
              Label("Maximum \(maxTags) hashtags allowed", systemImage: "info.circle.fill")
                .appFont(AppTextRole.caption)
                .foregroundColor(.orange)
            }
          }
        }
        .onAppear {
          DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            isTextFieldFocused = true
          }
        }
      }
    }
  }
  
  // MARK: - Empty State Section
  
  private var emptyStateSection: some View {
    HStack(spacing: 12) {
      Image(systemName: "number.circle")
        .appFont(size: 24)
        .foregroundColor(.systemGray4)
      
      VStack(alignment: .leading, spacing: 2) {
        Text("No hashtags added")
          .appFont(AppTextRole.subheadline)
          .foregroundColor(.secondary)
        
        Text("Tap + to add hashtags to categorize your post")
          .appFont(AppTextRole.caption)
          .foregroundColor(.systemGray)
      }
      
      Spacer()
    }
    .padding(.vertical, 8)
  }
  
  // MARK: - Helper Properties
  
  private var canAddTag: Bool {
    let trimmedTag = newTag.trimmingCharacters(in: .whitespacesAndNewlines)
    return !trimmedTag.isEmpty && 
           trimmedTag.count <= maxTagLength &&
           tags.count < maxTags &&
           !tags.contains(cleanedTag(trimmedTag).lowercased())
  }
  
  // MARK: - Helper Methods
  
  private func toggleAddingTag() {
    isAddingTag.toggle()
    if isAddingTag {
      isTextFieldFocused = true
    } else {
      cancelAddingTag()
    }
  }
  
  private func addTag() {
    let trimmedTag = newTag.trimmingCharacters(in: .whitespacesAndNewlines)
    
    guard !trimmedTag.isEmpty else { return }
    guard trimmedTag.count <= maxTagLength else { return }
    guard tags.count < maxTags else { return }
    
    let cleanTag = cleanedTag(trimmedTag)
    
    // Check if tag already exists (case insensitive)
    if tags.contains(where: { $0.lowercased() == cleanTag.lowercased() }) {
      showDuplicateWarning = true
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
    showDuplicateWarning = false
  }
  
  private func cleanedTag(_ tag: String) -> String {
    var cleaned = tag.hasPrefix("#") ? String(tag.dropFirst()) : tag
    // Remove any invalid characters
    cleaned = cleaned.replacingOccurrences(of: " ", with: "")
    cleaned = cleaned.replacingOccurrences(of: "#", with: "")
    return cleaned
  }
}

// MARK: - Enhanced Tag Chip

struct EnhancedTagChip: View {
  let tag: String
  let onRemove: () -> Void
  @State private var isPressed: Bool = false
  
  var body: some View {
    HStack(spacing: 8) {
      Text("#\(tag)")
        .appFont(AppTextRole.subheadline)
        .fontWeight(.medium)
        .foregroundColor(.accentColor)
        .lineLimit(1)
      
      Button(action: onRemove) {
        Image(systemName: "xmark.circle.fill")
          .appFont(size: 16)
          .foregroundColor(.systemGray2)
      }
      .buttonStyle(PlainButtonStyle())
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 8)
    .background(
      RoundedRectangle(cornerRadius: 18)
        .fill(Color.accentColor.opacity(isPressed ? 0.2 : 0.1))
        .overlay(
          RoundedRectangle(cornerRadius: 18)
            .stroke(Color.accentColor.opacity(0.3), lineWidth: 1)
        )
    )
    .scaleEffect(isPressed ? 0.95 : 1.0)
    .animation(.easeInOut(duration: 0.1), value: isPressed)
    .onLongPressGesture(minimumDuration: 0) {
      // This won't trigger, but the gesture states will
    } onPressingChanged: { pressing in
      isPressed = pressing
    }
  }
}


#Preview {
  @Previewable @State var tags: [String] = ["swift", "ios", "development", "mobile", "app"]
  
  return VStack(spacing: 20) {
    OutlineTagsView(tags: $tags)
    
    OutlineTagsView(tags: .constant([]))
  }
  .padding()
  .background(Color.systemGray6)
}
