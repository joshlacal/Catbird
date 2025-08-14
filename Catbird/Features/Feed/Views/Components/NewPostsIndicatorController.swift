//
//  NewPostsIndicatorController.swift
//  Catbird
//
//  Bridges UICollectionView scrolling + data diff events to SwiftUI NewPostsIndicator.
//
//  Usage:
//  1. Own an instance (strong) alongside your feed collection view.
//  2. Call `notifyNewPosts(count:avatars:)` when a refresh detects new posts above current viewport.
//  3. Call `attach(to:)` after collectionView is set up.
//  4. Provide `indicatorHostView` (a UIHostingController's view) overlaying collection view.
//
//  The controller throttles indicator presentation so it feels responsive not spammy.
//

import SwiftUI
import UIKit

final class NewPostsIndicatorController: NSObject {
  private weak var collectionView: UICollectionView?
  private var hostingController: UIHostingController<NewPostsIndicator>?
  private var containerView: UIView?

  private var currentCount: Int = 0
  private var avatarURLs: [String] = []

  // Configuration
  var minVerticalOffsetToShow: CGFloat = 160
  var scrollDismissThreshold: CGFloat = 80  // if user scrolls near top, dismiss

  // Cooldown to avoid rapid flicker
  private var lastShowDate: Date = .distantPast
  var minSecondsBetweenShows: TimeInterval = 4

  // Inject activation callback (e.g., scroll to top / load new posts)
  var onActivate: (() -> Void)?

  init(onActivate: (() -> Void)? = nil) {
    self.onActivate = onActivate
  }

  func attach(to collectionView: UICollectionView, in parent: UIViewController) {
    self.collectionView = collectionView

    // Create container overlay if needed
    let overlay = UIView()
    overlay.translatesAutoresizingMaskIntoConstraints = false
    overlay.isUserInteractionEnabled = true
    parent.view.addSubview(overlay)

    NSLayoutConstraint.activate([
      overlay.leadingAnchor.constraint(equalTo: parent.view.leadingAnchor),
      overlay.trailingAnchor.constraint(equalTo: parent.view.trailingAnchor),
      overlay.topAnchor.constraint(equalTo: parent.view.safeAreaLayoutGuide.topAnchor),
      // Height small; we only need tap area for indicator.
      overlay.heightAnchor.constraint(equalToConstant: 60),
    ])

    self.containerView = overlay

    collectionView.addObserver(
      self, forKeyPath: #keyPath(UICollectionView.contentOffset), options: [.new, .initial],
      context: nil)
  }

  deinit {
    if let cv = collectionView {
      cv.removeObserver(self, forKeyPath: #keyPath(UICollectionView.contentOffset))
    }
  }

  // MARK: - Public API

  func notifyNewPosts(count: Int, avatars: [String]) {
    guard count > 0 else {
      dismiss()
      return
    }
    currentCount = count
    avatarURLs = avatars
    showIfEligible()
  }

  // MARK: - Observation

  override func observeValue(
    forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey: Any]?,
    context: UnsafeMutableRawPointer?
  ) {
    guard keyPath == #keyPath(UICollectionView.contentOffset), let cv = collectionView else {
      return
    }
    let offsetY = cv.contentOffset.y + cv.adjustedContentInset.top

    // If user comes near top, dismiss early
    if offsetY < scrollDismissThreshold { dismiss() }
  }

  // MARK: - Presentation Logic

  private func showIfEligible() {
    guard let cv = collectionView, let container = containerView else { return }
    let offsetY = cv.contentOffset.y + cv.adjustedContentInset.top
    guard offsetY > minVerticalOffsetToShow else { return }
    guard Date().timeIntervalSince(lastShowDate) > minSecondsBetweenShows else { return }

    lastShowDate = Date()
    presentIndicator(in: container)
  }

  private func presentIndicator(in container: UIView) {
    if hostingController != nil {  // update existing
      updateHosting()
      return
    }

    let indicator = NewPostsIndicator(
      newPostsCount: currentCount,
      authorAvatars: avatarURLs,
      onActivate: { [weak self] in
        self?.onActivate?()
        self?.dismiss()
      }
    )

    let hc = UIHostingController(rootView: indicator)
    hc.view.translatesAutoresizingMaskIntoConstraints = false
    hc.view.backgroundColor = .clear
    container.addSubview(hc.view)
    NSLayoutConstraint.activate([
      hc.view.centerXAnchor.constraint(equalTo: container.centerXAnchor),
      hc.view.centerYAnchor.constraint(equalTo: container.centerYAnchor),
    ])

    hostingController = hc
  }

  private func updateHosting() {
    hostingController?.rootView = NewPostsIndicator(
      newPostsCount: currentCount,
      authorAvatars: avatarURLs,
      onActivate: { [weak self] in
        self?.onActivate?()
        self?.dismiss()
      }
    )
  }

  func dismiss() {
    guard let hc = hostingController else { return }
    UIView.animate(
      withDuration: 0.18,
      animations: {
        hc.view.alpha = 0
        hc.view.transform = CGAffineTransform(scaleX: 0.8, y: 0.8)
      },
      completion: { [weak self] _ in
        hc.view.removeFromSuperview()
        self?.hostingController = nil
      })
  }
}
