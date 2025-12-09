//
//  ViewportPredictor.swift
//
//  Predicts future viewport position based on scroll velocity.
//
//  The predictor tracks scroll velocity to pre-tokenize content before it
//  becomes visible, enabling smooth scrolling with instant highlighting.
//

import Foundation
import QuartzCore

/// Predicts future viewport position based on scroll velocity.
///
/// By tracking scroll velocity, we can pre-tokenize content that will likely
/// become visible soon, ensuring highlighting is ready before the user sees it.
@MainActor
final class ViewportPredictor {

  // MARK: - Configuration

  /// How far into the future to predict (seconds).
  private let predictionTime: TimeInterval = 0.15

  /// Additional buffer of lines to pre-tokenize.
  private let bufferLines: Int = 30

  /// Minimum velocity to consider for prediction (points/second).
  private let minimumVelocity: CGFloat = 50

  /// Maximum time between scroll updates before velocity resets (seconds).
  private let velocityTimeout: TimeInterval = 0.2

  // MARK: - State

  /// Current scroll velocity (points/second, positive = scrolling down).
  private(set) var scrollVelocity: CGFloat = 0

  /// Last scroll offset.
  private var lastScrollOffset: CGFloat = 0

  /// Time of last scroll update.
  private var lastScrollTime: CFTimeInterval = 0

  /// Line height for converting points to lines.
  private var lineHeight: CGFloat = 14

  // MARK: - Initialization

  init(lineHeight: CGFloat = 14) {
    self.lineHeight = lineHeight
  }

  // MARK: - Public API

  /// Update the line height (call when font changes).
  func setLineHeight(_ height: CGFloat) {
    lineHeight = max(1, height)
  }

  /// Update scroll position tracking.
  ///
  /// Call this on every scroll event to track velocity.
  ///
  /// - Parameter scrollOffset: Current vertical scroll offset in points.
  func update(scrollOffset: CGFloat) {
    let now = CACurrentMediaTime()
    let dt = now - lastScrollTime

    if dt > 0 && dt < velocityTimeout {
      // Calculate velocity with some smoothing
      let newVelocity = (scrollOffset - lastScrollOffset) / CGFloat(dt)
      scrollVelocity = scrollVelocity * 0.3 + newVelocity * 0.7
    } else {
      // Too much time passed, reset velocity
      scrollVelocity = 0
    }

    lastScrollOffset = scrollOffset
    lastScrollTime = now
  }

  /// Predict the viewport that will be visible in the near future.
  ///
  /// - Parameters:
  ///   - currentViewport: Currently visible line range.
  ///   - totalLines: Total number of lines in the document.
  /// - Returns: Expanded line range that should be pre-tokenized.
  func predictedViewport(current currentViewport: Range<Int>, totalLines: Int) -> Range<Int> {
    // Always include buffer around current viewport
    let baseStart = max(0, currentViewport.lowerBound - bufferLines)
    let baseEnd = min(totalLines, currentViewport.upperBound + bufferLines)

    // If velocity is too low, just use the buffered viewport
    guard abs(scrollVelocity) > minimumVelocity else {
      return baseStart..<baseEnd
    }

    // Predict position based on velocity
    let predictedOffset = scrollVelocity * CGFloat(predictionTime)
    let lineDelta = Int(predictedOffset / lineHeight)

    if lineDelta > 0 {
      // Scrolling down - extend end of range
      let predictedEnd = min(totalLines, baseEnd + lineDelta)
      return baseStart..<predictedEnd
    } else {
      // Scrolling up - extend start of range
      let predictedStart = max(0, baseStart + lineDelta)
      return predictedStart..<baseEnd
    }
  }

  /// Get the scroll direction.
  var scrollDirection: ScrollDirection {
    if scrollVelocity > minimumVelocity {
      return .down
    } else if scrollVelocity < -minimumVelocity {
      return .up
    } else {
      return .stationary
    }
  }

  /// Reset velocity tracking (e.g., on programmatic scroll).
  func reset() {
    scrollVelocity = 0
    lastScrollTime = 0
  }

  // MARK: - Types

  enum ScrollDirection {
    case up
    case down
    case stationary
  }
}
