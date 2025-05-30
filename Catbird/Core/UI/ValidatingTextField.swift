import SwiftUI

/// A text field that displays validation errors
struct ValidatingTextField: View {
    @Binding var text: String
    var prompt: String
    var icon: String
    var validationError: String?
    var isDisabled: Bool
    var keyboardType: UIKeyboardType = .default
    var submitLabel: SubmitLabel = .done
    var onSubmit: (() -> Void)?
    
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: icon)
                    .foregroundStyle(.secondary)
                
                TextField("", text: $text, prompt: Text(prompt))
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .keyboardType(keyboardType)
                    .submitLabel(submitLabel)
                    .onSubmit {
                        onSubmit?()
                    }
                
                if !text.isEmpty {
                    Button(action: { text = "" }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding()
            .background {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color(.systemBackground))
                    .shadow(color: .black.opacity(0.05), radius: 2, x: 0, y: 1)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .stroke(validationError != nil ? .red.opacity(0.5) : .gray.opacity(0.2), lineWidth: 1)
            }
            .disabled(isDisabled)
            
            if let error = validationError {
                Label(error, systemImage: "exclamationmark.circle")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 4)
            }
        }
    }
}

#Preview {
    VStack {
        ValidatingTextField(
            text: .constant("test"),
            prompt: "Enter value",
            icon: "envelope",
            validationError: nil,
            isDisabled: false
        )
        
        ValidatingTextField(
            text: .constant(""),
            prompt: "Enter value",
            icon: "envelope",
            validationError: "This field is required",
            isDisabled: false
        )
        
        ValidatingTextField(
            text: .constant("test"),
            prompt: "Enter value",
            icon: "envelope",
            validationError: nil,
            isDisabled: true
        )
    }
    .padding()
}
