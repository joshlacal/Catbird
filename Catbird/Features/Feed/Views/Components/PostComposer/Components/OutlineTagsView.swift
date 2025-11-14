import SwiftUI

struct OutlineTagsView: View {
  @Binding var tags: [String]
  @State private var newTag: String = ""
  @State private var isAddingTag: Bool = false
  @State private var showDuplicateWarning: Bool = false
  @FocusState private var isTextFieldFocused: Bool
  
  // Compact layout option for tighter UI in constrained spaces
  var compact: Bool = false
  
  private let maxTagLength = 25
  private let maxTags = 10
  
  var body: some View {
    VStack(alignment: .leading, spacing: compact ? 10 : 16) {
      headerSection
      
      if !tags.isEmpty {
        tagsDisplaySection
      }
      
      addTagSection
      
      if tags.isEmpty && !isAddingTag {
        emptyStateSection
      }
    }
    .padding(compact ? 12 : 16)
    .background(Color.systemBackground)
    .overlay(
      RoundedRectangle(cornerRadius: compact ? 10 : 12)
        .stroke(Color.systemGray5, lineWidth: 1)
    )
    .cornerRadius(compact ? 10 : 12)
    .animation(.easeInOut(duration: 0.3), value: tags.count)
    .animation(.easeInOut(duration: 0.2), value: isAddingTag)
  }
  
  // MARK: - Header Section
  
  private var headerSection: some View {
    Group {
      if compact {
        // Compact header: single line with optional count, no description
        HStack(alignment: .center, spacing: 8) {
          Image(systemName: "number")
            .appFont(size: 14)
            .foregroundColor(.accentColor)
          
          HStack(spacing: 6) {
            Text("Outline Hashtags")
              .appFont(AppTextRole.caption)
              .fontWeight(.semibold)
              .foregroundColor(.primary)
            if !tags.isEmpty {
              Text("\(tags.count)/\(maxTags)")
                .appFont(AppTextRole.caption2)
                .foregroundColor(.secondary)
            }
          }
          Spacer()
          Button(action: {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) { toggleAddingTag() }
          }) {
            Image(systemName: isAddingTag ? "xmark.circle.fill" : "plus.circle.fill")
              .appFont(size: 18)
              .foregroundColor(.accentColor)
          }
          .disabled(tags.count >= maxTags && !isAddingTag)
          .opacity(tags.count >= maxTags && !isAddingTag ? 0.5 : 1.0)
        }
      } else {
        // Default header: title + description + optional count stacked
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
    }
  }
  
  // MARK: - Tags Display Section
  
  private var tagsDisplaySection: some View {
    FlowLayout(horizontalSpacing: compact ? 6 : 8, verticalSpacing: compact ? 4 : 8) {
      ForEach(tags, id: \.self) { tag in
        EnhancedTagChip(
          tag: tag,
          compact: compact,
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
        VStack(alignment: .leading, spacing: compact ? 8 : 12) {
          HStack(spacing: compact ? 8 : 12) {
            TextField("Add hashtag", text: $newTag)
              .focused($isTextFieldFocused)
              .appFont(compact ? AppTextRole.caption : AppTextRole.body)
              .padding(.horizontal, compact ? 12 : 16)
              .padding(.vertical, compact ? 8 : 12)
              .background(Color.systemGray6)
              .cornerRadius(compact ? 8 : 10)
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
                .appFont(compact ? AppTextRole.caption : AppTextRole.subheadline)
                .fontWeight(.semibold)
                .foregroundColor(.white)
                .padding(.horizontal, compact ? 14 : 20)
                .padding(.vertical, compact ? 8 : 12)
                .background(
                  RoundedRectangle(cornerRadius: compact ? 8 : 10)
                    .fill(canAddTag ? Color.accentColor : Color.systemGray4)
                )
            }
            .disabled(!canAddTag)
          }
          
          // Helper text and warnings
          VStack(alignment: .leading, spacing: compact ? 2 : 4) {
            if showDuplicateWarning {
              Label("This hashtag already exists", systemImage: "exclamationmark.triangle.fill")
                .appFont(AppTextRole.caption)
                .foregroundColor(.orange)
            } else if newTag.count > maxTagLength {
              Label("Maximum \(maxTagLength) characters", systemImage: "exclamationmark.circle.fill")
                .appFont(AppTextRole.caption)
                .foregroundColor(.red)
            } else if !compact {
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
    HStack(spacing: compact ? 8 : 12) {
      Image(systemName: "number.circle")
        .appFont(size: compact ? 20 : 24)
        .foregroundColor(.systemGray4)
      
      VStack(alignment: .leading, spacing: 2) {
        Text("No hashtags added")
          .appFont(compact ? AppTextRole.caption : AppTextRole.subheadline)
          .foregroundColor(.secondary)
        
        if !compact {
          Text("Tap + to add hashtags to categorize your post")
            .appFont(AppTextRole.caption)
            .foregroundColor(.systemGray)
        }
      }
      
      Spacer()
    }
    .padding(.vertical, compact ? 4 : 8)
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
    
    // Keep adding flow active and keyboard open
    newTag = ""
    showDuplicateWarning = false
    isAddingTag = true
    isTextFieldFocused = true
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
  var compact: Bool = false
  let onRemove: () -> Void
  @State private var isPressed: Bool = false
  
  var body: some View {
    HStack(spacing: compact ? 6 : 8) {
      Text("#\(tag)")
        .appFont(compact ? AppTextRole.caption : AppTextRole.subheadline)
        .fontWeight(.medium)
        .foregroundColor(.accentColor)
        .lineLimit(1)
      
      Button(action: onRemove) {
        Image(systemName: "xmark.circle.fill")
          .appFont(size: compact ? 14 : 16)
          .foregroundColor(.systemGray2)
      }
      .buttonStyle(PlainButtonStyle())
    }
    .padding(.horizontal, compact ? 10 : 14)
    .padding(.vertical, compact ? 6 : 8)
    .background(
      RoundedRectangle(cornerRadius: compact ? 14 : 18)
        .fill(Color.accentColor.opacity(isPressed ? 0.2 : 0.1))
        .overlay(
          RoundedRectangle(cornerRadius: compact ? 14 : 18)
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
    @Previewable @Environment(AppState.self) var appState
  @Previewable @State var tags: [String] = ["swift", "ios", "development", "mobile", "app"]
  
  return VStack(spacing: 20) {
    OutlineTagsView(tags: $tags)
    
    OutlineTagsView(tags: .constant([]))
  }
  .padding()
  .background(Color.systemGray6)
}
