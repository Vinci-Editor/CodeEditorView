//
//  TokenizationCoordinator.swift
//
//  Coordinates viewport-based tokenization to improve performance for large files.
//

import Foundation

#if os(iOS) || os(visionOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// Coordinates viewport-based tokenization for improved performance with large files.
///
/// Instead of tokenizing the entire document upfront, this coordinator:
/// 1. Tracks which lines are visible in the viewport
/// 2. Prioritizes tokenization of visible lines
/// 3. Schedules background tokenization for non-visible content
///
@MainActor
final class TokenizationCoordinator {

  /// Priority levels for tokenization work.
  ///
  enum Priority: Int, Comparable {
    case visible = 0      // Currently visible in viewport
    case buffer = 1       // Buffer around viewport for smooth scrolling
    case background = 2   // Everything else

    static func < (lhs: Priority, rhs: Priority) -> Bool {
      lhs.rawValue < rhs.rawValue
    }
  }

  /// A region of lines pending tokenization.
  ///
  struct TokenizationRegion {
    let lines: Range<Int>
    let priority: Priority
  }

  /// Reference to the code storage delegate that performs actual tokenization.
  ///
  weak var codeStorageDelegate: CodeStorageDelegate?

  /// Reference to the text storage.
  ///
  weak var textStorage: NSTextStorage?

  /// Callback to trigger re-rendering after tokenization.
  ///
  var triggerRedraw: ((NSRange) -> Void)?

  /// Lines currently visible in the viewport.
  ///
  private var visibleLines: Range<Int> = 0..<0

  /// Number of lines to pre-tokenize around the viewport.
  ///
  private let bufferSize: Int = 100

  /// Background tokenization task.
  ///
  private var backgroundTask: Task<Void, Never>?

  /// Minimum number of lines to process in a single chunk.
  ///
  private let chunkSize: Int = 50

  /// Threshold for enabling deferred tokenization (in characters).
  ///
  private let deferredTokenizationThreshold: Int = 50000  // ~1000+ lines

  // MARK: - Initialization

  init() {}

  // MARK: - Viewport Updates

  /// Called when the viewport changes to update tokenization priorities.
  ///
  /// - Parameters:
  ///   - startLine: First visible line.
  ///   - endLine: Last visible line.
  ///
  func viewportDidChange(startLine: Int, endLine: Int) {
    let newVisibleLines = startLine..<(endLine + 1)

    // Only update if viewport actually changed significantly
    guard newVisibleLines != visibleLines else { return }
    visibleLines = newVisibleLines

    // Check if visible lines need tokenization
    scheduleTokenizationIfNeeded()
  }

  /// Schedule tokenization for untokenized visible lines.
  ///
  private func scheduleTokenizationIfNeeded() {
    guard let delegate = codeStorageDelegate else { return }

    // Find untokenized lines in the visible range
    let untokenizedVisible = untokenizedLines(in: visibleLines, delegate: delegate)

    if !untokenizedVisible.isEmpty {
      // Tokenize visible lines immediately
      tokenizeLines(untokenizedVisible, priority: .visible)
    }

    // Schedule buffer tokenization
    scheduleBufferTokenization()
  }

  /// Schedule tokenization for the buffer around the viewport.
  ///
  private func scheduleBufferTokenization() {
    guard let delegate = codeStorageDelegate else { return }

    let totalLines = delegate.lineMap.lines.count
    let bufferStart = max(0, visibleLines.lowerBound - bufferSize)
    let bufferEnd = min(totalLines, visibleLines.upperBound + bufferSize)

    // Before visible
    if bufferStart < visibleLines.lowerBound {
      let untokenized = untokenizedLines(in: bufferStart..<visibleLines.lowerBound, delegate: delegate)
      if !untokenized.isEmpty {
        scheduleBackgroundTokenization(lines: untokenized, priority: .buffer)
      }
    }

    // After visible
    if bufferEnd > visibleLines.upperBound {
      let untokenized = untokenizedLines(in: visibleLines.upperBound..<bufferEnd, delegate: delegate)
      if !untokenized.isEmpty {
        scheduleBackgroundTokenization(lines: untokenized, priority: .buffer)
      }
    }
  }

  /// Find untokenized lines in a range.
  ///
  private func untokenizedLines(in range: Range<Int>, delegate: CodeStorageDelegate) -> [Range<Int>] {
    var result: [Range<Int>] = []
    var currentStart: Int? = nil

    for line in range {
      guard line < delegate.lineMap.lines.count else { break }

      let info = delegate.lineMap.lines[line].info
      let needsTokenization = info?.tokenizationState != .tokenized

      if needsTokenization {
        if currentStart == nil {
          currentStart = line
        }
      } else {
        if let start = currentStart {
          result.append(start..<line)
          currentStart = nil
        }
      }
    }

    // Close any open range
    if let start = currentStart {
      result.append(start..<range.upperBound)
    }

    return result
  }

  // MARK: - Tokenization

  /// Tokenize lines immediately (for visible content).
  ///
  private func tokenizeLines(_ ranges: [Range<Int>], priority: Priority) {
    guard let delegate = codeStorageDelegate,
          let storage = textStorage
    else { return }

    for lineRange in ranges {
      guard !lineRange.isEmpty else { continue }

      // Get character range for these lines
      let startLine = delegate.lineMap.lines[lineRange.lowerBound]
      let endLine = delegate.lineMap.lines[min(lineRange.upperBound - 1, delegate.lineMap.lines.count - 1)]
      let charRange = NSRange(location: startLine.range.location,
                              length: endLine.range.max - startLine.range.location)

      // Perform tokenization
      let _ = delegate.tokenise(range: charRange, in: storage)

      // Mark lines as tokenized
      delegate.setTokenizationState(.tokenized, for: lineRange)

      // Trigger redraw
      triggerRedraw?(charRange)
    }
  }

  /// Schedule background tokenization for non-visible content.
  ///
  private func scheduleBackgroundTokenization(lines: [Range<Int>], priority: Priority) {
    // Cancel existing background task if priorities changed
    if priority == .visible {
      backgroundTask?.cancel()
    }

    backgroundTask = Task { [weak self] in
      for lineRange in lines {
        guard !Task.isCancelled else { return }

        // Yield to keep UI responsive
        await Task.yield()

        await self?.tokenizeLinesBackground(lineRange)
      }
    }
  }

  /// Tokenize a range of lines in the background.
  ///
  private func tokenizeLinesBackground(_ range: Range<Int>) async {
    guard let delegate = codeStorageDelegate,
          let storage = textStorage
    else { return }

    // Process in chunks
    var current = range.lowerBound
    while current < range.upperBound {
      guard !Task.isCancelled else { return }

      let chunkEnd = min(current + chunkSize, range.upperBound)
      let chunkRange = current..<chunkEnd

      // Get character range for chunk
      guard chunkRange.lowerBound < delegate.lineMap.lines.count else { break }
      let startLine = delegate.lineMap.lines[chunkRange.lowerBound]
      let endLineIndex = min(chunkRange.upperBound - 1, delegate.lineMap.lines.count - 1)
      let endLine = delegate.lineMap.lines[endLineIndex]
      let charRange = NSRange(location: startLine.range.location,
                              length: endLine.range.max - startLine.range.location)

      // Tokenize
      let _ = delegate.tokenise(range: charRange, in: storage)

      // Mark as tokenized
      delegate.setTokenizationState(.tokenized, for: chunkRange)

      // Trigger redraw for this chunk
      triggerRedraw?(charRange)

      current = chunkEnd

      // Yield between chunks
      await Task.yield()
    }
  }

  // MARK: - Initial Load Optimization

  /// Prepare for loading a large document.
  ///
  /// Call this before setting text on large documents to enable deferred tokenization.
  ///
  func prepareForLargeDocument(characterCount: Int) -> Bool {
    return characterCount > deferredTokenizationThreshold
  }

  /// Mark all lines as pending tokenization.
  ///
  func markAllLinesPending() {
    guard let delegate = codeStorageDelegate else { return }

    let allLines = 0..<delegate.lineMap.lines.count
    delegate.setTokenizationState(.pending, for: allLines)
  }

  /// Invalidate tokenization for lines affected by an edit.
  ///
  func invalidateLines(in range: Range<Int>) {
    guard let delegate = codeStorageDelegate else { return }
    delegate.setTokenizationState(.invalidated, for: range)
  }

  // MARK: - Cleanup

  /// Cancel any pending background tokenization.
  ///
  func cancelBackgroundTokenization() {
    backgroundTask?.cancel()
    backgroundTask = nil
  }

  deinit {
    backgroundTask?.cancel()
  }
}
