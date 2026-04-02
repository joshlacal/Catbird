#if os(iOS)
import AVFoundation
import UIKit

// MARK: - Composer Mode

enum ComposerMode: Equatable {
  case compose
  case recording(locked: Bool)
  case preview(duration: TimeInterval, waveform: [Float])

  static func == (lhs: ComposerMode, rhs: ComposerMode) -> Bool {
    switch (lhs, rhs) {
    case (.compose, .compose):
      return true
    case (.recording(let a), .recording(let b)):
      return a == b
    case (.preview(let d1, let w1), .preview(let d2, let w2)):
      return d1 == d2 && w1 == w2
    default:
      return false
    }
  }
}

// MARK: - Composer Delegate

protocol UIKitMLSComposerDelegate: AnyObject {
  func composerDidChangeHeight(_ composer: UIKitMLSComposerView, height: CGFloat)
  func composerDidTapSend(_ composer: UIKitMLSComposerView, text: String)
  func composerDidTapAttach(_ composer: UIKitMLSComposerView)
  func composerDidChangeTypingState(_ composer: UIKitMLSComposerView, isTyping: Bool)
  func composerDidTapPhoto(_ composer: UIKitMLSComposerView)
  func composerDidTapGif(_ composer: UIKitMLSComposerView)
  func composerDidTapSharePost(_ composer: UIKitMLSComposerView)

  // Voice recording lifecycle
  func composerDidStartVoiceRecording(_ composer: UIKitMLSComposerView)
  func composerDidLockVoiceRecording(_ composer: UIKitMLSComposerView)
  func composerDidStopVoiceRecording(_ composer: UIKitMLSComposerView)
  func composerDidCancelVoiceRecording(_ composer: UIKitMLSComposerView)
  func composerDidTapSendVoice(_ composer: UIKitMLSComposerView)
  func composerDidTapDiscardVoice(_ composer: UIKitMLSComposerView)
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

  private(set) var mode: ComposerMode = .compose

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
  private let minRecordingDuration: TimeInterval = 1.0

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
      withConfiguration: UIImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
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

  // MARK: - Recording State Subviews

  private let recordingStack: UIStackView = {
    let stack = UIStackView()
    stack.axis = .horizontal
    stack.alignment = .center
    stack.spacing = 10
    stack.translatesAutoresizingMaskIntoConstraints = false
    stack.isHidden = true
    return stack
  }()

  private lazy var recordingCancelButton: UIButton = {
    var config = UIButton.Configuration.plain()
    config.image = UIImage(
      systemName: "xmark.circle.fill",
      withConfiguration: UIImage.SymbolConfiguration(pointSize: 18, weight: .medium)
    )
    config.baseForegroundColor = .secondaryLabel
    config.contentInsets = .zero
    let button = UIButton(configuration: config)
    button.translatesAutoresizingMaskIntoConstraints = false
    button.accessibilityLabel = "Cancel recording"
    button.addTarget(self, action: #selector(recordingCancelTapped), for: .touchUpInside)
    NSLayoutConstraint.activate([
      button.widthAnchor.constraint(equalToConstant: 30),
      button.heightAnchor.constraint(equalToConstant: 30),
    ])
    return button
  }()

  private let recordingDotView: UIView = {
    let dot = UIView()
    dot.translatesAutoresizingMaskIntoConstraints = false
    dot.backgroundColor = .systemRed
    dot.layer.cornerRadius = 5
    NSLayoutConstraint.activate([
      dot.widthAnchor.constraint(equalToConstant: 10),
      dot.heightAnchor.constraint(equalToConstant: 10),
    ])
    return dot
  }()

  private let recordingDurationLabel: UILabel = {
    let label = UILabel()
    label.font = .monospacedDigitSystemFont(ofSize: 15, weight: .regular)
    label.textColor = .label
    label.text = "0:00"
    label.translatesAutoresizingMaskIntoConstraints = false
    return label
  }()

  private let recordingLockIcon: UIImageView = {
    let iv = UIImageView(image: UIImage(
      systemName: "lock.fill",
      withConfiguration: UIImage.SymbolConfiguration(pointSize: 11, weight: .medium)
    ))
    iv.tintColor = .secondaryLabel
    iv.translatesAutoresizingMaskIntoConstraints = false
    iv.alpha = 0
    return iv
  }()

  private lazy var recordingStopButton: UIButton = {
    var config = UIButton.Configuration.filled()
    config.image = UIImage(
      systemName: "stop.fill",
      withConfiguration: UIImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
    )
    config.baseForegroundColor = .white
    config.baseBackgroundColor = .systemRed
    config.cornerStyle = .capsule
    config.contentInsets = .zero
    let button = UIButton(configuration: config)
    button.translatesAutoresizingMaskIntoConstraints = false
    button.accessibilityLabel = "Stop recording"
    button.addTarget(self, action: #selector(recordingStopTapped), for: .touchUpInside)
    button.isHidden = true
    NSLayoutConstraint.activate([
      button.widthAnchor.constraint(equalToConstant: 30),
      button.heightAnchor.constraint(equalToConstant: 30),
    ])
    return button
  }()

  // MARK: - Preview State Subviews

  private let previewStack: UIStackView = {
    let stack = UIStackView()
    stack.axis = .horizontal
    stack.alignment = .center
    stack.spacing = 8
    stack.translatesAutoresizingMaskIntoConstraints = false
    stack.isHidden = true
    return stack
  }()

  private lazy var previewDiscardButton: UIButton = {
    var config = UIButton.Configuration.plain()
    config.image = UIImage(
      systemName: "trash.fill",
      withConfiguration: UIImage.SymbolConfiguration(pointSize: 14, weight: .medium)
    )
    config.baseForegroundColor = .systemRed
    config.contentInsets = .zero
    let button = UIButton(configuration: config)
    button.translatesAutoresizingMaskIntoConstraints = false
    button.accessibilityLabel = "Discard recording"
    button.addTarget(self, action: #selector(previewDiscardTapped), for: .touchUpInside)
    NSLayoutConstraint.activate([
      button.widthAnchor.constraint(equalToConstant: 30),
      button.heightAnchor.constraint(equalToConstant: 30),
    ])
    return button
  }()

  private lazy var previewPlayButton: UIButton = {
    var config = UIButton.Configuration.plain()
    config.image = UIImage(
      systemName: "play.fill",
      withConfiguration: UIImage.SymbolConfiguration(pointSize: 14, weight: .medium)
    )
    config.baseForegroundColor = .label
    config.contentInsets = .zero
    config.background.backgroundColor = UIColor.label.withAlphaComponent(0.1)
    config.background.cornerRadius = 14
    let button = UIButton(configuration: config)
    button.translatesAutoresizingMaskIntoConstraints = false
    button.accessibilityLabel = "Play preview"
    button.addTarget(self, action: #selector(previewPlayTapped), for: .touchUpInside)
    NSLayoutConstraint.activate([
      button.widthAnchor.constraint(equalToConstant: 28),
      button.heightAnchor.constraint(equalToConstant: 28),
    ])
    return button
  }()

  private let previewWaveformView: ComposerWaveformView = {
    let view = ComposerWaveformView()
    view.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      view.heightAnchor.constraint(equalToConstant: 28),
    ])
    return view
  }()

  private let previewDurationLabel: UILabel = {
    let label = UILabel()
    label.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
    label.textColor = .secondaryLabel
    label.text = "0:00"
    label.translatesAutoresizingMaskIntoConstraints = false
    label.setContentHuggingPriority(.required, for: .horizontal)
    label.setContentCompressionResistancePriority(.required, for: .horizontal)
    return label
  }()

  private lazy var previewSendButton: UIButton = {
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
    button.accessibilityLabel = "Send voice message"
    button.addTarget(self, action: #selector(previewSendTapped), for: .touchUpInside)
    NSLayoutConstraint.activate([
      button.widthAnchor.constraint(equalToConstant: 30),
      button.heightAnchor.constraint(equalToConstant: 30),
    ])
    return button
  }()

  // MARK: - Preview Playback State

  private var previewPlayer: AVAudioPlayer?
  private var previewDisplayLink: CADisplayLink?
  private var isPreviewPlaying = false

  // MARK: - Private Layout State

  private var textViewHeightConstraint: NSLayoutConstraint!
  private var contentStackTopWithoutEmbed: NSLayoutConstraint!
  private var contentStackTopWithEmbed: NSLayoutConstraint!
  private var wasTyping = false
  private var voiceLongPressStartY: CGFloat = 0
  private var hasLockedRecording = false
  private var recordingStartTime: Date?

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

    // Recording stack assembly
    let recordingInfoStack = UIStackView(arrangedSubviews: [
      recordingDotView, recordingDurationLabel, recordingLockIcon,
    ])
    recordingInfoStack.axis = .horizontal
    recordingInfoStack.alignment = .center
    recordingInfoStack.spacing = 8
    recordingInfoStack.translatesAutoresizingMaskIntoConstraints = false

    let recordingSpacer = UIView()
    recordingSpacer.translatesAutoresizingMaskIntoConstraints = false
    recordingSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

    recordingStack.addArrangedSubview(recordingCancelButton)
    recordingStack.addArrangedSubview(recordingInfoStack)
    recordingStack.addArrangedSubview(recordingSpacer)
    recordingStack.addArrangedSubview(recordingStopButton)

    backgroundEffectView.contentView.addSubview(recordingStack)

    // Preview stack assembly
    let previewWaveformContainer = UIView()
    previewWaveformContainer.translatesAutoresizingMaskIntoConstraints = false
    previewWaveformContainer.addSubview(previewWaveformView)
    NSLayoutConstraint.activate([
      previewWaveformView.topAnchor.constraint(equalTo: previewWaveformContainer.topAnchor),
      previewWaveformView.leadingAnchor.constraint(equalTo: previewWaveformContainer.leadingAnchor),
      previewWaveformView.trailingAnchor.constraint(equalTo: previewWaveformContainer.trailingAnchor),
      previewWaveformView.bottomAnchor.constraint(equalTo: previewWaveformContainer.bottomAnchor),
    ])
    previewWaveformContainer.setContentHuggingPriority(.defaultLow, for: .horizontal)
    previewWaveformContainer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

    previewStack.addArrangedSubview(previewDiscardButton)
    previewStack.addArrangedSubview(previewPlayButton)
    previewStack.addArrangedSubview(previewWaveformContainer)
    previewStack.addArrangedSubview(previewDurationLabel)
    previewStack.addArrangedSubview(previewSendButton)

    backgroundEffectView.contentView.addSubview(previewStack)

    // Wire waveform seek to player
    previewWaveformView.onSeek = { [weak self] progress in
      guard let self, let player = self.previewPlayer else { return }
      player.currentTime = Double(progress) * player.duration
    }

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

    // Recording stack constraints
    NSLayoutConstraint.activate([
      recordingStack.leadingAnchor.constraint(equalTo: backgroundEffectView.contentView.leadingAnchor, constant: horizontalPadding),
      recordingStack.trailingAnchor.constraint(equalTo: backgroundEffectView.contentView.trailingAnchor, constant: -horizontalPadding),
      recordingStack.topAnchor.constraint(equalTo: backgroundEffectView.contentView.topAnchor, constant: verticalPadding),
      recordingStack.bottomAnchor.constraint(equalTo: backgroundEffectView.contentView.bottomAnchor, constant: -verticalPadding),
    ])

    // Preview stack constraints
    NSLayoutConstraint.activate([
      previewStack.leadingAnchor.constraint(equalTo: backgroundEffectView.contentView.leadingAnchor, constant: horizontalPadding),
      previewStack.trailingAnchor.constraint(equalTo: backgroundEffectView.contentView.trailingAnchor, constant: -horizontalPadding),
      previewStack.topAnchor.constraint(equalTo: backgroundEffectView.contentView.topAnchor, constant: verticalPadding),
      previewStack.bottomAnchor.constraint(equalTo: backgroundEffectView.contentView.bottomAnchor, constant: -verticalPadding),
    ])
  }

  private func setupActions() {
    sendButton.addTarget(self, action: #selector(sendTapped), for: .touchUpInside)

    // Voice button: long press only (quick tap = no-op)
    let longPress = UILongPressGestureRecognizer(target: self, action: #selector(voiceLongPressed(_:)))
    longPress.minimumPressDuration = 0.3
    voiceButton.addGestureRecognizer(longPress)
  }

  // MARK: - Mode Transitions

  func setMode(_ newMode: ComposerMode, animated: Bool = true) {
    guard newMode != mode else { return }
    mode = newMode

    let duration: TimeInterval = animated && !UIAccessibility.isReduceMotionEnabled ? 0.25 : 0
    let showCompose = newMode == .compose
    let showRecording: Bool
    let showPreview: Bool

    switch newMode {
    case .compose:
      showRecording = false
      showPreview = false
      stopPreviewPlayback()
    case .recording:
      showRecording = true
      showPreview = false
    case .preview(let dur, let waveform):
      showRecording = false
      showPreview = true
      configurePreview(duration: dur, waveform: waveform)
    }

    // Animate glass tint
    if #available(iOS 26.0, *) {
      let glass = UIGlassEffect()
      if case .recording = newMode {
        glass.tintColor = .systemRed
      }
      glass.isInteractive = true
      UIView.animate(withDuration: duration) {
        self.backgroundEffectView.effect = glass
      }
    } else {
      UIView.animate(withDuration: duration) {
        if case .recording = newMode {
          self.backgroundEffectView.contentView.backgroundColor = UIColor.systemRed.withAlphaComponent(0.12)
        } else {
          self.backgroundEffectView.contentView.backgroundColor = .clear
        }
      }
    }

    // Un-hide before animation starts
    if showCompose { contentStack.isHidden = false }
    if showRecording { recordingStack.isHidden = false }
    if showPreview { previewStack.isHidden = false }

    // Cross-fade subview groups
    UIView.animate(withDuration: duration) {
      self.contentStack.alpha = showCompose ? 1 : 0
      self.embedPreviewContainer.alpha = showCompose && self.hasEmbed ? 1 : 0
      self.recordingStack.alpha = showRecording ? 1 : 0
      self.previewStack.alpha = showPreview ? 1 : 0
    } completion: { _ in
      self.contentStack.isHidden = !showCompose
      self.embedPreviewContainer.isHidden = !(showCompose && self.hasEmbed)
      self.recordingStack.isHidden = !showRecording
      self.previewStack.isHidden = !showPreview
      self.notifyHeightChange()
    }

    // Update recording-specific UI
    if case .recording(let locked) = newMode {
      recordingStopButton.isHidden = !locked
      UIView.animate(withDuration: duration) {
        self.recordingLockIcon.alpha = locked ? 1 : 0
      }
      if locked {
        UIAccessibility.post(notification: .announcement, argument: "Recording locked")
      } else {
        UIAccessibility.post(notification: .announcement, argument: "Recording")
      }
      startPulseAnimation()
    } else {
      stopPulseAnimation()
    }
  }

  /// Called by the parent to update the recording duration display.
  func updateRecordingDuration(_ duration: TimeInterval) {
    let minutes = Int(duration) / 60
    let seconds = Int(duration) % 60
    recordingDurationLabel.text = String(format: "%d:%02d", minutes, seconds)
  }

  /// Load a WAV file for preview playback.
  func loadPreviewAudio(url: URL) {
    guard previewPlayer == nil else { return }
    do {
      let player = try AVAudioPlayer(contentsOf: url)
      player.prepareToPlay()
      previewPlayer = player
    } catch {
      previewPlayer = nil
    }
  }

  // MARK: - Actions

  @objc private func voiceLongPressed(_ gesture: UILongPressGestureRecognizer) {
    switch gesture.state {
    case .began:
      voiceLongPressStartY = gesture.location(in: self).y
      hasLockedRecording = false
      recordingStartTime = Date()
      delegate?.composerDidStartVoiceRecording(self)

    case .changed:
      guard !hasLockedRecording else { return }
      let currentY = gesture.location(in: self).y
      let delta = voiceLongPressStartY - currentY
      if delta > 60 {
        hasLockedRecording = true
        delegate?.composerDidLockVoiceRecording(self)
      }

    case .ended:
      if !hasLockedRecording {
        let elapsed = Date().timeIntervalSince(recordingStartTime ?? Date())
        if elapsed < minRecordingDuration {
          // Too short — silently discard
          delegate?.composerDidCancelVoiceRecording(self)
        } else {
          delegate?.composerDidStopVoiceRecording(self)
        }
      }

    case .cancelled, .failed:
      if !hasLockedRecording {
        delegate?.composerDidCancelVoiceRecording(self)
      }

    default:
      break
    }
  }

  @objc private func recordingCancelTapped() {
    delegate?.composerDidCancelVoiceRecording(self)
  }

  @objc private func recordingStopTapped() {
    delegate?.composerDidStopVoiceRecording(self)
  }

  @objc private func previewPlayTapped() {
    if isPreviewPlaying {
      stopPreviewPlayback()
    } else {
      startPreviewPlayback()
    }
  }

  @objc private func previewDiscardTapped() {
    stopPreviewPlayback()
    previewPlayer = nil
    delegate?.composerDidTapDiscardVoice(self)
  }

  @objc private func previewSendTapped() {
    stopPreviewPlayback()
    previewPlayer = nil
    delegate?.composerDidTapSendVoice(self)
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

  // MARK: - Preview Playback

  private func configurePreview(duration: TimeInterval, waveform: [Float]) {
    let minutes = Int(duration) / 60
    let seconds = Int(duration) % 60
    previewDurationLabel.text = String(format: "%d:%02d", minutes, seconds)
    previewWaveformView.setWaveform(waveform, progress: 0)
    updatePreviewPlayButton(playing: false)
  }

  private func startPreviewPlayback() {
    guard let player = previewPlayer else { return }
    do {
      let session = AVAudioSession.sharedInstance()
      try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
      try session.setActive(true, options: [])
    } catch {}

    player.play()
    isPreviewPlaying = true
    updatePreviewPlayButton(playing: true)
    startPreviewDisplayLink()
  }

  func stopPreviewPlayback() {
    previewPlayer?.pause()
    isPreviewPlaying = false
    updatePreviewPlayButton(playing: false)
    stopPreviewDisplayLink()
  }

  private func updatePreviewPlayButton(playing: Bool) {
    var config = previewPlayButton.configuration
    config?.image = UIImage(
      systemName: playing ? "pause.fill" : "play.fill",
      withConfiguration: UIImage.SymbolConfiguration(pointSize: 14, weight: .medium)
    )
    previewPlayButton.configuration = config
    previewPlayButton.accessibilityLabel = playing ? "Pause preview" : "Play preview"
  }

  private func startPreviewDisplayLink() {
    let link = CADisplayLink(target: DisplayLinkProxy { [weak self] in
      self?.updatePreviewProgress()
    }, selector: #selector(DisplayLinkProxy.tick))
    link.preferredFrameRateRange = CAFrameRateRange(minimum: 15, maximum: 30)
    link.add(to: .main, forMode: .common)
    previewDisplayLink = link
  }

  private func stopPreviewDisplayLink() {
    previewDisplayLink?.invalidate()
    previewDisplayLink = nil
  }

  private func updatePreviewProgress() {
    guard let player = previewPlayer else { return }
    if player.isPlaying {
      let progress = player.duration > 0 ? player.currentTime / player.duration : 0
      previewWaveformView.setProgress(Float(progress))
      let remaining = player.duration - player.currentTime
      let m = Int(remaining) / 60
      let s = Int(remaining) % 60
      previewDurationLabel.text = String(format: "%d:%02d", m, s)
    } else if isPreviewPlaying {
      isPreviewPlaying = false
      updatePreviewPlayButton(playing: false)
      stopPreviewDisplayLink()
      previewWaveformView.setProgress(0)
      if let dur = previewPlayer?.duration {
        let m = Int(dur) / 60
        let s = Int(dur) % 60
        previewDurationLabel.text = String(format: "%d:%02d", m, s)
      }
    }
  }

  // MARK: - Pulse Animation

  private func startPulseAnimation() {
    recordingDotView.alpha = 1
    UIView.animate(
      withDuration: 0.8,
      delay: 0,
      options: [.repeat, .autoreverse, .allowUserInteraction]
    ) {
      self.recordingDotView.alpha = 0.3
    }
  }

  private func stopPulseAnimation() {
    recordingDotView.layer.removeAllAnimations()
    recordingDotView.alpha = 1
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
    sendButton.isHidden = !showSend
    voiceButton.isHidden = showSend
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

// MARK: - DisplayLink Proxy

private final class DisplayLinkProxy: NSObject {
  let callback: () -> Void
  init(_ callback: @escaping () -> Void) {
    self.callback = callback
  }
  @objc func tick() {
    callback()
  }
}
#endif
