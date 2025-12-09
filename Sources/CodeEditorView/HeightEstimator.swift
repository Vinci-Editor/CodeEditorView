//
//  HeightEstimator.swift
//
//  Provides instant document height estimation for monospaced fonts.
//  Eliminates the need for full document layout on initial load.
//

import Foundation

#if os(iOS) || os(visionOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// Provides instant document height estimation for monospaced fonts.
///
/// For monospaced fonts without word wrap:
/// - Height = lineCount * lineHeight
/// - No layout required - calculation is exact
///
/// For word wrap enabled:
/// - Uses lineCount * lineHeight as initial estimate
/// - Progressively refines with actual layout measurements
///
@MainActor
final class HeightEstimator {

  /// Configuration for height estimation.
  ///
  struct Configuration: Equatable {
    let font: OSFont
    let wrapText: Bool
    let containerWidth: CGFloat
    let minimapRatio: CGFloat

    /// The line height for the configured font.
    ///
    var lineHeight: CGFloat { font.lineHeight }

    /// The minimap line height (scaled down by minimapRatio).
    ///
    var minimapLineHeight: CGFloat { lineHeight / minimapRatio }

    /// The character width for monospaced fonts.
    ///
    var characterWidth: CGFloat { font.maximumHorizontalAdvancement }

    static func == (lhs: Configuration, rhs: Configuration) -> Bool {
      lhs.font == rhs.font &&
      lhs.wrapText == rhs.wrapText &&
      abs(lhs.containerWidth - rhs.containerWidth) < 1.0 &&
      lhs.minimapRatio == rhs.minimapRatio
    }
  }

  private var config: Configuration

  /// For progressive refinement when word wrap is enabled.
  /// Maps line index to measured height.
  ///
  private var measuredLineHeights: [Int: CGFloat] = [:]

  /// Tracks the total delta from measured heights vs estimated.
  /// Used to quickly adjust overall height without summing all measurements.
  ///
  private var heightDelta: CGFloat = 0

  /// Number of lines with measurements recorded.
  ///
  private var measuredLineCount: Int = 0

  // MARK: - Initialization

  init(config: Configuration) {
    self.config = config
  }

  // MARK: - Height Estimation

  /// Instantly estimate document height based on line count.
  ///
  /// - Parameter lineCount: The number of lines in the document.
  /// - Returns: Estimated document height in points.
  ///
  func estimatedHeight(for lineCount: Int) -> CGFloat {
    if config.wrapText && measuredLineCount > 0 {
      // With word wrap and measurements, use adjusted estimate
      return estimateWithWordWrap(lineCount: lineCount)
    } else {
      // Without word wrap (or no measurements yet), calculation is exact
      return CGFloat(lineCount) * config.lineHeight
    }
  }

  /// Instantly estimate minimap height based on line count.
  ///
  /// - Parameter lineCount: The number of lines in the document.
  /// - Returns: Estimated minimap height in points.
  ///
  func estimatedMinimapHeight(for lineCount: Int) -> CGFloat {
    return CGFloat(lineCount) * config.minimapLineHeight
  }

  // MARK: - Progressive Refinement (Word Wrap)

  /// Record actual measured height for a line (for word-wrap refinement).
  ///
  /// - Parameters:
  ///   - height: The actual measured height of the line.
  ///   - line: The line index (0-based).
  ///
  func recordMeasuredHeight(_ height: CGFloat, for line: Int) {
    guard config.wrapText else { return }

    let expectedHeight = config.lineHeight
    let oldMeasurement = measuredLineHeights[line]

    if let old = oldMeasurement {
      // Update existing measurement
      heightDelta -= (old - expectedHeight)
      heightDelta += (height - expectedHeight)
    } else {
      // New measurement
      heightDelta += (height - expectedHeight)
      measuredLineCount += 1
    }

    measuredLineHeights[line] = height
  }

  /// Remove measurement for a line (when line is deleted).
  ///
  /// - Parameter line: The line index to remove.
  ///
  func removeMeasurement(for line: Int) {
    guard let height = measuredLineHeights.removeValue(forKey: line) else { return }
    heightDelta -= (height - config.lineHeight)
    measuredLineCount -= 1
  }

  // MARK: - Configuration Updates

  /// Update configuration when font/layout changes.
  ///
  /// - Parameter newConfig: The new configuration.
  ///
  func updateConfiguration(_ newConfig: Configuration) {
    guard config != newConfig else { return }
    config = newConfig
    invalidateCache()
  }

  /// Invalidate cached measurements (called on text change or config change).
  ///
  func invalidateCache() {
    measuredLineHeights.removeAll(keepingCapacity: true)
    heightDelta = 0
    measuredLineCount = 0
  }

  /// Shift line measurements after an edit.
  ///
  /// - Parameters:
  ///   - startLine: The line where the edit started.
  ///   - delta: The number of lines inserted (positive) or deleted (negative).
  ///
  func shiftMeasurements(from startLine: Int, by delta: Int) {
    guard delta != 0, !measuredLineHeights.isEmpty else { return }

    // Build new dictionary with shifted keys
    var newMeasurements: [Int: CGFloat] = [:]

    for (line, height) in measuredLineHeights {
      if line < startLine {
        // Lines before edit are unchanged
        newMeasurements[line] = height
      } else if delta > 0 {
        // Lines after insertion shift down
        newMeasurements[line + delta] = height
      } else if line >= startLine - delta {
        // Lines after deletion shift up (only if not deleted)
        newMeasurements[line + delta] = height
      }
      // Lines in deleted range are dropped
    }

    measuredLineHeights = newMeasurements
  }

  // MARK: - Private

  private func estimateWithWordWrap(lineCount: Int) -> CGFloat {
    // Base estimate + accumulated delta from measurements
    let baseEstimate = CGFloat(lineCount) * config.lineHeight
    return baseEstimate + heightDelta
  }
}
