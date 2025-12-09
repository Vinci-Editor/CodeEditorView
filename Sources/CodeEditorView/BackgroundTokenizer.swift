//
//  BackgroundTokenizer.swift
//
//  Continuous background tokenization with viewport-based prioritization.
//
//  The BackgroundTokenizer runs a continuous loop that:
//  1. Gets pending lines prioritized by viewport proximity
//  2. Tokenizes them using the existing CodeStorageDelegate.tokenise() infrastructure
//  3. Triggers UI refresh for tokenized lines
//
//  This integrates with the existing lineMap-based token storage rather than
//  introducing a parallel TokenCache, keeping the architecture simple.
//

import Foundation
import os

#if os(iOS) || os(visionOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

import LanguageSupport

private let logger = Logger(subsystem: "org.justtesting.CodeEditorView", category: "BackgroundTokenizer")

/// Continuous background tokenization with viewport-based prioritization.
///
/// This tokenizer works with the existing CodeStorageDelegate infrastructure,
/// calling tokenise() to populate the lineMap with token data.
@MainActor
final class BackgroundTokenizer {

  // MARK: - Configuration

  /// Number of lines to process in each batch.
  private let batchSize: Int = 20

  /// Delay between batches when processing background lines (seconds).
  private let backgroundDelay: TimeInterval = 0.05

  /// Delay between checks when all lines are tokenized (seconds).
  private let idleDelay: TimeInterval = 0.1

  /// Delay after user stops typing before resuming tokenization (seconds).
  private let typingCooldownDelay: TimeInterval = 0.15

  /// Buffer size around viewport for pre-tokenization.
  let bufferSize: Int = 50

  /// Timestamp of last edit - used to pause tokenization during active typing.
  private var lastEditTime: CFAbsoluteTime = 0

  // MARK: - Dependencies

  /// Reference to the code storage delegate that performs actual tokenization.
  weak var codeStorageDelegate: CodeStorageDelegate?

  /// Reference to the text storage.
  weak var textStorage: NSTextStorage?

  /// Callback to trigger UI refresh after tokenization.
  var triggerRedraw: ((NSRange) -> Void)?

  /// Provider for current viewport line range.
  var viewportProvider: (() -> Range<Int>)?

  // MARK: - State

  /// Main tokenization task.
  private var tokenizationTask: Task<Void, Never>?

  /// Whether the tokenizer is running.
  private(set) var isRunning: Bool = false

  /// Lines currently visible in the viewport.
  private var visibleLines: Range<Int> = 0..<0

  /// Priority viewport (may include predicted lines).
  private var priorityViewport: Range<Int> = 0..<0

  // MARK: - Initialization

  init() {}

  deinit {
    tokenizationTask?.cancel()
  }

  // MARK: - Public API

  /// Start the background tokenization loop.
  func start() {
    guard !isRunning else { return }
    isRunning = true

    tokenizationTask = Task { [weak self] in
      await self?.tokenizationLoop()
    }

    logger.info("Background tokenizer started")
  }

  /// Stop the background tokenization.
  func stop() {
    isRunning = false
    tokenizationTask?.cancel()
    tokenizationTask = nil
    logger.info("Background tokenizer stopped")
  }

  /// Update the visible viewport.
  func viewportDidChange(startLine: Int, endLine: Int) {
    let newVisibleLines = startLine..<(endLine + 1)
    guard newVisibleLines != visibleLines else { return }
    visibleLines = newVisibleLines
  }

  /// Set priority viewport (e.g., from ViewportPredictor).
  func setPriorityViewport(_ viewport: Range<Int>) {
    priorityViewport = viewport
  }

  /// Mark lines as needing tokenization after an edit.
  func invalidateLines(_ lines: Range<Int>) {
    codeStorageDelegate?.setTokenizationState(.invalidated, for: lines)
    // Record edit time to pause background tokenization during active typing
    lastEditTime = CFAbsoluteTimeGetCurrent()
  }

  /// Notify the tokenizer that an edit occurred. Call this on every text change
  /// to pause background tokenization during active typing.
  func notifyEdit() {
    lastEditTime = CFAbsoluteTimeGetCurrent()
  }

  /// Mark all lines as pending (e.g., for initial load or language change).
  func markAllLinesPending() {
    guard let delegate = codeStorageDelegate else { return }
    let allLines = 0..<delegate.lineMap.lines.count
    delegate.setTokenizationState(.pending, for: allLines)
  }

  // MARK: - Tokenization Loop

  private func tokenizationLoop() async {
    while !Task.isCancelled && isRunning {
      guard let delegate = codeStorageDelegate,
            let storage = textStorage
      else {
        try? await Task.sleep(for: .milliseconds(Int(idleDelay * 1000)))
        continue
      }

      // PERFORMANCE: Pause tokenization during active typing to avoid micro-hangs.
      // Wait until user has stopped typing for typingCooldownDelay before processing.
      let timeSinceLastEdit = CFAbsoluteTimeGetCurrent() - lastEditTime
      if timeSinceLastEdit < typingCooldownDelay {
        // User is actively typing - wait and check again
        try? await Task.sleep(for: .milliseconds(Int(typingCooldownDelay * 1000)))
        continue
      }

      // Use priority viewport if set, otherwise use visible lines
      let effectiveViewport = priorityViewport.isEmpty ? visibleLines : priorityViewport

      // Find untokenized lines, prioritizing viewport (limit scan for performance)
      let pendingLines = findPendingLines(delegate: delegate, viewport: effectiveViewport)

      if pendingLines.isEmpty {
        // No work to do, wait briefly before checking again
        try? await Task.sleep(for: .milliseconds(Int(idleDelay * 1000)))
        continue
      }

      // Tokenize a batch of lines
      let batch = Array(pendingLines.prefix(batchSize))
      let tokenizedRange = tokenizeBatch(batch, delegate: delegate, storage: storage)

      if let range = tokenizedRange {
        // Trigger redraw for tokenized lines
        triggerRedraw?(range)
      }

      // Yield to keep UI responsive
      await Task.yield()

      // Delay between batches to avoid hogging the main thread
      try? await Task.sleep(for: .milliseconds(Int(backgroundDelay * 1000)))
    }
  }

  /// Find pending lines, prioritized by distance from viewport.
  /// - Note: For performance, we limit the scan to viewport + 2x buffer. Lines outside this
  ///         range will be picked up in subsequent passes as the viewport moves.
  private func findPendingLines(delegate: CodeStorageDelegate, viewport: Range<Int>) -> [Int] {
    let totalLines = delegate.lineMap.lines.count
    guard totalLines > 0 else { return [] }

    // PERFORMANCE: Only scan viewport + extended buffer, not the entire document.
    // This keeps findPendingLines O(buffer) instead of O(document).
    let extendedBuffer = bufferSize * 2
    let scanStart = max(0, viewport.lowerBound - extendedBuffer)
    let scanEnd = min(totalLines, viewport.upperBound + extendedBuffer)

    var pending: [(line: Int, priority: Int)] = []
    pending.reserveCapacity(scanEnd - scanStart)

    for line in scanStart..<scanEnd {
      let info = delegate.lineMap.lines[line].info
      guard info?.tokenizationState != .tokenized else { continue }

      // Calculate priority based on distance from viewport
      let priority: Int
      if viewport.contains(line) {
        priority = 0 // Highest priority
      } else {
        let distance = min(
          abs(line - viewport.lowerBound),
          abs(line - viewport.upperBound)
        )
        priority = distance
      }

      pending.append((line, priority))
    }

    // Sort by priority and return lines
    return pending.sorted { $0.priority < $1.priority }.map { $0.line }
  }

  /// Tokenize a batch of lines.
  /// - Note: Uses limited trailing line processing to prevent a single tokenize call from cascading
  ///         through the entire file (e.g., when editing inside multi-line comments).
  ///         The background tokenizer will eventually process all affected lines across multiple batches.
  private func tokenizeBatch(_ lines: [Int], delegate: CodeStorageDelegate, storage: NSTextStorage) -> NSRange? {
    guard !lines.isEmpty else { return nil }

    var affectedRange: NSRange?

    for line in lines {
      guard line < delegate.lineMap.lines.count else { continue }

      let lineEntry = delegate.lineMap.lines[line]
      let charRange = lineEntry.range

      // Perform tokenization for this line with limited trailing to prevent blocking
      // The background tokenizer will handle remaining lines in subsequent batches
      let (highlightingRange, _) = delegate.tokenise(range: charRange, in: storage, maxTrailingLines: 20)

      // Mark line as tokenized
      delegate.setTokenizationState(.tokenized, for: line..<(line + 1))

      // Expand affected range
      if let existing = affectedRange {
        affectedRange = NSUnionRange(existing, highlightingRange)
      } else {
        affectedRange = highlightingRange
      }
    }

    return affectedRange
  }
}
