#if os(iOS)
import UIKit

// MARK: - Composer Delegate

protocol UIKitMLSComposerDelegate: AnyObject {
  func composerDidChangeHeight(_ composer: UIKitMLSComposerView, height: CGFloat)
  func composerDidTapSend(_ composer: UIKitMLSComposerView, text: String)
  func composerDidTapAttach(_ composer: UIKitMLSComposerView)
  func composerDidChangeTypingState(_ composer: UIKitMLSComposerView, isTyping: Bool)
  func composerDidTapVoice(_ composer: UIKitMLSComposerView)
  func composerDidCancelVoiceRecording(_ composer: UIKitMLSComposerView)
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

  var embedPreviewImage: UIImage? {
    didSet { updateEmbedPreview() }
  }

  var hasEmbed: Bool = false {
    didSet {
      updateEmbedPreview()
      updateSendButtonState()
    }
  }

  var onEmbedRemoved: (() -> Void)?

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

  private let embedPreviewContainer: UIStackView = {
    let stack = UIStackView()
    stack.axis = .horizontal
    stack.alignment = .center
    stack.spacing = 8
    stack.translatesAutoresizingMaskIntoConstraints = false
    stack.isHidden = true
    stack.backgroundColor = .secondarySystemBackground
    stack.layer.cornerRadius = 8
    stack.layer.cornerCurve = .continuous
    stack.layoutMargins = UIEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
    stack.isLayoutMarginsRelativeArrangement = true
    return stack
  }()

  private let embedPreviewImageView: UIImageView = {
    let iv = UIImageView()
    iv.translatesAutoresizingMaskIntoConstraints = false
    iv.contentMode = .scaleAspectFill
    iv.clipsToBounds = true
    iv.layer.cornerRadius = 6
    iv.layer.cornerCurve = .continuous
    NSLayoutConstraint.activate([
      iv.widthAnchor.constraint(equalToConstant: 32),
      iv.heightAnchor.constraint(equalToConstant: 32),
    ])
    return iv
  }()

  private let embedPreviewTitleLabel: UILabel = {
    let label = UILabel()
    label.font = .systemFont(ofSize: 14, weight: UIFont.Weight.medium)
    label.textColor = .secondaryLabel
    label.text = "Photo attached"
    label.translatesAutoresizingMaskIntoConstraints = false
    label.setContentHuggingPriority(.defaultLow, for: .horizontal)
    return label
  }()

  private lazy var embedPreviewDismissButton: UIButton = {
    var config = UIButton.Configuration.plain()
    config.image = UIImage(
      systemName: "xmark.circle.fill",
      withConfiguration: UIImage.SymbolConfiguration(pointSize: 14, weight: .medium)
    )
    config.baseForegroundColor = .tertiaryLabel
    config.contentInsets = .zero
    let button = UIButton(configuration: config)
    button.translatesAutoresizingMaskIntoConstraints = false
    button.accessibilityLabel = "Remove attachment"
    button.addTarget(self, action: #selector(embedDismissTapped), for: .touchUpInside)
    NSLayoutConstraint.activate([
      button.widthAnchor.constraint(equalToConstant: 24),
      button.heightAnchor.constraint(equalToConstant: 24),
    ])
    return button
  }()

  private var textViewHeightConstraint: NSLayoutConstraint!
  private var contentStackTopWithoutEmbed: NSLayoutConstraint!
  private var contentStackTopWithEmbed: NSLayoutConstraint!
  private var wasTyping = false
  private var voiceLongPressStartY: CGFloat = 0

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
    setupEmbedPreview()
    backgroundEffectView.contentView.addSubview(embedPreviewContainer)
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

      // Embed preview container above content stack
      embedPreviewContainer.topAnchor.constraint(equalTo: backgroundEffectView.contentView.topAnchor, constant: verticalPadding),
      embedPreviewContainer.leadingAnchor.constraint(equalTo: backgroundEffectView.contentView.leadingAnchor, constant: horizontalPadding),
      embedPreviewContainer.trailingAnchor.constraint(equalTo: backgroundEffectView.contentView.trailingAnchor, constant: -horizontalPadding),

      // Content stack inside the effect view
      contentStack.leadingAnchor.constraint(equalTo: backgroundEffectView.contentView.leadingAnchor, constant: horizontalPadding),
      contentStack.trailingAnchor.constraint(equalTo: backgroundEffectView.contentView.trailingAnchor, constant: -horizontalPadding),
      contentStack.bottomAnchor.constraint(equalTo: backgroundEffectView.contentView.bottomAnchor, constant: -verticalPadding),
    ])

    // Dynamic top constraint for content stack (toggles based on embed visibility)
    contentStackTopWithoutEmbed = contentStack.topAnchor.constraint(
      equalTo: backgroundEffectView.contentView.topAnchor, constant: verticalPadding)
    contentStackTopWithEmbed = contentStack.topAnchor.constraint(
      equalTo: embedPreviewContainer.bottomAnchor, constant: verticalPadding)
    contentStackTopWithoutEmbed.isActive = true
    contentStackTopWithEmbed.isActive = false
  }

  private func setupActions() {
    sendButton.addTarget(self, action: #selector(sendTapped), for: .touchUpInside)
    voiceButton.addTarget(self, action: #selector(voiceTapped), for: .touchUpInside)

    let longPress = UILongPressGestureRecognizer(target: self, action: #selector(voiceLongPressed(_:)))
    longPress.minimumPressDuration = 0.3
    voiceButton.addGestureRecognizer(longPress)
  }

  // MARK: - Actions

  @objc private func voiceTapped() {
    delegate?.composerDidTapVoice(self)
  }

  @objc private func voiceLongPressed(_ gesture: UILongPressGestureRecognizer) {
    switch gesture.state {
    case .began:
      voiceLongPressStartY = gesture.location(in: self).y
      delegate?.composerDidTapVoice(self)
    case .changed:
      let currentY = gesture.location(in: self).y
      let delta = voiceLongPressStartY - currentY
      if delta > 60 {
        // Visual feedback for cancel state could be added here
      }
    case .ended, .cancelled:
      let currentY = gesture.location(in: self).y
      let delta = voiceLongPressStartY - currentY
      if delta > 60 {
        delegate?.composerDidCancelVoiceRecording(self)
      } else {
        delegate?.composerDidTapVoice(self)
      }
    default:
      break
    }
  }

  @objc private func embedDismissTapped() {
    hasEmbed = false
    embedPreviewImage = nil
    onEmbedRemoved?()
  }

  @objc private func sendTapped() {
    let trimmed = textView.text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty || hasEmbed else { return }
    let message = textView.text ?? ""
    textView.text = ""
    hasEmbed = false
    embedPreviewImage = nil
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

  // MARK: - Embed Preview

  private func setupEmbedPreview() {
    let spacer = UIView()
    spacer.translatesAutoresizingMaskIntoConstraints = false
    spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

    embedPreviewContainer.addArrangedSubview(embedPreviewImageView)
    embedPreviewContainer.addArrangedSubview(embedPreviewTitleLabel)
    embedPreviewContainer.addArrangedSubview(spacer)
    embedPreviewContainer.addArrangedSubview(embedPreviewDismissButton)
  }

  private func updateEmbedPreview() {
    let showEmbed = hasEmbed
    embedPreviewContainer.isHidden = !showEmbed

    contentStackTopWithoutEmbed.isActive = !showEmbed
    contentStackTopWithEmbed.isActive = showEmbed

    if let image = embedPreviewImage {
      embedPreviewImageView.image = image
    } else {
      embedPreviewImageView.image = UIImage(systemName: "photo")
      embedPreviewImageView.tintColor = .secondaryLabel
    }

    UIView.animate(withDuration: 0.2, delay: 0, options: .curveEaseInOut) {
      self.layoutIfNeeded()
      self.superview?.layoutIfNeeded()
    } completion: { _ in
      self.notifyHeightChange()
    }
  }

  // MARK: - Private Helpers

  private func updatePlaceholderVisibility() {
    placeholderLabel.isHidden = !textView.text.isEmpty
  }

  private func updateSendButtonState() {
    let hasText = !(textView.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    let canSend = hasText || hasEmbed
    sendButton.isEnabled = canSend
    sendButton.alpha = canSend ? 1.0 : 0.5

    var config = sendButton.configuration
    config?.baseBackgroundColor = canSend ? .tintColor : .secondarySystemFill
    sendButton.configuration = config

    updateRightButton()
  }

  private func updateRightButton() {
    let hasText = !(textView.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    let showSend = hasText || hasEmbed
    // Show send button when there's text or embed, voice button when empty
    sendButton.isHidden = !showSend
    voiceButton.isHidden = showSend

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
