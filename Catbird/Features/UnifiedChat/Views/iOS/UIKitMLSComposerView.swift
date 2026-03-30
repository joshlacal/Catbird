#if os(iOS)
import UIKit

// MARK: - Composer Delegate

protocol UIKitMLSComposerDelegate: AnyObject {
  func composerDidChangeHeight(_ composer: UIKitMLSComposerView, height: CGFloat)
  func composerDidTapSend(_ composer: UIKitMLSComposerView, text: String)
  func composerDidTapAttach(_ composer: UIKitMLSComposerView)
  func composerDidChangeTypingState(_ composer: UIKitMLSComposerView, isTyping: Bool)
  func composerDidTapVoice(_ composer: UIKitMLSComposerView)
  func composerDidTapPhoto(_ composer: UIKitMLSComposerView)
  func composerDidTapGif(_ composer: UIKitMLSComposerView)
  func composerDidTapSharePost(_ composer: UIKitMLSComposerView)
}

// MARK: - UIKit MLS Composer View

/// Pure UIKit message composer with iOS 26 Liquid Glass background.
/// Self-sizing, auto-growing text input with send and attachment buttons.
@available(iOS 16.0, *)
final class UIKitMLSComposerView: UIView, UITextViewDelegate {

  // MARK: - Public Properties

  weak var delegate: UIKitMLSComposerDelegate?

  var text: String {
    get { textView.text }
    set {
      textView.text = newValue
      updatePlaceholderVisibility()
      updateSendButtonState()
      recalculateTextViewHeight()
    }
  }

  var placeholderText: String = "Message" {
    didSet { placeholderLabel.text = placeholderText }
  }

  var isRecording: Bool = false {
    didSet { updateRightButton() }
  }

  // MARK: - Layout Constants

  private let minTextHeight: CGFloat = 36
  private let maxTextHeight: CGFloat = 120
  private let horizontalPadding: CGFloat = 15  // DesignTokens.Spacing.lg
  private let verticalPadding: CGFloat = 6     // DesignTokens.Spacing.sm
  private let buttonSize: CGFloat = 30         // DesignTokens.Size.buttonSM
  private let innerSpacing: CGFloat = 6        // DesignTokens.Spacing.sm
  private let outerMargin: CGFloat = 12        // DesignTokens.Spacing.base

  // MARK: - Subviews

  private let backgroundEffectView: UIVisualEffectView = {
    let effect: UIVisualEffect
    if #available(iOS 26.0, *) {
      let glass = UIGlassEffect()
      effect = glass
    } else {
      effect = UIBlurEffect(style: .systemMaterial)
    }
    let view = UIVisualEffectView(effect: effect)
    view.translatesAutoresizingMaskIntoConstraints = false
    view.clipsToBounds = true
    return view
  }()

  private let contentStack: UIStackView = {
    let stack = UIStackView()
    stack.axis = .horizontal
    stack.alignment = .bottom
    stack.spacing = 6
    stack.translatesAutoresizingMaskIntoConstraints = false
    return stack
  }()

  private lazy var attachButton: UIButton = {
    var config = UIButton.Configuration.plain()
    config.image = UIImage(
      systemName: "plus",
      withConfiguration: UIImage.SymbolConfiguration(pointSize: 15, weight: .semibold)
    )
    config.baseForegroundColor = .label
    config.contentInsets = .zero
    let button = UIButton(configuration: config)
    button.translatesAutoresizingMaskIntoConstraints = false
    button.accessibilityLabel = "Add attachment"
    button.menu = UIMenu(children: [
      UIAction(title: "Send Image", image: UIImage(systemName: "photo")) { [weak self] _ in
        guard let self else { return }
        self.delegate?.composerDidTapPhoto(self)
      },
      UIAction(title: "Add GIF", image: UIImage(systemName: "photo.on.rectangle")) { [weak self] _ in
        guard let self else { return }
        self.delegate?.composerDidTapGif(self)
      },
      UIAction(title: "Share Post", image: UIImage(systemName: "text.bubble")) { [weak self] _ in
        guard let self else { return }
        self.delegate?.composerDidTapSharePost(self)
      },
    ])
    button.showsMenuAsPrimaryAction = true
    return button
  }()

  private let textView: UITextView = {
    let tv = UITextView()
    tv.font = .systemFont(ofSize: 17) // DesignTokens.FontSize.body
    tv.backgroundColor = .clear
    tv.textContainerInset = UIEdgeInsets(top: 8, left: 4, bottom: 8, right: 4)
    tv.textContainer.lineFragmentPadding = 0
    tv.isScrollEnabled = false
    tv.showsVerticalScrollIndicator = false
    tv.translatesAutoresizingMaskIntoConstraints = false
    tv.returnKeyType = .default
    tv.enablesReturnKeyAutomatically = false
    return tv
  }()

  private let placeholderLabel: UILabel = {
    let label = UILabel()
    label.text = "Message"
    label.font = .systemFont(ofSize: 17)
    label.textColor = .placeholderText
    label.translatesAutoresizingMaskIntoConstraints = false
    label.isUserInteractionEnabled = false
    return label
  }()

  private let sendButton: UIButton = {
    var config = UIButton.Configuration.filled()
    config.image = UIImage(
      systemName: "arrow.up",
      withConfiguration: UIImage.SymbolConfiguration(pointSize: 15, weight: .semibold)
    )
    config.baseForegroundColor = .white
    config.baseBackgroundColor = .tintColor
    config.cornerStyle = .capsule
    config.contentInsets = .zero
    let button = UIButton(configuration: config)
    button.translatesAutoresizingMaskIntoConstraints = false
    button.accessibilityLabel = "Send message"
    return button
  }()

  private let voiceButton: UIButton = {
    var config = UIButton.Configuration.filled()
    config.image = UIImage(
      systemName: "mic.fill",
      withConfiguration: UIImage.SymbolConfiguration(pointSize: 15, weight: .semibold)
    )
    config.baseForegroundColor = .white
    config.baseBackgroundColor = .tintColor
    config.cornerStyle = .capsule
    config.contentInsets = .zero
    let button = UIButton(configuration: config)
    button.translatesAutoresizingMaskIntoConstraints = false
    button.accessibilityLabel = "Record voice message"
    return button
  }()

  private var textViewHeightConstraint: NSLayoutConstraint!
  private var wasTyping = false

  // MARK: - Initialization

  override init(frame: CGRect) {
    super.init(frame: frame)
    setupViews()
    setupConstraints()
    setupActions()
    updateSendButtonState()
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  // MARK: - Setup

  private func setupViews() {
    backgroundColor = .clear
    translatesAutoresizingMaskIntoConstraints = false

    addSubview(backgroundEffectView)

    // The content goes into the glass view's contentView
    backgroundEffectView.contentView.addSubview(contentStack)

    // Attach button wrapper to center it vertically against the bottom line
    let attachWrapper = UIView()
    attachWrapper.translatesAutoresizingMaskIntoConstraints = false
    attachWrapper.addSubview(attachButton)
    NSLayoutConstraint.activate([
      attachButton.centerXAnchor.constraint(equalTo: attachWrapper.centerXAnchor),
      attachButton.bottomAnchor.constraint(equalTo: attachWrapper.bottomAnchor, constant: -2),
      attachButton.topAnchor.constraint(greaterThanOrEqualTo: attachWrapper.topAnchor),
      attachButton.widthAnchor.constraint(equalToConstant: buttonSize),
      attachButton.heightAnchor.constraint(equalToConstant: buttonSize),
      attachWrapper.widthAnchor.constraint(equalToConstant: buttonSize),
    ])

    // Text input container with placeholder overlay
    let textContainer = UIView()
    textContainer.translatesAutoresizingMaskIntoConstraints = false
    textContainer.addSubview(textView)
    textContainer.addSubview(placeholderLabel)

    textViewHeightConstraint = textView.heightAnchor.constraint(equalToConstant: minTextHeight)
    textViewHeightConstraint.priority = .defaultHigh

    NSLayoutConstraint.activate([
      textView.topAnchor.constraint(equalTo: textContainer.topAnchor),
      textView.leadingAnchor.constraint(equalTo: textContainer.leadingAnchor),
      textView.trailingAnchor.constraint(equalTo: textContainer.trailingAnchor),
      textView.bottomAnchor.constraint(equalTo: textContainer.bottomAnchor),
      textViewHeightConstraint,
      placeholderLabel.leadingAnchor.constraint(equalTo: textView.leadingAnchor, constant: 5),
      placeholderLabel.centerYAnchor.constraint(equalTo: textContainer.centerYAnchor),
    ])

    // Right button wrapper (send or voice, same position)
    let sendWrapper = UIView()
    sendWrapper.translatesAutoresizingMaskIntoConstraints = false
    sendWrapper.addSubview(sendButton)
    sendWrapper.addSubview(voiceButton)
    NSLayoutConstraint.activate([
      sendButton.centerXAnchor.constraint(equalTo: sendWrapper.centerXAnchor),
      sendButton.bottomAnchor.constraint(equalTo: sendWrapper.bottomAnchor, constant: -3),
      sendButton.topAnchor.constraint(greaterThanOrEqualTo: sendWrapper.topAnchor),
      sendButton.widthAnchor.constraint(equalToConstant: buttonSize),
      sendButton.heightAnchor.constraint(equalToConstant: buttonSize),
      voiceButton.centerXAnchor.constraint(equalTo: sendWrapper.centerXAnchor),
      voiceButton.bottomAnchor.constraint(equalTo: sendWrapper.bottomAnchor, constant: -3),
      voiceButton.topAnchor.constraint(greaterThanOrEqualTo: sendWrapper.topAnchor),
      voiceButton.widthAnchor.constraint(equalToConstant: buttonSize),
      voiceButton.heightAnchor.constraint(equalToConstant: buttonSize),
      sendWrapper.widthAnchor.constraint(equalToConstant: buttonSize),
    ])

    contentStack.addArrangedSubview(attachWrapper)
    contentStack.addArrangedSubview(textContainer)
    contentStack.addArrangedSubview(sendWrapper)

    textView.delegate = self

    // Round the glass background
    backgroundEffectView.layer.cornerRadius = 24
    backgroundEffectView.layer.cornerCurve = .continuous
  }

  private func setupConstraints() {
    NSLayoutConstraint.activate([
      // Background effect view fills self with outer margin
      backgroundEffectView.topAnchor.constraint(equalTo: topAnchor, constant: outerMargin / 2),
      backgroundEffectView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: outerMargin),
      backgroundEffectView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -outerMargin),
      backgroundEffectView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -outerMargin / 2),

      // Content stack inside the effect view
      contentStack.topAnchor.constraint(equalTo: backgroundEffectView.contentView.topAnchor, constant: verticalPadding),
      contentStack.leadingAnchor.constraint(equalTo: backgroundEffectView.contentView.leadingAnchor, constant: horizontalPadding),
      contentStack.trailingAnchor.constraint(equalTo: backgroundEffectView.contentView.trailingAnchor, constant: -horizontalPadding),
      contentStack.bottomAnchor.constraint(equalTo: backgroundEffectView.contentView.bottomAnchor, constant: -verticalPadding),
    ])
  }

  private func setupActions() {
    sendButton.addTarget(self, action: #selector(sendTapped), for: .touchUpInside)
    voiceButton.addTarget(self, action: #selector(voiceTapped), for: .touchUpInside)
  }

  // MARK: - Actions

  @objc private func voiceTapped() {
    delegate?.composerDidTapVoice(self)
  }

  @objc private func sendTapped() {
    let trimmed = textView.text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    let message = textView.text ?? ""
    textView.text = ""
    updatePlaceholderVisibility()
    updateSendButtonState()
    recalculateTextViewHeight()
    delegate?.composerDidTapSend(self, text: message)
    delegate?.composerDidChangeTypingState(self, isTyping: false)
    wasTyping = false
  }

  // MARK: - UITextViewDelegate

  func textViewDidChange(_ textView: UITextView) {
    updatePlaceholderVisibility()
    updateSendButtonState()
    recalculateTextViewHeight()

    let isTyping = !textView.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    if isTyping != wasTyping {
      wasTyping = isTyping
      delegate?.composerDidChangeTypingState(self, isTyping: isTyping)
    }
  }

  // MARK: - Private Helpers

  private func updatePlaceholderVisibility() {
    placeholderLabel.isHidden = !textView.text.isEmpty
  }

  private func updateSendButtonState() {
    let canSend = !(textView.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    sendButton.isEnabled = canSend
    sendButton.alpha = canSend ? 1.0 : 0.5

    var config = sendButton.configuration
    config?.baseBackgroundColor = canSend ? .tintColor : .secondarySystemFill
    sendButton.configuration = config

    updateRightButton()
  }

  private func updateRightButton() {
    let hasText = !(textView.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    // Show send button when there's text, voice button when empty
    sendButton.isHidden = !hasText
    voiceButton.isHidden = hasText

    // Update voice button appearance for recording state
    var voiceConfig = voiceButton.configuration
    voiceConfig?.image = UIImage(
      systemName: isRecording ? "stop.circle.fill" : "mic.fill",
      withConfiguration: UIImage.SymbolConfiguration(pointSize: 15, weight: .semibold)
    )
    voiceConfig?.baseBackgroundColor = isRecording ? .systemRed : .tintColor
    voiceButton.configuration = voiceConfig
    voiceButton.accessibilityLabel = isRecording ? "Stop recording" : "Record voice message"
  }

  private func recalculateTextViewHeight() {
    let fittingSize = CGSize(
      width: textView.frame.width > 0 ? textView.frame.width : 200,
      height: .greatestFiniteMagnitude
    )
    let newSize = textView.sizeThatFits(fittingSize)
    let clampedHeight = min(max(newSize.height, minTextHeight), maxTextHeight)

    textView.isScrollEnabled = newSize.height > maxTextHeight

    guard abs(clampedHeight - textViewHeightConstraint.constant) > 0.5 else { return }

    textViewHeightConstraint.constant = clampedHeight
    UIView.animate(withDuration: 0.15, delay: 0, options: .curveEaseOut) {
      self.layoutIfNeeded()
      self.superview?.layoutIfNeeded()
    } completion: { _ in
      self.notifyHeightChange()
    }
  }

  private func notifyHeightChange() {
    let totalHeight = systemLayoutSizeFitting(
      CGSize(width: bounds.width, height: UIView.layoutFittingCompressedSize.height),
      withHorizontalFittingPriority: .required,
      verticalFittingPriority: .fittingSizeLevel
    ).height
    delegate?.composerDidChangeHeight(self, height: totalHeight)
  }

  // MARK: - Public API

  /// Dismiss the keyboard.
  func dismissKeyboard() {
    textView.resignFirstResponder()
  }

  /// Focus the text view.
  func becomeFirstResponderForTextView() {
    textView.becomeFirstResponder()
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    // Recalculate on width changes
    recalculateTextViewHeight()
  }
}
#endif
