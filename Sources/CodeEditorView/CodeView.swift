//
//  CodeView.swift
//  
//
//  Created by Manuel M T Chakravarty on 05/05/2021.
//
//  This file contains both the macOS and iOS versions of the subclass for `NSTextView` and `UITextView`, respectively,
//  which forms the heart of the code editor.

import os
import Combine
import SwiftUI
@preconcurrency import ObjectiveC

import Rearrange

import LanguageSupport


private let logger = Logger(subsystem: "org.justtesting.CodeEditorView", category: "CodeView")


// MARK: -
// MARK: Message info

/// Information required to layout message views.
///
/// NB: This information is computed incrementally. We get the `lineFragementRect` from the text container during the
///     line fragment computations. This indicates that the message layout may have to change (if it was already
///     computed), but at this point, we cannot determine the new geometry yet; hence, `geometry` will be `nil`.
///     The `geometry` will be determined after text layout is complete. We get the `characterIndex` also from the text
///     container during line fragment computations.
///
struct MessageInfo {
  let view:                    StatefulMessageView.HostingView
  let backgroundView:          CodeBackgroundHighlightView
  var characterIndex:          Int                    // The starting character index for the line hosting the message
  var telescope:               Int?                   // The number of telescope lines (i.e., beyond starting line)
  var characterIndexTelescope: Int?                   // The last index of the last line of the telescope lines (if any)
  var lineFragementRect:       CGRect                 // The *full* line fragement rectangle (incl. message)
  var geometry:                MessageView.Geometry?
  var colour:                  OSColor                // The category colour of the most severe category
  var invalidated:             Bool                   // Greyed out and doesn't display a telescope

  var topAnchorConstraint:   NSLayoutConstraint?
  var rightAnchorConstraint: NSLayoutConstraint?
}

/// Dictionary of message views.
///
typealias MessageViews = [LineInfo.MessageBundle.ID: MessageInfo]


#if os(iOS) || os(visionOS)

// MARK: -
// MARK: UIKit version

/// `UITextView` with a gutter
///
final class CodeView: UITextView {

  // Delegates
  fileprivate var codeViewDelegate:                     CodeViewDelegate?
  fileprivate var codeStorageDelegate:                  CodeStorageDelegate
  fileprivate let minimapTextLayoutManagerDelegate      = MinimapTextLayoutManagerDelegate()

  // Subviews
  var gutterView:               GutterView?
  var currentLineHighlightView: CodeBackgroundHighlightView?
  var minimapView:              MinimapView?
  var minimapGutterView:        GutterView?
  var documentVisibleBox:       UIView?
  var minimapDividerView:       UIView?

  // Notification observer
  private var textDidChangeObserver: NSObjectProtocol?

  /// For the consumption of the diagnostics stream.
  ///
  private var diagnosticsCancellable: Cancellable?

  /// For the consumption of the events stream from the language service.
  ///
  private var eventsCancellable: Cancellable?

  /// Background tokenizer for viewport-based tokenization (replaces old TokenizationCoordinator).
  ///
  private let backgroundTokenizer = BackgroundTokenizer()

  /// KVO observations that need to be retained (e.g. safe renderingAttributesValidator wrapper).
  ///
  private var observations: [NSKeyValueObservation] = []

  /// Viewport predictor for pre-tokenizing content before it scrolls into view.
  ///
  private let viewportPredictor = ViewportPredictor()

  /// Estimator for instant document height calculation (avoids full layout on load).
  ///
  private var heightEstimator: HeightEstimator?

  /// Work item for debouncing viewport change notifications to reduce tokenization triggers during scroll.
  ///
  private var viewportChangeWorkItem: DispatchWorkItem?

  /// Work item for debouncing resize end (wrap text).
  ///
  private var resizeEndWorkItem: DispatchWorkItem?

  /// Last bounds size observed for resize detection.
  ///
  private var lastObservedResizeBoundsSize: CGSize = .zero

  /// Debounce interval for viewport changes. 50ms reduces triggers from 60+ to ~20 per second
  /// during scrolling while being responsive enough for a good experience.
  ///
  private let viewportChangeDebounceInterval: TimeInterval = 0.05

  /// Contains the line on which the insertion point was located, the last time the selection range got set (if the
  /// selection was an insertion point at all; i.e., it's length was 0).
  ///
  var oldLastLineOfInsertionPoint: Int? = 1

  /// Flag indicating the view is currently being resized - skip expensive operations.
  ///
  var isResizing: Bool = false

  /// Flag indicating tile() is currently executing - prevents recursive layout cycles.
  ///
  private var isTiling: Bool = false

  /// Cached documentVisibleRect to avoid repeated access during layout.
  ///
  private var cachedDocumentVisibleRect: CGRect?

  /// Tracks pending layout work that needs to be applied after current layout pass.
  ///
  private var hasPendingLayoutWork: Bool = false

  /// Last bounds size that was tiled.
  ///
  /// PERF: Avoid calling `tile()` on every scroll tick (UIScrollView updates bounds origin while scrolling).
  private var lastTiledBoundsSize: CGSize = .zero

  /// Last content height that was tiled.
  ///
  /// PERF: Keep gutter/minimap sizing in sync when the document height changes without over-tiling.
  private var lastTiledContentHeight: CGFloat = 0

  /// Last layout configuration that was tiled.
  ///
  private var lastTiledViewLayout: CodeEditor.LayoutConfiguration = .standard

  /// Last font width that was tiled (affects gutter sizing).
  ///
  private var lastTiledFontWidth: CGFloat = 0

  /// The current highlighting theme
  ///
  @Invalidating(.layout, .display)
  var theme: Theme = .defaultLight {
    didSet {
      font                                  = theme.font
      backgroundColor                       = theme.backgroundColour
      tintColor                             = theme.tintColour
      (textStorage as? CodeStorage)?.theme  = theme
      gutterView?.theme                     = theme
      currentLineHighlightView?.color       = theme.currentLineColour
      minimapView?.backgroundColor          = theme.backgroundColour
      minimapGutterView?.theme              = theme
      documentVisibleBox?.backgroundColor   = theme.textColour.withAlphaComponent(0.1)
    }
  }

  /// The current language configuration.
  ///
  /// We keep track of it here to enable us to spot changes during processing of view updates.
  ///
  @Invalidating(.layout, .display)
  var language: LanguageConfiguration = .none {
    didSet {
      guard let codeStorage = optCodeStorage else { return }

      if oldValue != language {

        Task { @MainActor in
          do {

            try await codeStorageDelegate.change(language: language, for: codeStorage)
            try await startLanguageService()

          } catch let error {
            logger.trace("Failed to change language from \(oldValue.name) to \(self.language.name): \(error.localizedDescription)")
          }

          // FIXME: This is an awful kludge to get the code view to redraw with the new highlighting. Emitting
          //        `codeStorage.edited(:range:changeInLength)` doesn't seem to work reliably.
          Task { @MainActor in
            font = theme.font
          }
        }

      }
    }
  }

  /// The current view layout.
  ///
  @Invalidating(.layout)
  var viewLayout: CodeEditor.LayoutConfiguration = .standard

  /// The current indentation configuration.
  ///
  var indentation: CodeEditor.IndentationConfiguration = .standard

  /// The current auto-brace configuration.
  ///
  var autoBrace: CodeEditor.AutoBraceConfiguration = .enabled

  /// Hook to propagate message sets upwards in the view hierarchy.
  ///
  let setMessages: (Set<TextLocated<Message>>) -> Void

  /// This is the last reported set of `messages`. New message sets can come from the context or from a language server.
  ///
  var lastMessages: Set<TextLocated<Message>> = Set()

  /// Keeps track of the set of message views.
  ///
  var messageViews: MessageViews = [:]

  /// Cached document height for the main code view (invalidated on text change).
  ///
  private var cachedCodeHeight: CGFloat?

  /// Cached document height for the minimap (invalidated on text change).
  ///
  private var cachedMinimapHeight: CGFloat?

  /// Last time the minimap position was updated (for throttling during scroll).
  ///
  private var lastMinimapUpdateTime: CFAbsoluteTime = 0

  /// Minimum interval between minimap position updates during scroll (in seconds).
  ///
  private let minimapUpdateThrottleInterval: CFAbsoluteTime = 0.016  // ~60fps

  /// Invalidate and recalculate cached document heights when content changes.
  /// Uses height estimation for instant updates instead of full layout.
  /// Also updates scroll metrics to prevent "jelly" scrolling effect.
  ///
  func invalidateDocumentHeightCache(updateScrollMetrics: Bool = true) {
    let lineCount = codeStorageDelegate.lineMap.lines.count
    if let estimator = heightEstimator {
      cachedCodeHeight = estimator.estimatedHeight(for: lineCount)
      cachedMinimapHeight = estimator.estimatedMinimapHeight(for: lineCount)
    } else {
      // Fallback: estimate based on font line height
      let lineHeight = theme.font.lineHeight
      cachedCodeHeight = CGFloat(lineCount) * lineHeight
      cachedMinimapHeight = CGFloat(lineCount) * (lineHeight / minimapRatio)
    }

    // Don't modify contentSize during tiling to prevent recursion
    if isTiling {
      hasPendingLayoutWork = true
      return
    }
    guard updateScrollMetrics else { return }

    // Update content size to match estimated height (prevents jelly scrolling)
    // On iOS, UITextView inherits from UIScrollView, so contentSize determines scrollable area
    if let estimatedHeight = cachedCodeHeight {
      let minHeight = max(estimatedHeight, documentVisibleRect.height)
      let newContentSize = CGSize(width: bounds.width, height: minHeight)
      if contentSize != newContentSize {
        contentSize = newContentSize
      }
    }
  }

  /// Designated initializer for code views with a gutter.
  ///
  init(frame: CGRect,
       with language: LanguageConfiguration,
       viewLayout: CodeEditor.LayoutConfiguration,
       indentation: CodeEditor.IndentationConfiguration,
       autoBrace: CodeEditor.AutoBraceConfiguration = .enabled,
       theme: Theme,
       setText: @escaping (String) -> Void,
       setMessages: @escaping (Set<TextLocated<Message>>) -> Void)
  {

    self.theme       = theme
    self.language    = language
    self.viewLayout  = viewLayout
    self.indentation = indentation
    self.autoBrace   = autoBrace
    self.setMessages = setMessages

    // Use custom components that are gutter-aware and support code-specific editing actions and highlighting.
    let textLayoutManager  = NSTextLayoutManager(),
        codeContainer      = CodeContainer(size: frame.size),
        codeStorage        = CodeStorage(theme: theme),
        textContentStorage = CodeContentStorage()
    textLayoutManager.textContainer = codeContainer
    textContentStorage.addTextLayoutManager(textLayoutManager)
    textContentStorage.primaryTextLayoutManager = textLayoutManager
    textContentStorage.textStorage              = codeStorage

    codeStorageDelegate = CodeStorageDelegate(with: language, setText: setText)
    // IMPORTANT: Install the storage delegate *before* any rendering-attributes validation can run.
    // Otherwise the first viewport fragments may get validated without highlighting and never get revalidated,
    // which shows up as "highlighting one viewport ahead".
    codeStorage.delegate = codeStorageDelegate

    super.init(frame: frame, textContainer: codeContainer)
    codeContainer.textView = self

    // Add the view delegate early so it can be used by the safe renderingAttributesValidator wrapper.
    let codeViewDelegate = CodeViewDelegate(codeView: self)
    self.codeViewDelegate = codeViewDelegate
    delegate = codeViewDelegate

    textLayoutManager.setSafeRenderingAttributesValidator(with: codeViewDelegate) { [weak self] (textLayoutManager, layoutFragment) in
      guard let self else { return }
      guard let textContentStorage = textLayoutManager.textContentManager as? NSTextContentStorage else { return }

      let charRange = textContentStorage.range(for: layoutFragment.rangeInElement)
      codeStorage.setHighlightingAttributes(for: charRange, in: textLayoutManager)

      // Record measured height for word wrap - enables accurate document height estimation
      if self.viewLayout.wrapText, let estimator = self.heightEstimator {
        let fragmentHeight = layoutFragment.layoutFragmentFrameWithoutExtraLineFragment.height
        let lineRange = self.codeStorageDelegate.lineMap.linesContaining(range: charRange)
        if let firstLine = lineRange.first {
          estimator.recordMeasuredHeight(fragmentHeight, for: firstLine)
        }
      }
    }.flatMap { observations.append($0) }

    // We can't do this — see [Note NSTextViewportLayoutControllerDelegate].
    //
    //    if let systemDelegate = codeLayoutManager.textViewportLayoutController.delegate {
    //      let codeViewportLayoutControllerDelegate = CodeViewportLayoutControllerDelegate(systemDelegate: systemDelegate,
    //                                                                                      codeView: self)
    //      self.codeViewportLayoutControllerDelegate               = codeViewportLayoutControllerDelegate
    //      codeLayoutManager.textViewportLayoutController.delegate = codeViewportLayoutControllerDelegate
    //    }

    // Set basic display and input properties
    font                   = theme.font
    backgroundColor        = theme.backgroundColour
    tintColor              = theme.tintColour
    autocapitalizationType = .none
    autocorrectionType     = .no
    spellCheckingType      = .no
    smartQuotesType        = .no
    smartDashesType        = .no
    smartInsertDeleteType  = .no

    // Line wrapping
    textContainerInset                  = .zero
    textContainer.widthTracksTextView  = false   // we need to be able to control the size (see `tile()`)
    textContainer.heightTracksTextView = false
    textContainer.lineBreakMode        = .byWordWrapping

    // `codeStorage.delegate` is set above (before installing validators) for correct initial highlighting.

    // Initialize the background tokenizer (replaces old TokenizationCoordinator)
    backgroundTokenizer.codeStorageDelegate = codeStorageDelegate
    backgroundTokenizer.textStorage = codeStorage
    backgroundTokenizer.triggerRedraw = { [weak self] range in
      guard let self else { return }
      if let textContentStorage = self.optTextContentStorage,
         let textRange = textContentStorage.textRange(for: range) {
        // Light-weight invalidation (just marks attributes as dirty)
        self.optTextLayoutManager?.invalidateRenderingAttributes(for: textRange)
        // Only invalidate minimap if it's visible
        if self.viewLayout.showMinimap {
          self.minimapView?.textLayoutManager?.invalidateRenderingAttributes(for: textRange)
        }
      }
      // Mark views as needing display - TextKit 2 will call validators during draw
      #if os(iOS) || os(visionOS)
      self.setNeedsDisplay()
      if self.viewLayout.showMinimap {
        self.minimapView?.setNeedsDisplay()
      }
      #else
      self.needsDisplay = true
      if self.viewLayout.showMinimap {
        self.minimapView?.needsDisplay = true
      }
      #endif
    }
    // Start the background tokenizer
    backgroundTokenizer.start()

    // Initialize the viewport predictor with font line height
    viewportPredictor.setLineHeight(theme.font.lineHeight)

    // Initialize the height estimator for instant document height calculation
    // Account for gutter width when estimating container width for word wrap
    let gutterWidthEstimate = ceil(theme.font.maximumHorizontalAdvancement * 7)
    let initialContainerWidth = viewLayout.wrapText
      ? max(frame.width - gutterWidthEstimate, 100)
      : CGFloat.greatestFiniteMagnitude
    heightEstimator = HeightEstimator(config: HeightEstimator.Configuration(
      font: theme.font,
      wrapText: viewLayout.wrapText,
      containerWidth: initialContainerWidth,
      minimapRatio: minimapRatio
    ))

    // Add a gutter view
    let gutterView  = GutterView(frame: .zero,
                                 textView: self,
                                 codeStorage: codeStorage,
                                 theme: theme,
                                 getMessageViews: { [weak self] in self?.messageViews ?? [:] },
                                 isMinimapGutter: false)
    gutterView.autoresizingMask  = []
    self.gutterView              = gutterView
    addSubview(gutterView)

    let currentLineHighlightView = CodeBackgroundHighlightView(color: theme.currentLineColour)
    self.currentLineHighlightView = currentLineHighlightView
    addBackgroundSubview(currentLineHighlightView)

    // Create the minimap with its own gutter, but sharing the code storage with the code view
    //
    let minimapView        = MinimapView(),
        minimapGutterView  = GutterView(frame: CGRect.zero,
                                        textView: minimapView,
                                        codeStorage: codeStorage,
                                        theme: theme,
                                        getMessageViews: { [weak self] in self?.messageViews ?? [:] },
                                        isMinimapGutter: true),
        minimapDividerView = UIView()
    minimapView.codeView = self

    minimapDividerView.backgroundColor = .separator
    self.minimapDividerView            = minimapDividerView
    addSubview(minimapDividerView)

    // We register the text layout manager of the minimap view as a secondary layout manager of the code view's text
    // content storage, so that code view and minimap use the same content.
    minimapView.textLayoutManager?.replace(textContentStorage)
    textContentStorage.primaryTextLayoutManager = textLayoutManager
    minimapView.textLayoutManager?.setSafeRenderingAttributesValidator(with: codeViewDelegate) { [weak self, weak minimapView] (minimapLayoutManager, layoutFragment) in
      guard let self else { return }
      guard let minimapView, !minimapView.isHidden, !minimapView.isShowingSnapshot else { return }
      guard let textContentStorage = minimapLayoutManager.textContentManager as? NSTextContentStorage else { return }
      codeStorage.setHighlightingAttributes(for: textContentStorage.range(for: layoutFragment.rangeInElement),
                                            in: minimapLayoutManager)
    }.flatMap { observations.append($0) }
    minimapView.textLayoutManager?.delegate = minimapTextLayoutManagerDelegate

    minimapView.isScrollEnabled                    = false
    minimapView.backgroundColor                    = theme.backgroundColour
    minimapView.tintColor                          = theme.tintColour
    minimapView.isEditable                         = false
    minimapView.isSelectable                       = false
    minimapView.textContainerInset                 = .zero
    minimapView.textContainer.widthTracksTextView  = false    // we need to be able to control the size (see `tile()`)
    minimapView.textContainer.heightTracksTextView = true
    minimapView.textContainer.lineBreakMode        = .byWordWrapping
    self.minimapView = minimapView
    addSubview(minimapView)

    minimapView.addSubview(minimapGutterView)
    self.minimapGutterView = minimapGutterView

    let documentVisibleBox = UIView()
    documentVisibleBox.backgroundColor = theme.textColour.withAlphaComponent(0.1)
    minimapView.addSubview(documentVisibleBox)
    self.documentVisibleBox = documentVisibleBox

    // We need to check whether we need to look up completions or cancel a running completion process after every text
    // change.  We also need to invalidate the views of all in the meantime invalidated message views.
    textDidChangeObserver
      = NotificationCenter.default.addObserver(forName: UITextView.textDidChangeNotification,
                                               object: self,
                                               queue: .main){ [weak self] _ in

        // Notify background tokenizer of edit to pause during active typing
        self?.backgroundTokenizer.notifyEdit()

        self?.invalidateDocumentHeightCache()
        // NOTE: Removed computeDocumentHeightsAsync() - heights are set by performFullDocumentLayout()
        self?.considerCompletionFor(range: self!.rangeForUserCompletion)
        self?.invalidateMessageViews(withIDs: self!.codeStorageDelegate.lastInvalidatedMessageIDs)
        self?.gutterView?.invalidateGutter()
        self?.minimapGutterView?.invalidateGutter()
      }

    Task {
      do {
        try await startLanguageService()
      } catch let error {
        logger.trace("Failed to start language service for \(language.name): \(error.localizedDescription)")
      }
    }
  }

  /// Try to activate the language service for the currently configured language.
  ///
  func startLanguageService() async throws {
    diagnosticsCancellable = nil
    eventsCancellable      = nil

    if let languageService = codeStorageDelegate.languageService {

      try await languageService.openDocument(with: textStorage.string,
                                             locationService: codeStorageDelegate.lineMapLocationConverter)

      // Report diagnostic messages as they come in.
      diagnosticsCancellable = languageService.diagnostics
        .receive(on: DispatchQueue.main)
        .sink { [weak self] messages in

          self?.setMessages(messages)
          self?.update(messages: messages)
        }

      eventsCancellable = languageService.events
        .receive(on: DispatchQueue.main)
        .sink { [weak self] event in

          self?.process(event: event)
        }
    }
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  deinit {
    if let observer = textDidChangeObserver { NotificationCenter.default.removeObserver(observer) }
  }

  // NB: Trying to do tiling and minimap adjusting on specific events, instead of here, leads to lots of tricky corner
  //     case.
  override func layoutSubviews() {
    // Detect resize early (before expensive tiling) and suppress heavy work while the size is in flux.
    // This is especially important for wrap text, where changing the container width can trigger expensive reflow.
    let currentBoundsSize = bounds.size
    if lastObservedResizeBoundsSize == .zero {
      lastObservedResizeBoundsSize = currentBoundsSize
    } else if currentBoundsSize != lastObservedResizeBoundsSize {
      lastObservedResizeBoundsSize = currentBoundsSize

      // Treat any bounds size change as an active resize; settle after a short debounce.
      if !isResizing {
        isResizing = true
        if viewLayout.showMinimap {
          minimapView?.captureSnapshot()
          minimapView?.showSnapshot()
        }
      }

      resizeEndWorkItem?.cancel()
      let delay: TimeInterval = viewLayout.wrapText ? 0.2 : 0.05
      let work = DispatchWorkItem { [weak self] in
        guard let self else { return }
        self.isResizing = false
        self.minimapView?.hideSnapshot()
        self.relayoutAfterResize()
      }
      resizeEndWorkItem = work
      DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    // During resize, only update gutter position (lightweight)
    if isResizing {
      updateContainerWidthForResize()
      tileGutterOnly()
      super.layoutSubviews()
      return
    }

    // PERF: Avoid expensive tiling during scrolling.
    // `layoutSubviews()` is called frequently while scrolling because UIScrollView changes its bounds origin.
    // Only retile when size/content/layout/font metrics changed.
    let currentContentHeight = contentSize.height
    let currentViewLayout = viewLayout
    let currentFontWidth = (font ?? theme.font).maximumHorizontalAdvancement

    let needsTiling = currentBoundsSize != lastTiledBoundsSize
      || abs(currentContentHeight - lastTiledContentHeight) > 0.5
      || currentViewLayout != lastTiledViewLayout
      || abs(currentFontWidth - lastTiledFontWidth) > 0.0001

    if needsTiling {
      tile()
      if viewLayout.showMinimap {
        adjustScrollPositionOfMinimap()
      }
      lastTiledBoundsSize = currentBoundsSize
      lastTiledContentHeight = contentSize.height
      lastTiledViewLayout = currentViewLayout
      lastTiledFontWidth = currentFontWidth
    }

    super.layoutSubviews()

    // Only force gutter redraw after geometry changes, not on every scroll.
    if needsTiling {
      gutterView?.setNeedsDisplay()
      if viewLayout.showMinimap {
        minimapGutterView?.setNeedsDisplay()
      }
    }
  }

  /// Notify the view about scrolling for viewport-dependent background work.
  ///
  /// PERF: Keep this lightweight; scrolling must remain on the fast path.
  func userDidScroll() {
    // Pause background tokenization during active scrolling to keep scrolling responsive.
    backgroundTokenizer.notifyEdit()
    guard !isResizing else { return }

    // Update viewport predictor with scroll position.
    viewportPredictor.update(scrollOffset: documentVisibleRect.origin.y)

    // Notify background tokenizer of viewport changes (debounced).
    viewportChangeWorkItem?.cancel()
    viewportChangeWorkItem = DispatchWorkItem { [weak self] in
      guard let self,
            let textLayoutManager = self.optTextLayoutManager,
            let viewportRange = textLayoutManager.textViewportLayoutController.viewportRange,
            let textContentStorage = self.optTextContentStorage
      else { return }

      let charRange = textContentStorage.range(for: viewportRange)
      let visibleLines = self.codeStorageDelegate.lineMap.linesContaining(range: charRange)

      // Update background tokenizer with visible viewport
      self.backgroundTokenizer.viewportDidChange(startLine: visibleLines.lowerBound,
                                                  endLine: visibleLines.upperBound)

      // Set priority viewport for pre-tokenization based on scroll velocity
      let totalLines = self.codeStorageDelegate.lineMap.lines.count
      let predictedViewport = self.viewportPredictor.predictedViewport(current: visibleLines, totalLines: totalLines)
      self.backgroundTokenizer.setPriorityViewport(predictedViewport)

      // Update document height when word wrap is enabled.
      // This allows progressive height refinement as the user scrolls and new lines are measured.
      if self.viewLayout.wrapText {
        self.updateDocumentHeightsFromLineCount()
        // Update frame/content size if height changed significantly (prevents jitter during scroll)
        if let estimatedHeight = self.cachedCodeHeight {
          let currentHeight = self.frame.size.height
          let minHeight = max(estimatedHeight, self.documentVisibleRect.height)
          // Only update if difference is significant (more than one line height)
          if abs(currentHeight - minHeight) > self.theme.font.lineHeight {
            self.frame.size.height = minHeight
            self.contentSize = CGSize(width: self.bounds.width, height: minHeight)
          }
        }
      }
    }

    if let workItem = viewportChangeWorkItem {
      DispatchQueue.main.asyncAfter(deadline: .now() + viewportChangeDebounceInterval, execute: workItem)
    }
  }

  /// Lightweight gutter positioning for use during resize.
  /// Only updates frames - skips redraws, minimap layout, message views, and other expensive work.
  private func tileGutterOnly() {
    guard let gutterView else { return }
    // Pause background work during resize to keep resizing smooth.
    backgroundTokenizer.notifyEdit()
    let theFont = font ?? OSFont.systemFont(ofSize: 0)
    let fontWidth = theFont.maximumHorizontalAdvancement
    let gutterWidth = ceil(fontWidth * 7)
    let gutterHeight = max(contentSize.height, bounds.height)
    let gutterFrame = CGRect(x: 0, y: 0, width: gutterWidth, height: gutterHeight)
    if gutterView.frame != gutterFrame { gutterView.frame = gutterFrame }
    // Skip gutter redraw during resize - will be redrawn in relayoutAfterResize()

    // Update minimap frame position (lightweight - no layout or redraw)
    if viewLayout.showMinimap {
      updateMinimapFrameOnly()
    }
  }

  /// Update minimap frame position during resize without triggering layout.
  /// This positions the minimap on the right edge without expensive viewport layout.
  private func updateMinimapFrameOnly() {
    guard viewLayout.showMinimap,
          let minimapView = minimapView
    else { return }

    let visibleRect = documentVisibleRect
    let theFont = font ?? OSFont.systemFont(ofSize: 0)
    let fontWidth = theFont.maximumHorizontalAdvancement
    let minimapFontWidth = fontWidth / minimapRatio
    let minimapGutterWidth = ceil(minimapFontWidth * 7)
    let dividerWidth = CGFloat(1)
    let gutterWidth = ceil(fontWidth * 7)
    let lineFragmentPadding = CGFloat(5)
    let gutterWithPadding = gutterWidth + lineFragmentPadding

    let visibleWidth = visibleRect.width
    let minimapExtras = minimapGutterWidth + dividerWidth
    let widthWithoutGutters = max(CGFloat(0), visibleWidth - gutterWithPadding - minimapExtras)
    let compositeFontWidth = fontWidth + minimapFontWidth
    let numberOfCharacters = max(0, Int(floor(widthWithoutGutters / compositeFontWidth)))
    let codeViewWidth = gutterWithPadding + (CGFloat(numberOfCharacters) * fontWidth)
    let minimapWidth = visibleWidth - codeViewWidth
    let minimapX = floor(visibleWidth - minimapWidth)

    // Update minimap frame x and width only (lightweight frame update)
    var newFrame = minimapView.frame
    if newFrame.origin.x != minimapX || newFrame.width != minimapWidth {
      newFrame.origin.x = minimapX
      newFrame.size.width = minimapWidth
      minimapView.frame = newFrame
    }

    // Update divider position
    if let divider = minimapDividerView {
      let dividerX = minimapX - dividerWidth
      if divider.frame.origin.x != dividerX {
        divider.frame.origin.x = dividerX
      }
    }

    // Update minimap snapshot frame if showing
    minimapView.updateSnapshotFrame()
  }

  /// Update container width during resize for smooth word wrap.
  /// Called immediately during resize (not just at the end) for smooth visual feedback.
  func updateContainerWidthForResize() {
    guard let textLayoutManager = optTextLayoutManager,
          let codeContainer = optTextContainer as? CodeContainer
    else { return }

    let theFont = font ?? theme.font
    let fontWidth = theFont.maximumHorizontalAdvancement
    let gutterWidth = ceil(fontWidth * 7)
    let lineFragmentPadding = CGFloat(5)

    // Keep inset/padding in sync with tiling so wrapping is stable during live resize.
    if textContainerInset.left != gutterWidth {
      textContainerInset = UIEdgeInsets(top: 0, left: gutterWidth, bottom: 0, right: 0)
    }
    if codeContainer.lineFragmentPadding != lineFragmentPadding {
      codeContainer.lineFragmentPadding = lineFragmentPadding
    }

    let visibleWidth = bounds.width

    let desiredContainerWidth: CGFloat = if viewLayout.wrapText {
      if viewLayout.showMinimap {
        let minimapFontWidth = fontWidth / minimapRatio
        let minimapGutterWidth = ceil(minimapFontWidth * 7)
        let dividerWidth = CGFloat(1)
        let minimapExtras = minimapGutterWidth + dividerWidth
        let gutterWithPadding = gutterWidth + lineFragmentPadding
        let availableWidth = max(CGFloat(0), visibleWidth - gutterWithPadding - minimapExtras)
        let compositeFontWidth = fontWidth + minimapFontWidth
        let columns = max(0, Int(floor(availableWidth / compositeFontWidth)))
        lineFragmentPadding + (CGFloat(columns) * fontWidth)
      } else {
        let gutterWithPadding = gutterWidth + lineFragmentPadding
        let availableWidth = max(CGFloat(0), visibleWidth - gutterWithPadding)
        let columns = max(0, Int(floor(availableWidth / fontWidth)))
        lineFragmentPadding + (CGFloat(columns) * fontWidth)
      }
    } else {
      CGFloat.greatestFiniteMagnitude
    }

    guard abs(codeContainer.size.width - desiredContainerWidth) > 0.0001 else { return }

    codeContainer.size = CGSize(width: desiredContainerWidth, height: CGFloat.greatestFiniteMagnitude)
    heightEstimator?.updateConfiguration(HeightEstimator.Configuration(
      font: theme.font,
      wrapText: viewLayout.wrapText,
      containerWidth: desiredContainerWidth,
      minimapRatio: minimapRatio
    ))

    // Container width affects word wrap => affects height estimates and scrollable area.
    // During live resize, avoid updating scroll metrics on every step to keep resizing smooth.
    invalidateDocumentHeightCache(updateScrollMetrics: false)

    // Reflow visible content immediately.
    textLayoutManager.textViewportLayoutController.layoutViewport()

    // Keep minimap wrapping in sync when it is visible (skip while snapshot is showing).
    if viewLayout.showMinimap,
       let minimapView,
       !minimapView.isHidden,
       !minimapView.isShowingSnapshot
    {
      minimapView.textContainer.size = CGSize(width: desiredContainerWidth, height: CGFloat.greatestFiniteMagnitude)
      minimapView.textLayoutManager?.textViewportLayoutController.layoutViewport()
    }
  }

  /// Relayout after resize - viewport only, height from estimation.
  /// NEVER does full document layout - uses math-based height estimation instead.
  func relayoutAfterResize() {
    guard let textLayoutManager = optTextLayoutManager,
          let codeContainer = optTextContainer as? CodeContainer
    else { return }

    let visibleWidth = bounds.width
    let theFont = font ?? theme.font
    let fontWidth = theFont.maximumHorizontalAdvancement
    let gutterWidth = ceil(fontWidth * 7)
    let lineFragmentPadding = CGFloat(5)

    if textContainerInset.left != gutterWidth {
      textContainerInset = UIEdgeInsets(top: 0, left: gutterWidth, bottom: 0, right: 0)
    }
    if codeContainer.lineFragmentPadding != lineFragmentPadding {
      codeContainer.lineFragmentPadding = lineFragmentPadding
    }

    let desiredContainerWidth: CGFloat = if viewLayout.wrapText {
      if viewLayout.showMinimap {
        let minimapFontWidth = fontWidth / minimapRatio
        let minimapGutterWidth = ceil(minimapFontWidth * 7)
        let dividerWidth = CGFloat(1)
        let minimapExtras = minimapGutterWidth + dividerWidth
        let gutterWithPadding = gutterWidth + lineFragmentPadding
        let availableWidth = max(CGFloat(0), visibleWidth - gutterWithPadding - minimapExtras)
        let compositeFontWidth = fontWidth + minimapFontWidth
        let columns = max(0, Int(floor(availableWidth / compositeFontWidth)))
        lineFragmentPadding + (CGFloat(columns) * fontWidth)
      } else {
        let gutterWithPadding = gutterWidth + lineFragmentPadding
        let availableWidth = max(CGFloat(0), visibleWidth - gutterWithPadding)
        let columns = max(0, Int(floor(availableWidth / fontWidth)))
        lineFragmentPadding + (CGFloat(columns) * fontWidth)
      }
    } else {
      CGFloat.greatestFiniteMagnitude
    }

    codeContainer.size = CGSize(width: desiredContainerWidth, height: CGFloat.greatestFiniteMagnitude)
    heightEstimator?.updateConfiguration(HeightEstimator.Configuration(
      font: theme.font,
      wrapText: viewLayout.wrapText,
      containerWidth: desiredContainerWidth,
      minimapRatio: minimapRatio
    ))

    // Only layout the visible viewport - TextKit 2 handles the rest on-demand
    textLayoutManager.textViewportLayoutController.layoutViewport()

    // Update minimap viewport if visible
    if viewLayout.showMinimap,
       let minimapView,
       !minimapView.isHidden,
       !minimapView.isShowingSnapshot
    {
      minimapView.textContainer.size = CGSize(width: desiredContainerWidth, height: CGFloat.greatestFiniteMagnitude)
      minimapView.textLayoutManager?.textViewportLayoutController.layoutViewport()
    }

    // Resize is complete — update scroll metrics from the current estimate (including any new wrap measurements).
    invalidateDocumentHeightCache()

    // Trigger tile() for gutter positioning - minimap scroll adjustment handled there
    setNeedsLayout()

    // Force gutter redraw now that resize is complete (was skipped during resize)
    gutterView?.setNeedsDisplay()
    if viewLayout.showMinimap {
      minimapGutterView?.setNeedsDisplay()
    }
  }
}

final class CodeViewDelegate: NSObject, UITextViewDelegate {

  // Hooks for events
  //
  var textDidChange:      ((UITextView) -> ())?
  var selectionDidChange: ((UITextView) -> ())?
  var didScroll:          ((UIScrollView) -> ())?

  /// Caching the last set selected range.
  ///
  var oldSelectedRange: NSRange

  init(codeView: CodeView) {
    oldSelectedRange = codeView.selectedRange
  }

  // MARK: -
  // MARK: UITextViewDelegate protocol

  func textViewDidChange(_ textView: UITextView) { textDidChange?(textView) }

  func textViewDidChangeSelection(_ textView: UITextView) {
    guard let codeView = textView as? CodeView else { return }

    // Close completion overlay when selection changes (user tapped or moved cursor)
    if codeView.isCompletionVisible {
      codeView.dismissCompletion()
    }

    selectionDidChange?(textView)

    codeView.updateBackgroundFor(oldSelection: oldSelectedRange, newSelection: codeView.selectedRange)
    oldSelectedRange = textView.selectedRange
  }

  func scrollViewDidScroll(_ scrollView: UIScrollView) {
    guard let codeView = scrollView as? CodeView else { return }

    // Dismiss completion overlay on scroll
    if codeView.isCompletionVisible {
      codeView.dismissCompletion()
    }

    didScroll?(scrollView)

    codeView.gutterView?.invalidateGutter()
    codeView.adjustScrollPositionOfMinimap()
    codeView.userDidScroll()
  }
}

/// Custom view for background highlights.
///
final class CodeBackgroundHighlightView: UIView {
  
  /// The background colour displayed by this view.
  ///
  var color: UIColor {
    get { backgroundColor ?? .clear }
    set { backgroundColor = newValue }
  }

  init(color: UIColor) {
    super.init(frame: .zero)
    self.color = color
  }
  
  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }
}


#elseif os(macOS)

// MARK: -
// MARK: AppKit version

/// `NSTextView` with a gutter
///  
final class CodeView: NSTextView {

  // Delegates
  fileprivate let codeViewDelegate =                 CodeViewDelegate()
  fileprivate var codeStorageDelegate:               CodeStorageDelegate
  fileprivate let minimapTextLayoutManagerDelegate = MinimapTextLayoutManagerDelegate()
  fileprivate let minimapCodeViewDelegate =          CodeViewDelegate()

  // Subviews
  var gutterView:               GutterView?
  var currentLineHighlightView: CodeBackgroundHighlightView?
  var minimapView:              MinimapView?
  var minimapGutterView:        GutterView?
  var documentVisibleBox:       NSBox?
  var minimapDividerView:       NSBox?

  // Notification observer
  private var frameChangedNotificationObserver:       NSObjectProtocol?
  private var didChangeNotificationObserver:          NSObjectProtocol?
  private var didChangeSelectionNotificationObserver: NSObjectProtocol?

  /// Flag indicating the view is currently being resized - skip expensive operations.
  var isResizing: Bool = false

  /// Flag indicating tile() is currently executing - prevents recursive layout cycles.
  ///
  private var isTiling: Bool = false

  /// Cached documentVisibleRect to avoid repeated access during layout.
  ///
  private var cachedDocumentVisibleRect: CGRect?

  /// Tracks pending layout work that needs to be applied after current layout pass.
  ///
  private var hasPendingLayoutWork: Bool = false

  /// Background tokenizer for viewport-based tokenization (replaces old TokenizationCoordinator).
  ///
  private let backgroundTokenizer = BackgroundTokenizer()

  /// Viewport predictor for pre-tokenizing content before it scrolls into view.
  ///
  private let viewportPredictor = ViewportPredictor()

  /// Estimator for instant document height calculation (avoids full layout on load).
  ///
  private var heightEstimator: HeightEstimator?

  /// Work item for debouncing viewport change notifications to reduce tokenization triggers during scroll.
  ///
  private var viewportChangeWorkItem: DispatchWorkItem?

  /// Debounce interval for viewport changes. 50ms reduces triggers from 60+ to ~20 per second
  /// during scrolling while being responsive enough for a good experience.
  ///
  private let viewportChangeDebounceInterval: TimeInterval = 0.05

  /// Contains the line on which the insertion point was located, the last time the selection range got set (if the
  /// selection was an insertion point at all; i.e., it's length was 0).
  ///
  var oldLastLineOfInsertionPoint: Int? = 1

  /// The current highlighting theme
  ///
  @Invalidating(.layout, .display)
  var theme: Theme = .defaultLight {
    didSet {
      font                                 = theme.font
      backgroundColor                      = theme.backgroundColour
      insertionPointColor                  = theme.cursorColour
      selectedTextAttributes               = [.backgroundColor: theme.selectionColour]
      (textStorage as? CodeStorage)?.theme = theme
      gutterView?.theme                    = theme
      currentLineHighlightView?.color      = theme.currentLineColour
      minimapView?.backgroundColor         = theme.backgroundColour
      minimapGutterView?.theme             = theme
      documentVisibleBox?.fillColor        = theme.textColour.withAlphaComponent(0.1)
    }
  }

  /// The current language configuration.
  ///
  /// We keep track of it here to enable us to spot changes during processing of view updates.
  ///
  @Invalidating(.layout, .display)
  var language: LanguageConfiguration = .none {
    didSet {
      guard let codeStorage = optCodeStorage else { return }

      if oldValue != language {

        Task { @MainActor in
          do {

            try await codeStorageDelegate.change(language: language, for: codeStorage)
            try await startLanguageService()

          } catch let error {
            logger.trace("Failed to change language from \(oldValue.name) to \(self.language.name): \(error.localizedDescription)")
          }

          // FIXME: This is an awful kludge to get the code view to redraw with the new highlighting. Emitting
          //        `codeStorage.edited(:range:changeInLength)` doesn't seem to work reliably.
          Task { @MainActor in
            font = theme.font
          }
        }

      }
    }
  }

  /// The current view layout.
  ///
  @Invalidating(.layout)
  var viewLayout: CodeEditor.LayoutConfiguration = .standard

  /// The current indentation configuration.
  ///
  var indentation: CodeEditor.IndentationConfiguration = .standard

  /// The current auto-brace configuration.
  ///
  var autoBrace: CodeEditor.AutoBraceConfiguration = .enabled

  /// Hook to propagate message sets upwards in the view hierarchy.
  ///
  let setMessages: (Set<TextLocated<Message>>) -> Void

  /// This is the last reported set of `messages`. New message sets can come from the context or from a language server.
  ///
  var lastMessages: Set<TextLocated<Message>> = Set()

  /// Keeps track of the set of message views.
  ///
  var messageViews: MessageViews = [:]

  /// Cached document height for the main code view (invalidated on text change).
  ///
  private var cachedCodeHeight: CGFloat?

  /// Cached document height for the minimap (invalidated on text change).
  ///
  private var cachedMinimapHeight: CGFloat?

  /// Last time the minimap position was updated (for throttling during scroll).
  ///
  private var lastMinimapUpdateTime: CFAbsoluteTime = 0

  /// Minimum interval between minimap position updates during scroll (in seconds).
  ///
  private let minimapUpdateThrottleInterval: CFAbsoluteTime = 0.016  // ~60fps

  /// Invalidate and recalculate cached document heights when content changes.
  /// Uses height estimation for instant updates instead of full layout.
  /// Also updates the frame size to prevent "jelly" scrolling effect.
  ///
  func invalidateDocumentHeightCache(updateScrollMetrics: Bool = true) {
    let lineCount = codeStorageDelegate.lineMap.lines.count
    if let estimator = heightEstimator {
      cachedCodeHeight = estimator.estimatedHeight(for: lineCount)
      cachedMinimapHeight = estimator.estimatedMinimapHeight(for: lineCount)
    } else {
      // Fallback: estimate based on font line height
      let lineHeight = theme.font.lineHeight
      cachedCodeHeight = CGFloat(lineCount) * lineHeight
      cachedMinimapHeight = CGFloat(lineCount) * (lineHeight / minimapRatio)
    }

    // Don't update frame during tiling to prevent recursion
    if isTiling {
      hasPendingLayoutWork = true
      return
    }
    guard updateScrollMetrics else { return }

    // Update frame size to match estimated height (prevents jelly scrolling)
    if let estimatedHeight = cachedCodeHeight {
      let minHeight = max(estimatedHeight, documentVisibleRect.height)
      if frame.size.height != minHeight {
        setFrameSize(NSSize(width: frame.size.width, height: minHeight))
      }
    }
  }

  /// NOTE: Removed computeDocumentHeightsAsync() - heights are now set by performInitialLayout()

  /// For the consumption of the diagnostics stream.
  ///
  private var diagnosticsCancellable: Cancellable?

  /// For the consumption of the events stream from the language service.
  ///
  private var eventsCancellable: Cancellable?

  /// Holds the info popover if there is one.
  ///
  var infoPopover: InfoPopover?

  /// Holds the completion panel. It is always available, but open, closed, and positioned on demand.
  ///
  var completionPanel: CompletionPanel = CompletionPanel()

  /// Cancellable task used to compute completions.
  ///
  var completionTask: Task<(), Error>?

  /// KVO observations that need to be retained.
  ///
  var observations: [NSKeyValueObservation] = []

  /// Designated initialiser for code views with a gutter.
  ///
  init(frame: CGRect,
       with language: LanguageConfiguration,
       viewLayout: CodeEditor.LayoutConfiguration,
       indentation: CodeEditor.IndentationConfiguration,
       autoBrace: CodeEditor.AutoBraceConfiguration = .enabled,
       theme: Theme,
       setText: @escaping (String) -> Void,
       setMessages: @escaping (Set<TextLocated<Message>>) -> Void)
  {

    self.theme       = theme
    self.language    = language
    self.viewLayout  = viewLayout
    self.indentation = indentation
    self.autoBrace   = autoBrace
    self.setMessages = setMessages

    // Use custom components that are gutter-aware and support code-specific editing actions and highlighting.
    let textLayoutManager  = NSTextLayoutManager(),
        codeContainer      = CodeContainer(size: frame.size),
        codeStorage        = CodeStorage(theme: theme),
        textContentStorage = CodeContentStorage()
    textLayoutManager.textContainer = codeContainer
    textContentStorage.addTextLayoutManager(textLayoutManager)
    textContentStorage.primaryTextLayoutManager = textLayoutManager
    textContentStorage.textStorage              = codeStorage

    codeStorageDelegate = CodeStorageDelegate(with: language, setText: setText)
    // IMPORTANT: Install the storage delegate before installing the rendering attributes validator.
    // If the validator runs while the delegate is nil, the initial viewport fragments won't be highlighted.
    codeStorage.delegate = codeStorageDelegate

    super.init(frame: frame, textContainer: codeContainer)

    textLayoutManager.setSafeRenderingAttributesValidator(with: codeViewDelegate) { [weak self] (textLayoutManager, layoutFragment) in
      guard let self else { return }
      guard let textContentStorage = textLayoutManager.textContentManager as? NSTextContentStorage else { return }

      let charRange = textContentStorage.range(for: layoutFragment.rangeInElement)
      codeStorage.setHighlightingAttributes(for: charRange, in: textLayoutManager)

      // Record measured height for word wrap - enables accurate document height estimation
      if self.viewLayout.wrapText, let estimator = self.heightEstimator {
        let fragmentHeight = layoutFragment.layoutFragmentFrameWithoutExtraLineFragment.height
        let lineRange = self.codeStorageDelegate.lineMap.linesContaining(range: charRange)
        if let firstLine = lineRange.first {
          estimator.recordMeasuredHeight(fragmentHeight, for: firstLine)
        }
      }
    }.flatMap { observations.append($0) }

    // We can't do this — see [Note NSTextViewportLayoutControllerDelegate].
    //
    //    if let systemDelegate = codeLayoutManager.textViewportLayoutController.delegate {
    //      let codeViewportLayoutControllerDelegate = CodeViewportLayoutControllerDelegate(systemDelegate: systemDelegate,
    //                                                                                      codeView: self)
    //      self.codeViewportLayoutControllerDelegate = codeViewportLayoutControllerDelegate
    //      codeLayoutManager.textViewportLayoutController.delegate = codeViewportLayoutControllerDelegate
    //    }

    // Set basic display and input properties
    font                                 = theme.font
    backgroundColor                      = theme.backgroundColour
    insertionPointColor                  = theme.cursorColour
    selectedTextAttributes               = [.backgroundColor: theme.selectionColour]
    isRichText                           = false
    isAutomaticQuoteSubstitutionEnabled  = false
    isAutomaticLinkDetectionEnabled      = false
    smartInsertDeleteEnabled             = false
    isContinuousSpellCheckingEnabled     = false
    isGrammarCheckingEnabled             = false
    isAutomaticDashSubstitutionEnabled   = false
    isAutomaticDataDetectionEnabled      = false
    isAutomaticSpellingCorrectionEnabled = false
    isAutomaticTextReplacementEnabled    = false
    usesFontPanel                        = false

    // Line wrapping
    isHorizontallyResizable             = false
    isVerticallyResizable               = true
    textContainerInset                  = .zero
    textContainer?.widthTracksTextView  = false   // we need to be able to control the size (see `tile()`)
    textContainer?.heightTracksTextView = false
    textContainer?.lineBreakMode        = .byWordWrapping

    // FIXME: properties that ought to be configurable
    usesFindBar                   = true
    isIncrementalSearchingEnabled = true

    // Enable undo support
    allowsUndo = true

    // Add the view delegate
    delegate = codeViewDelegate

    // `codeStorage.delegate` is set above (before installing validators) for correct initial highlighting.

    // Initialize the background tokenizer (replaces old TokenizationCoordinator)
    backgroundTokenizer.codeStorageDelegate = codeStorageDelegate
    backgroundTokenizer.textStorage = codeStorage
    backgroundTokenizer.triggerRedraw = { [weak self] range in
      guard let self else { return }
      if let textContentStorage = self.optTextContentStorage,
         let textRange = textContentStorage.textRange(for: range) {
        // Light-weight invalidation (just marks attributes as dirty)
        self.optTextLayoutManager?.invalidateRenderingAttributes(for: textRange)
        // Only invalidate minimap if it's visible
        if self.viewLayout.showMinimap {
          self.minimapView?.textLayoutManager?.invalidateRenderingAttributes(for: textRange)
        }
      }
      // Mark views as needing display - TextKit 2 will call validators during draw
      #if os(iOS) || os(visionOS)
      self.setNeedsDisplay()
      if self.viewLayout.showMinimap {
        self.minimapView?.setNeedsDisplay()
      }
      #else
      self.needsDisplay = true
      if self.viewLayout.showMinimap {
        self.minimapView?.needsDisplay = true
      }
      #endif
    }
    // Start the background tokenizer
    backgroundTokenizer.start()

    // Initialize the viewport predictor with font line height
    viewportPredictor.setLineHeight(theme.font.lineHeight)

    // Initialize the height estimator for instant document height calculation
    // Account for gutter width when estimating container width for word wrap
    let gutterWidthEstimate = ceil(theme.font.maximumHorizontalAdvancement * 7)
    let initialContainerWidth = viewLayout.wrapText
      ? max(frame.width - gutterWidthEstimate, 100)
      : CGFloat.greatestFiniteMagnitude
    heightEstimator = HeightEstimator(config: HeightEstimator.Configuration(
      font: theme.font,
      wrapText: viewLayout.wrapText,
      containerWidth: initialContainerWidth,
      minimapRatio: minimapRatio
    ))

    // Create the main gutter view
    let gutterView = GutterView(frame: CGRect.zero,
                                textView: self,
                                codeStorage: codeStorage,
                                theme: theme,
                                getMessageViews: { [weak self] in self?.messageViews ?? [:] },
                                isMinimapGutter: false)
    gutterView.autoresizingMask  = .none
    self.gutterView              = gutterView
    // NB: The gutter view is floating. We cannot add it now, as we don't have an `enclosingScrollView` yet.

    let currentLineHighlightView = CodeBackgroundHighlightView(color: theme.currentLineColour)
    addBackgroundSubview(currentLineHighlightView)
    self.currentLineHighlightView = currentLineHighlightView

    // Create the minimap with its own gutter, but sharing the code storage with the code view
    //
    let minimapView        = MinimapView(),
        minimapGutterView  = GutterView(frame: CGRect.zero,
                                        textView: minimapView,
                                        codeStorage: codeStorage,
                                        theme: theme,
                                        getMessageViews: { [weak self] in self?.messageViews ?? [:] },
                                        isMinimapGutter: true),
        minimapDividerView = NSBox()
    minimapView.codeView = self

    minimapDividerView.boxType     = .custom
    minimapDividerView.fillColor   = .separatorColor
    minimapDividerView.borderWidth = 0
    self.minimapDividerView = minimapDividerView
    // NB: The divider view is floating. We cannot add it now, as we don't have an `enclosingScrollView` yet.

    // We register the text layout manager of the minimap view as a secondary layout manager of the code view's text
    // content storage, so that code view and minimap use the same content.
    minimapView.textLayoutManager?.replace(textContentStorage)
    textContentStorage.primaryTextLayoutManager = textLayoutManager
    minimapView.delegate = minimapCodeViewDelegate
    minimapView.textLayoutManager?.setSafeRenderingAttributesValidator(with:
                                                                        minimapCodeViewDelegate) { [weak self, weak minimapView] (minimapLayoutManager,
                                                                                                    layoutFragment) in
      guard let self else { return }
      guard let minimapView, !minimapView.isHidden, !minimapView.isShowingSnapshot else { return }
      guard let textContentStorage = minimapLayoutManager.textContentManager as? NSTextContentStorage else { return }
      codeStorage.setHighlightingAttributes(for: textContentStorage.range(for: layoutFragment.rangeInElement),
                                            in: minimapLayoutManager)
    }.flatMap { observations.append($0) }
    minimapView.textLayoutManager?.delegate = minimapTextLayoutManagerDelegate

    let font = theme.font
    minimapView.font                                = OSFont(name: font.fontName, size: font.pointSize / minimapRatio)!
    minimapView.backgroundColor                     = backgroundColor
    minimapView.autoresizingMask                    = .none
    minimapView.isEditable                          = false
    minimapView.isSelectable                        = false
    minimapView.isHorizontallyResizable             = false
    minimapView.isVerticallyResizable               = true
    minimapView.textContainerInset                  = .zero
    minimapView.textContainer?.widthTracksTextView  = false    // we need to be able to control the size (see `tile()`)
    minimapView.textContainer?.heightTracksTextView = false
    minimapView.textContainer?.lineBreakMode        = .byWordWrapping
    self.minimapView = minimapView
    // NB: The minimap view is floating. We cannot add it now, as we don't have an `enclosingScrollView` yet.

    minimapView.addSubview(minimapGutterView)
    self.minimapGutterView = minimapGutterView

    let documentVisibleBox = NSBox()
    documentVisibleBox.boxType     = .custom
    documentVisibleBox.fillColor   = theme.textColour.withAlphaComponent(0.1)
    documentVisibleBox.borderWidth = 0
    minimapView.addSubview(documentVisibleBox)
    self.documentVisibleBox = documentVisibleBox

    maxSize = CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)


    // NOTE: Removed deferred minimap invalidation - it was undoing the work of performFullDocumentLayout().
    // The minimap layout is now handled by performFullDocumentLayout() called from CodeEditor.

    // NOTE: Frame change observation is set up in viewDidMoveToSuperview() when enclosingScrollView is available.
    // This ensures we observe the correct object and can properly trigger layout recalculation.

    // We need to check whether we need to look up completions or cancel a running completion process after every text
    // change. We also need to invalidate the views of all in the meantime invalidated message views.
    didChangeNotificationObserver
      = NotificationCenter.default.addObserver(forName: NSText.didChangeNotification,
                                               object: self,
                                               queue: .main) { [weak self] _ in

        // Notify background tokenizer of edit to pause during active typing
        self?.backgroundTokenizer.notifyEdit()

//        self?.infoPopover?.close()
        self?.invalidateDocumentHeightCache()
        // NOTE: Heights will be updated incrementally by TextKit 2 as needed
        self?.considerCompletionFor(range: self!.rangeForUserCompletion)
        self?.invalidateMessageViews(withIDs: self!.codeStorageDelegate.lastInvalidatedMessageIDs)
      }

    // Popups should disappear on cursor change.
    didChangeSelectionNotificationObserver
      = NotificationCenter.default.addObserver(forName: NSTextView.didChangeSelectionNotification,
                                               object: self,
                                               queue: .main) { [weak self] _ in

        self?.infoPopover?.close()
      }

    Task {
      do {
        try await startLanguageService()
      } catch let error {
        logger.trace("Failed to start language service for \(language.name): \(error.localizedDescription)")
      }
    }
  }
  
  /// Try to activate the language service for the currently configured language.
  ///
  func startLanguageService() async throws {
    guard let textStorage else { return }

    diagnosticsCancellable = nil
    eventsCancellable      = nil

    if let languageService = codeStorageDelegate.languageService {

      try await languageService.openDocument(with: textStorage.string,
                                             locationService: codeStorageDelegate.lineMapLocationConverter)

      // Report diagnostic messages as they come in.
      diagnosticsCancellable = languageService.diagnostics
        .receive(on: DispatchQueue.main)
        .sink { [weak self] messages in

          self?.setMessages(messages)
          self?.update(messages: messages)
        }

      eventsCancellable = languageService.events
        .receive(on: DispatchQueue.main)
        .sink { [weak self] event in

          self?.process(event: event)
        }
    }
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  deinit {
    if let observer = frameChangedNotificationObserver { NotificationCenter.default.removeObserver(observer) }
    if let observer = didChangeNotificationObserver { NotificationCenter.default.removeObserver(observer) }
    if let observer = didChangeSelectionNotificationObserver { NotificationCenter.default.removeObserver(observer) }
  }


  // MARK: Overrides

  override func viewWillStartLiveResize() {
    super.viewWillStartLiveResize()

    // Enter lightweight resize mode early to avoid expensive TextKit reflow while dragging.
    isResizing = true
    viewportChangeWorkItem?.cancel()
    backgroundTokenizer.notifyEdit()

    if viewLayout.showMinimap {
      minimapView?.captureSnapshot()
      minimapView?.showSnapshot()
    }
  }

  override func viewDidEndLiveResize() {
    super.viewDidEndLiveResize()

    isResizing = false
    minimapView?.hideSnapshot()
    relayoutAfterResize()
  }

  override func setSelectedRanges(_ ranges: [NSValue],
                                  affinity: NSSelectionAffinity,
                                  stillSelecting stillSelectingFlag: Bool)
  {
    let oldSelectedRanges = selectedRanges
    super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelectingFlag)

    // Updates only if there is an actual selection change.
    if oldSelectedRanges != selectedRanges {

      // FIXME: The following does not succeed for anything, but setting an insertion point. From macOS 15, selecting
      // FIXME: across more than one line, leads to a crash.
//      minimapView?.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelectingFlag)
      // FIXME: Hence, we only set insertion points for now. (They lead to a line highlight.)
      if let insertionPoint {
        minimapView?.setSelectedRange(NSRange(location: insertionPoint, length: 0))
      }

      updateBackgroundFor(oldSelection: combinedRanges(ranges: oldSelectedRanges),
                          newSelection: combinedRanges(ranges: ranges))

    }
  }

  override func layout() {
    // During resize, only update gutter position (lightweight)
    if isResizing {
      updateContainerWidthForResize()
      tileGutterOnly()
      super.layout()
      return
    }
    tile()
    if viewLayout.showMinimap {
      adjustScrollPositionOfMinimap()
    }
    super.layout()
    gutterView?.needsDisplay = true
    if viewLayout.showMinimap {
      minimapGutterView?.needsDisplay = true
    }
  }

  /// Notify the view about scrolling for viewport-dependent background work.
  ///
  /// PERF: Keep this lightweight; scrolling must remain on the fast path.
  func userDidScroll() {
    // Pause background tokenization during active scrolling to keep scrolling responsive.
    backgroundTokenizer.notifyEdit()
    guard !isResizing else { return }

    // Update viewport predictor with scroll position.
    viewportPredictor.update(scrollOffset: documentVisibleRect.origin.y)

    // Notify background tokenizer of viewport changes (debounced).
    viewportChangeWorkItem?.cancel()
    viewportChangeWorkItem = DispatchWorkItem { [weak self] in
      guard let self,
            let textLayoutManager = self.optTextLayoutManager,
            let viewportRange = textLayoutManager.textViewportLayoutController.viewportRange,
            let textContentStorage = self.optTextContentStorage
      else { return }

      let charRange = textContentStorage.range(for: viewportRange)
      let visibleLines = self.codeStorageDelegate.lineMap.linesContaining(range: charRange)

      // Update background tokenizer with visible viewport
      self.backgroundTokenizer.viewportDidChange(startLine: visibleLines.lowerBound,
                                                  endLine: visibleLines.upperBound)

      // Set priority viewport for pre-tokenization based on scroll velocity
      let totalLines = self.codeStorageDelegate.lineMap.lines.count
      let predictedViewport = self.viewportPredictor.predictedViewport(current: visibleLines, totalLines: totalLines)
      self.backgroundTokenizer.setPriorityViewport(predictedViewport)

      // Update document height when word wrap is enabled.
      // This allows progressive height refinement as the user scrolls and new lines are measured.
      if self.viewLayout.wrapText {
        self.updateDocumentHeightsFromLineCount()
        // Update frame if height changed significantly (prevents jitter during scroll)
        if let estimatedHeight = self.cachedCodeHeight {
          let currentHeight = self.frame.size.height
          let minHeight = max(estimatedHeight, self.documentVisibleRect.height)
          // Only update if difference is significant (more than one line height)
          if abs(currentHeight - minHeight) > self.theme.font.lineHeight {
            self.setFrameSize(NSSize(width: self.frame.size.width, height: minHeight))
          }
        }
      }
    }

    if let workItem = viewportChangeWorkItem {
      DispatchQueue.main.asyncAfter(deadline: .now() + viewportChangeDebounceInterval, execute: workItem)
    }
  }

  /// Lightweight gutter positioning for use during resize.
  /// Only updates frames - skips redraws, minimap layout, message views, and other expensive work.
  private func tileGutterOnly() {
    guard let gutterView else { return }
    // Pause background work during resize to keep resizing smooth.
    backgroundTokenizer.notifyEdit()
    let theFont = font ?? OSFont.systemFont(ofSize: 0)
    let fontWidth = theFont.maximumHorizontalAdvancement
    let gutterWidth = ceil(fontWidth * 7)
    let gutterHeight = max(frame.height, enclosingScrollView?.documentVisibleRect.height ?? 0)
    let gutterFrame = CGRect(x: 0, y: 0, width: gutterWidth, height: gutterHeight)
    if gutterView.frame != gutterFrame { gutterView.frame = gutterFrame }
    // Skip gutter redraw during resize - will be redrawn in relayoutAfterResize()

    // Update minimap frame position (lightweight - no layout or redraw)
    if viewLayout.showMinimap {
      updateMinimapFrameOnly()
    }
  }

  /// Update minimap frame position during resize without triggering layout.
  /// This positions the minimap on the right edge without expensive viewport layout.
  private func updateMinimapFrameOnly() {
    guard viewLayout.showMinimap,
          let minimapView = minimapView,
          let scrollView = enclosingScrollView
    else { return }

    let visibleRect = scrollView.documentVisibleRect
    let theFont = font ?? OSFont.systemFont(ofSize: 0)
    let fontWidth = theFont.maximumHorizontalAdvancement
    let minimapFontWidth = fontWidth / minimapRatio
    let minimapGutterWidth = ceil(minimapFontWidth * 7)
    let dividerWidth = CGFloat(1)
    let gutterWidth = ceil(fontWidth * 7)
    let lineFragmentPadding = CGFloat(5)
    let gutterWithPadding = gutterWidth + lineFragmentPadding

    let visibleWidth = visibleRect.width
    let minimapExtras = minimapGutterWidth + dividerWidth
    let widthWithoutGutters = max(CGFloat(0), visibleWidth - gutterWithPadding - minimapExtras)
    let compositeFontWidth = fontWidth + minimapFontWidth
    let numberOfCharacters = max(0, Int(floor(widthWithoutGutters / compositeFontWidth)))
    let codeViewWidth = gutterWithPadding + (CGFloat(numberOfCharacters) * fontWidth)
    let minimapWidth = visibleWidth - codeViewWidth
    let minimapX = floor(visibleWidth - minimapWidth)

    // Update minimap frame x and width only (lightweight frame update)
    var newFrame = minimapView.frame
    if newFrame.origin.x != minimapX || newFrame.width != minimapWidth {
      newFrame.origin.x = minimapX
      newFrame.size.width = minimapWidth
      minimapView.frame = newFrame
    }

    // Update divider position
    if let divider = minimapDividerView {
      let dividerX = minimapX - dividerWidth
      if divider.frame.origin.x != dividerX {
        divider.frame.origin.x = dividerX
      }
    }

    // Update minimap snapshot frame if showing
    minimapView.updateSnapshotFrame()
  }

  /// Update text container width immediately during resize for smooth word wrap.
  func updateContainerWidthForResize() {
    guard let textLayoutManager = optTextLayoutManager,
          let codeContainer = optTextContainer as? CodeContainer
    else { return }

    let theFont = font ?? theme.font
    let fontWidth = theFont.maximumHorizontalAdvancement
    let gutterWidth = ceil(fontWidth * 7)
    let lineFragmentPadding = CGFloat(5)

    if textContainerInset.width != gutterWidth {
      textContainerInset = CGSize(width: gutterWidth, height: 0)
    }
    if codeContainer.lineFragmentPadding != lineFragmentPadding {
      codeContainer.lineFragmentPadding = lineFragmentPadding
    }

    let visibleWidth = enclosingScrollView?.documentVisibleRect.width ?? bounds.width

    let desiredContainerWidth: CGFloat
    if viewLayout.wrapText {
      if viewLayout.showMinimap {
        let minimapFontWidth = fontWidth / minimapRatio
        let minimapGutterWidth = ceil(minimapFontWidth * 7)
        let dividerWidth = CGFloat(1)
        let minimapExtras = minimapGutterWidth + dividerWidth
        let gutterWithPadding = gutterWidth + lineFragmentPadding
        let availableWidth = max(CGFloat(0), visibleWidth - gutterWithPadding - minimapExtras)
        let compositeFontWidth = fontWidth + minimapFontWidth
        let columns = max(0, Int(floor(availableWidth / compositeFontWidth)))
        desiredContainerWidth = lineFragmentPadding + (CGFloat(columns) * fontWidth)
      } else {
        let gutterWithPadding = gutterWidth + lineFragmentPadding
        let availableWidth = max(CGFloat(0), visibleWidth - gutterWithPadding)
        let columns = max(0, Int(floor(availableWidth / fontWidth)))
        desiredContainerWidth = lineFragmentPadding + (CGFloat(columns) * fontWidth)
      }
    } else {
      desiredContainerWidth = CGFloat.greatestFiniteMagnitude
    }

    guard abs(codeContainer.size.width - desiredContainerWidth) > 0.0001 else { return }

    codeContainer.size = CGSize(width: desiredContainerWidth, height: CGFloat.greatestFiniteMagnitude)
    heightEstimator?.updateConfiguration(HeightEstimator.Configuration(
      font: theme.font,
      wrapText: viewLayout.wrapText,
      containerWidth: desiredContainerWidth,
      minimapRatio: minimapRatio
    ))

    invalidateDocumentHeightCache(updateScrollMetrics: false)

    textLayoutManager.textViewportLayoutController.layoutViewport()

    if viewLayout.showMinimap,
       let minimapView,
       !minimapView.isHidden,
       !minimapView.isShowingSnapshot
    {
      minimapView.textContainer?.size = CGSize(width: desiredContainerWidth, height: CGFloat.greatestFiniteMagnitude)
      minimapView.textLayoutManager?.textViewportLayoutController.layoutViewport()
    }
  }

  override func setFrameSize(_ newSize: NSSize) {
    // During resize or tiling, just pass through to avoid expensive calculations and recursion
    if isResizing || isTiling {
      super.setFrameSize(newSize)
      return
    }

    // Use cached documentVisibleRect if available to avoid forcing layout
    let visibleHeight = cachedDocumentVisibleRect?.height
                     ?? enclosingScrollView?.documentVisibleRect.height
                     ?? newSize.height

    // Ensure the frame height never shrinks below the content height
    // This prevents the scroll view from clamping the scrollable area
    let lineCount = codeStorageDelegate.lineMap.lines.count
    let lineHeight = theme.font.lineHeight
    let estimatedHeight = cachedCodeHeight ?? (CGFloat(lineCount) * lineHeight)
    let minimumHeight = max(estimatedHeight, visibleHeight)

    let adjustedSize = NSSize(width: newSize.width, height: max(newSize.height, minimumHeight))
    super.setFrameSize(adjustedSize)
  }

  /// Relayout after resize - viewport only, height from estimation.
  /// NEVER does full document layout - uses math-based height estimation instead.
  func relayoutAfterResize() {
    guard let textLayoutManager = optTextLayoutManager,
          let codeContainer = optTextContainer as? CodeContainer
    else { return }

    let visibleWidth = enclosingScrollView?.documentVisibleRect.width ?? bounds.width
    let theFont = font ?? theme.font
    let fontWidth = theFont.maximumHorizontalAdvancement
    let gutterWidth = ceil(fontWidth * 7)
    let lineFragmentPadding = CGFloat(5)

    if textContainerInset.width != gutterWidth {
      textContainerInset = CGSize(width: gutterWidth, height: 0)
    }
    if codeContainer.lineFragmentPadding != lineFragmentPadding {
      codeContainer.lineFragmentPadding = lineFragmentPadding
    }

    let desiredContainerWidth: CGFloat
    if viewLayout.wrapText {
      if viewLayout.showMinimap {
        let minimapFontWidth = fontWidth / minimapRatio
        let minimapGutterWidth = ceil(minimapFontWidth * 7)
        let dividerWidth = CGFloat(1)
        let minimapExtras = minimapGutterWidth + dividerWidth
        let gutterWithPadding = gutterWidth + lineFragmentPadding
        let availableWidth = max(CGFloat(0), visibleWidth - gutterWithPadding - minimapExtras)
        let compositeFontWidth = fontWidth + minimapFontWidth
        let columns = max(0, Int(floor(availableWidth / compositeFontWidth)))
        desiredContainerWidth = lineFragmentPadding + (CGFloat(columns) * fontWidth)
      } else {
        let gutterWithPadding = gutterWidth + lineFragmentPadding
        let availableWidth = max(CGFloat(0), visibleWidth - gutterWithPadding)
        let columns = max(0, Int(floor(availableWidth / fontWidth)))
        desiredContainerWidth = lineFragmentPadding + (CGFloat(columns) * fontWidth)
      }
    } else {
      desiredContainerWidth = CGFloat.greatestFiniteMagnitude
    }

    codeContainer.size = CGSize(width: desiredContainerWidth, height: CGFloat.greatestFiniteMagnitude)
    heightEstimator?.updateConfiguration(HeightEstimator.Configuration(
      font: theme.font,
      wrapText: viewLayout.wrapText,
      containerWidth: desiredContainerWidth,
      minimapRatio: minimapRatio
    ))

    // Layout the visible viewport first - this records measured heights for word-wrapped lines
    // via the renderingAttributesValidator callback
    textLayoutManager.textViewportLayoutController.layoutViewport()

    // Update minimap viewport if visible
    if viewLayout.showMinimap,
       let minimapView,
       !minimapView.isHidden,
       !minimapView.isShowingSnapshot
    {
      minimapView.textContainer?.size = CGSize(width: desiredContainerWidth, height: CGFloat.greatestFiniteMagnitude)
      minimapView.textLayoutManager?.textViewportLayoutController.layoutViewport()
    }

    // Recalculate heights AFTER viewport layout so measurements from visible lines are included
    updateDocumentHeightsFromLineCount()

    // Update frame from estimated height (now includes measured word-wrap heights)
    if let estimatedHeight = cachedCodeHeight {
      let minHeight = max(estimatedHeight, enclosingScrollView?.documentVisibleRect.height ?? 0)
      if frame.size.height != minHeight {
        super.setFrameSize(NSSize(width: frame.size.width, height: minHeight))
        minSize = NSSize(width: visibleWidth, height: minHeight)
      }
    }

    // Trigger layout for gutter positioning - minimap scroll adjustment handled there
    needsLayout = true

    // Force gutter redraw now that resize is complete (was skipped during resize)
    gutterView?.needsDisplay = true
    if viewLayout.showMinimap {
      minimapGutterView?.needsDisplay = true
    }
  }

  override func viewDidMoveToSuperview() {
    super.viewDidMoveToSuperview()

    // Set up frame change observer for gutter updates.
    // Resize reflow is handled by the view's live-resize overrides.
    if frameChangedNotificationObserver == nil, let scrollView = enclosingScrollView {
      frameChangedNotificationObserver
        = NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification,
                                                 object: scrollView,
                                                 queue: .main) { [weak self] _ in
          // Skip gutter redraw during resize - will be handled by relayoutAfterResize
          guard let self, !self.isResizing else { return }
          // Redraw gutter for line number updates
          self.gutterView?.needsDisplay = true
        }
    }
  }
}

final class CodeViewDelegate: NSObject, NSTextViewDelegate {

  // Hooks for events
  //
  var textDidChange:      ((NSTextView) -> ())?
  var selectionDidChange: ((NSTextView) -> ())?

  // MARK: NSTextViewDelegate protocol

  func textView(_ textView: NSTextView,
                willChangeSelectionFromCharacterRanges oldSelectedCharRanges: [NSValue],
                toCharacterRanges newSelectedCharRanges: [NSValue])
  -> [NSValue]
  {
    guard let codeStorageDelegeate = textView.textStorage?.delegate as? CodeStorageDelegate,
          textView is CodeView    // Don't execute this for the minimap view
    else { return newSelectedCharRanges }

    // If token completion added characters, we don't want to include them in the advance of the insertion point.
    if codeStorageDelegeate.tokenCompletionCharacters > 0,
       let selectionRange = newSelectedCharRanges.first as? NSRange,
       selectionRange.length == 0
    {

      let insertionPointWithoutCompletion = selectionRange.location - codeStorageDelegeate.tokenCompletionCharacters
      codeStorageDelegeate.tokenCompletionCharacters = 0
      return [NSRange(location: insertionPointWithoutCompletion, length: 0) as NSValue]

    } else { return newSelectedCharRanges }
  }

  func textDidChange(_ notification: Notification) {
    guard let textView = notification.object as? NSTextView else { return }

    textDidChange?(textView)
  }

  func textViewDidChangeSelection(_ notification: Notification) {
    guard let textView = notification.object as? NSTextView else { return }

    // Close completion panel when selection changes (user clicked or moved cursor)
    // This is only called for selection changes NOT triggered by text insertion
    if let codeView = textView as? CodeView, codeView.completionPanel.isVisible {
      codeView.completionPanel.close()
    }

    selectionDidChange?(textView)
  }
}

/// Custom view for background highlights.
///
final class CodeBackgroundHighlightView: NSBox {

  /// The background colour displayed by this view.
  ///
  var color: NSColor {
    get { fillColor }
    set { fillColor = newValue }
  }

  init(color: NSColor) {
    super.init(frame: .zero)
    self.color  = color
    boxType     = .custom
    borderWidth = 0
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }
}


#endif


// MARK: -
// MARK: Shared code

extension CodeView {

  // MARK: Background highlights
  
  /// Update the code background for the given selection change.
  ///
  /// - Parameters:
  ///   - oldRange: Old selection range.
  ///   - newRange: New selection range.
  ///
  /// This includes both invalidating rectangle for background redrawing as well as updating the frames of background
  /// (highlighting) views.
  ///
  func updateBackgroundFor(oldSelection oldRange: NSRange, newSelection newRange: NSRange) {
    guard let textContentStorage = optTextContentStorage else { return }

    let lineOfInsertionPoint = insertionPoint.flatMap{ optLineMap?.lineOf(index: $0) }

    // If the insertion point changed lines, we need to redraw at the old and new location to fix the line highlighting.
    // NB: We retain the last line and not the character index as the latter may be inaccurate due to editing that let
    //     to the selected range change.
    if lineOfInsertionPoint != oldLastLineOfInsertionPoint {

      if let textLocation = textContentStorage.textLocation(for: oldRange.location) {
        minimapView?.invalidateBackground(forLineContaining: textLocation)
      }

      if let textLocation = textContentStorage.textLocation(for: newRange.location) {
        updateCurrentLineHighlight(for: textLocation)
        minimapView?.invalidateBackground(forLineContaining: textLocation)
      }
    }
    oldLastLineOfInsertionPoint = lineOfInsertionPoint

    // Needed as the selection affects line number highlighting.
    // NB: Invalidation of the old and new ranges needs to happen separately. If we were to union them, an insertion
    //     point (range length = 0) at the start of a line would be absorbed into the previous line, which results in
    //     a lack of invalidation of the line on which the insertion point is located.
    gutterView?.invalidateGutter(for: oldRange)
    gutterView?.invalidateGutter(for: newRange)
    minimapGutterView?.invalidateGutter(for: oldRange)
    minimapGutterView?.invalidateGutter(for: newRange)

    DispatchQueue.main.async { [self] in
      collapseMessageViews()
      updateMessageLineHighlights()
    }
  }

  func updateCurrentLineHighlight(for location: NSTextLocation) {
    guard let textLayoutManager = optTextLayoutManager else { return }

    // NOTE: Removed ensureLayout() call - layout should already be available from TextKit 2

    // The current line highlight view needs to be visible if we have an insertion point (and not a selection range).
    currentLineHighlightView?.isHidden = insertionPoint == nil

    // The insertion point is inside the body of the text
    if let fragmentFrame = textLayoutManager.textLayoutFragment(for: location)?.layoutFragmentFrameWithoutExtraLineFragment,
       let highlightRect = lineBackgroundRect(y: fragmentFrame.minY, height: fragmentFrame.height)
    {
      currentLineHighlightView?.frame = highlightRect
    } else 
    // OR the insertion point is behind the end of the text, which ends with a trailing newline (=> extra line fragement)
    if let previousLocation = optTextContentStorage?.location(location, offsetBy: -1),
       let fragmentFrame    = textLayoutManager.textLayoutFragment(for: previousLocation)?.layoutFragmentFrameExtraLineFragment,
       let highlightRect    = lineBackgroundRect(y: fragmentFrame.minY, height: fragmentFrame.height)
    {
      currentLineHighlightView?.frame = highlightRect
    } else
    // OR the insertion point is behind the end of the text, which does NOT end with a trailing newline
    if let previousLocation = optTextContentStorage?.location(location, offsetBy: -1),
       let fragmentFrame    = textLayoutManager.textLayoutFragment(for: previousLocation)?.layoutFragmentFrame,
       let highlightRect    = lineBackgroundRect(y: fragmentFrame.minY, height: fragmentFrame.height)
    {
      currentLineHighlightView?.frame = highlightRect
    } else
    // OR the document is empty
    if text.isEmpty,
       let highlightRect = lineBackgroundRect(y: 0, height: font?.lineHeight ?? 0)
    {
      currentLineHighlightView?.frame = highlightRect
    }
  }

  func updateMessageLineHighlights() {
    // NOTE: Removed ensureLayout() call - layout should already be available from TextKit 2

    for messageView in messageViews {

      if let telescopeCharacterIndex = messageView.value.characterIndexTelescope,
         !messageView.value.invalidated     // No telesopes for invalidates messages
      {

        if let startLocation  = optTextContentStorage?.textLocation(for: messageView.value.characterIndex),
           let endLocation    = optTextContentStorage?.textLocation(for: telescopeCharacterIndex),
           let textRange      = NSTextRange(location: startLocation, end: endLocation),
           let extent         = optTextLayoutManager?.textLayoutFragmentExtent(for: textRange),
           let highlightRect  = lineBackgroundRect(y: extent.y, height: extent.height)
        {
          messageView.value.backgroundView.frame = highlightRect
        }

      } else {

        if let textLocation  = optTextContentStorage?.textLocation(for: messageView.value.characterIndex),
           let fragmentFrame = optTextLayoutManager?.textLayoutFragment(for: textLocation)?.layoutFragmentFrameWithoutExtraLineFragment,
           let highlightRect = lineBackgroundRect(y: fragmentFrame.minY, height: fragmentFrame.height),
           messageView.value.backgroundView.frame != highlightRect
        {
          messageView.value.backgroundView.frame = highlightRect
        }
      }
    }
  }

  
  // MARK: Tiling
  
  /// Ensure that layout of the viewport region is complete.
  ///
  func ensureLayout(includingMinimap: Bool = true) {
    if let textLayoutManager {
      textLayoutManager.ensureLayout(for: textLayoutManager.textViewportLayoutController.viewportBounds)
    }
    if includingMinimap,
       let textLayoutManager = minimapView?.textLayoutManager
    {
      textLayoutManager.ensureLayout(for: textLayoutManager.textViewportLayoutController.viewportBounds)
    }
  }

  /// Pre-tokenize visible viewport lines synchronously with a time budget.
  /// This ensures instant syntax highlighting on first render without blocking indefinitely.
  ///
  /// - Parameter timeBudgetMs: Maximum time to spend tokenizing in milliseconds.
  ///
  private func preTokenizeVisibleViewport(timeBudgetMs: Double) {
    guard let codeStorage = optCodeStorage as? CodeStorage else { return }

    let deadline = CFAbsoluteTimeGetCurrent() + (timeBudgetMs / 1000.0)

    // Estimate visible lines based on viewport height and line height
    let lineHeight = theme.font.lineHeight
    let visibleLineCount = Int(ceil(documentVisibleRect.height / lineHeight))

    // Start from line 0 (top of viewport on initial load)
    let startLine = 0
    let endLine = min(startLine + visibleLineCount + 10, codeStorageDelegate.lineMap.lines.count) // +10 buffer

    var tokenizedCount = 0
    for line in startLine..<endLine {
      // Check time budget
      if CFAbsoluteTimeGetCurrent() >= deadline {
        break
      }

      guard line < codeStorageDelegate.lineMap.lines.count else { break }

      let lineInfo = codeStorageDelegate.lineMap.lines[line].info
      if lineInfo == nil || lineInfo?.tokenizationState != .tokenized {
        if let lineRange = codeStorageDelegate.lineMap.lookup(line: line)?.range {
          let _ = codeStorageDelegate.tokenise(range: lineRange, in: codeStorage, maxTrailingLines: 1)
          codeStorageDelegate.setTokenizationState(.tokenized, for: line..<(line + 1))
          tokenizedCount += 1
        }
      }
    }
  }

  /// Update cached document heights from line count.
  /// For monospaced fonts without word wrap, this is exact (lineCount × lineHeight).
  /// For word wrap, uses HeightEstimator which progressively refines the estimate.
  ///
  func updateDocumentHeightsFromLineCount() {
    let lineCount = codeStorageDelegate.lineMap.lines.count
    if let estimator = heightEstimator {
      cachedCodeHeight = estimator.estimatedHeight(for: lineCount)
      cachedMinimapHeight = estimator.estimatedMinimapHeight(for: lineCount)
    } else {
      let lineHeight = theme.font.lineHeight
      cachedCodeHeight = CGFloat(lineCount) * lineHeight
      cachedMinimapHeight = CGFloat(lineCount) * (lineHeight / minimapRatio)
    }
  }

  /// Perform initial document setup with viewport-only layout.
  /// Height is calculated from line count (exact for monospaced fonts).
  /// NEVER does full document layout - TextKit 2 handles on-demand layout.
  ///
  func performInitialLayout() {
    guard let mainTextLayoutManager = optTextLayoutManager else { return }

    // Calculate heights from line count (instant - no layout needed)
    updateDocumentHeightsFromLineCount()

    // Set frame height from estimated height
    if let estimatedHeight = cachedCodeHeight {
      let minHeight = max(estimatedHeight, documentVisibleRect.height)
#if os(iOS) || os(visionOS)
      if frame.size.height != minHeight {
        frame.size.height = minHeight
      }
      // Update content size for scroll view
      let newContentSize = CGSize(width: bounds.width, height: minHeight)
      if contentSize != newContentSize {
        contentSize = newContentSize
      }
#elseif os(macOS)
      if frame.size.height != minHeight {
        setFrameSize(NSSize(width: frame.size.width, height: minHeight))
      }
#endif
    }

    // Pre-tokenize visible viewport synchronously with time budget for instant highlighting
    preTokenizeVisibleViewport(timeBudgetMs: 16)

    // Layout ONLY the visible viewport - TextKit 2 handles the rest on-demand
    mainTextLayoutManager.textViewportLayoutController.layoutViewport()

    // Layout minimap viewport if visible
    if viewLayout.showMinimap, let minimapLayoutManager = minimapView?.textLayoutManager {
      minimapLayoutManager.textViewportLayoutController.layoutViewport()
    }

    // Update current line highlight and message highlights
    if let textLocation = optTextContentStorage?.textLocation(for: selectedRange.location) {
      updateCurrentLineHighlight(for: textLocation)
    }
    updateMessageLineHighlights()

    // Position the minimap correctly
    adjustScrollPositionOfMinimap()

    // Trigger tokenization for the visible viewport lines
    if let viewportRange = mainTextLayoutManager.textViewportLayoutController.viewportRange,
       let textContentStorage = optTextContentStorage {
      let charRange = textContentStorage.range(for: viewportRange)
      let visibleLines = codeStorageDelegate.lineMap.linesContaining(range: charRange)

      // Update background tokenizer with visible viewport
      backgroundTokenizer.viewportDidChange(startLine: visibleLines.lowerBound,
                                             endLine: visibleLines.upperBound)

      // Update viewport predictor and set priority viewport for pre-tokenization
      let totalLines = codeStorageDelegate.lineMap.lines.count
      let predictedViewport = viewportPredictor.predictedViewport(current: visibleLines, totalLines: totalLines)
      backgroundTokenizer.setPriorityViewport(predictedViewport)
    }
  }

  /// Legacy method name for compatibility - calls performInitialLayout
  ///
  func performFullDocumentLayout() {
    performInitialLayout()
  }

  /// Position and size the gutter and minimap and set the text container sizes and exclusion paths. Take the current
  /// view layout in `viewLayout` into account.
  ///
  /// * The main text view contains three subviews: (1) the main gutter on its left side, (2) the minimap on its right
  ///   side, and (3) a divider in between the code view and the minimap gutter.
  /// * The main text view by way of `lineFragmentRect(forProposedRect:at:writingDirection:remaining:)`and the minimap
  ///   view (or rather their text container) by way of an exclusion path keep text out of the gutter view. The main
  ///   text view is moreover sized to avoid overlap with the minimap.
  /// * The minimap is a fixed factor `minimapRatio` smaller than the main text view and uses a correspondingly smaller
  ///   font accomodate exactly the same number of characters, so that line breaking procceds in the exact same way.
  ///
  /// NB: We don't use a ruler view for the gutter on macOS to be able to use the same setup on macOS and iOS.
  ///
  @MainActor
  private func tile() {
    guard let codeContainer = optTextContainer as? CodeContainer else { return }

    // Prevent recursive layout cycles - if we're already tiling, mark pending work and return
    guard !isTiling else {
      hasPendingLayoutWork = true
      return
    }

    isTiling = true
    defer {
      isTiling = false
      cachedDocumentVisibleRect = nil
      if hasPendingLayoutWork {
        hasPendingLayoutWork = false
        // Defer to next runloop to break recursion chain
        DispatchQueue.main.async { [weak self] in
#if os(macOS)
          self?.needsLayout = true
#else
          self?.setNeedsLayout()
#endif
        }
      }
    }

    // Cache documentVisibleRect once at the start to avoid forcing layout during this method
    let visibleRect = self.documentVisibleRect
    cachedDocumentVisibleRect = visibleRect

    // Batch all frame updates to reduce layout passes and disable implicit animations
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    defer { CATransaction.commit() }

#if os(macOS)
    // Add the floating views if they are not yet in the view hierachy.
    // NB: Since macOS 14, we need to explicitly set clipping; otherwise, views will draw outside of the bounds of the
    //     scroll view. We need to do this vor each view, as it is not guaranteed that they share a container view.
    if let view = gutterView, view.superview == nil {
      enclosingScrollView?.addFloatingSubview(view, for: .horizontal)
      view.superview?.clipsToBounds = true
    }
    if let view = minimapDividerView, view.superview == nil {
      enclosingScrollView?.addFloatingSubview(view, for: .horizontal)
      view.superview?.clipsToBounds = true
    }
    if let view = minimapView, view.superview == nil {
      enclosingScrollView?.addFloatingSubview(view, for: .horizontal)
      view.superview?.clipsToBounds = true
    }
#endif

    // Compute size of the main view gutter
    //
    let theFont                 = font ?? OSFont.systemFont(ofSize: 0),
        fontWidth               = theFont.maximumHorizontalAdvancement,  // NB: we deal only with fixed width fonts
        gutterWidthInCharacters = CGFloat(7),
        gutterWidth             = ceil(fontWidth * gutterWidthInCharacters),
        // Use cached height from line count (more accurate than contentSize which may lag)
        estimatedHeight         = cachedCodeHeight ?? (CGFloat(codeStorageDelegate.lineMap.lines.count) * theFont.lineHeight),
        minimumHeight           = max(estimatedHeight, visibleRect.height),
        gutterSize              = CGSize(width: gutterWidth, height: minimumHeight),
        lineFragmentPadding     = CGFloat(5)

    if gutterView?.frame.size != gutterSize { gutterView?.frame = CGRect(origin: .zero, size: gutterSize) }

    // Compute sizes of the minimap text view and gutter
    //
    let minimapFontWidth     = fontWidth / minimapRatio,
        minimapGutterWidth   = ceil(minimapFontWidth * gutterWidthInCharacters),
        dividerWidth         = CGFloat(1),
        minimapGutterRect    = CGRect(origin: CGPoint.zero,
                                      size: CGSize(width: minimapGutterWidth, height: minimumHeight)).integral,
        minimapExtras        = minimapGutterWidth + dividerWidth,
        gutterWithPadding    = gutterWidth + lineFragmentPadding,
        visibleWidth         = visibleRect.width,
        widthWithoutGutters  = if viewLayout.showMinimap { visibleWidth - gutterWithPadding - minimapExtras }
                               else { visibleWidth - gutterWithPadding },
        compositeFontWidth   = if viewLayout.showMinimap { fontWidth + minimapFontWidth } else { fontWidth },
        availableWidth       = max(CGFloat(0), widthWithoutGutters),
        numberOfCharacters   = max(0, Int(floor(availableWidth / compositeFontWidth))),
        codeAreaWidth        = CGFloat(numberOfCharacters) * fontWidth,
        codeViewWidth        = if viewLayout.showMinimap { gutterWithPadding + codeAreaWidth }
                               else { visibleWidth },
        minimapWidth         = visibleWidth - codeViewWidth,
        minimapX             = floor(visibleWidth - minimapWidth),
        minimapExclusionPath = OSBezierPath(rect: minimapGutterRect),
        minimapDividerRect   = CGRect(x: minimapX - dividerWidth, y: 0, width: dividerWidth, height: minimumHeight).integral

    minimapDividerView?.isHidden = !viewLayout.showMinimap
    minimapView?.isHidden        = !viewLayout.showMinimap
    if let minimapViewFrame = minimapView?.frame,
       viewLayout.showMinimap
    {

      if minimapDividerView?.frame != minimapDividerRect { minimapDividerView?.frame = minimapDividerRect }
      if minimapViewFrame.origin.x != minimapX || minimapViewFrame.width != minimapWidth {

        minimapView?.frame       = CGRect(x: minimapX,
                                          y: minimapViewFrame.minY,
                                          width: minimapWidth,
                                          height: minimapViewFrame.height)
        minimapGutterView?.frame = minimapGutterRect
#if os(macOS)
        minimapView?.minSize     = CGSize(width: minimapFontWidth, height: visibleRect.height)
#endif

      }
    }

#if os(iOS) || os(visionOS)
    showsHorizontalScrollIndicator = !viewLayout.wrapText
    if viewLayout.wrapText && frame.size.width != visibleWidth { frame.size.width = visibleWidth }  // don't update frames in vain
#elseif os(macOS)
    enclosingScrollView?.hasHorizontalScroller = !viewLayout.wrapText
    isHorizontallyResizable                    = !viewLayout.wrapText
    if !isHorizontallyResizable && frame.size.width != visibleWidth { frame.size.width = visibleWidth }  // don't update frames in vain
#endif

    // Set the text container area of the main text view to reach up to the minimap
    // NB: We use the `excess` width to capture the slack that arises when the window width admits a fractional
    //     number of characters. Adding the slack to the code view's text container size doesn't work as the line breaks
    //     of the minimap and main code view are then sometimes not entirely in sync.
    let codeContainerWidth = if viewLayout.wrapText { lineFragmentPadding + codeAreaWidth } else { CGFloat.greatestFiniteMagnitude }

    // Update height estimator configuration when container width changes (affects word wrap height calculations)
    if let estimator = heightEstimator {
      let newConfig = HeightEstimator.Configuration(
        font: theFont,
        wrapText: viewLayout.wrapText,
        containerWidth: codeContainerWidth,
        minimapRatio: minimapRatio
      )
      estimator.updateConfiguration(newConfig)
    }

    if codeContainer.size.width != codeContainerWidth {
      codeContainer.size = CGSize(width: codeContainerWidth, height: CGFloat.greatestFiniteMagnitude)
      // Container width changed - invalidate and recalculate document heights
      invalidateDocumentHeightCache()
    }

    codeContainer.lineFragmentPadding = lineFragmentPadding
#if os(macOS)
    if textContainerInset.width != gutterWidth {
      textContainerInset = CGSize(width: gutterWidth, height: 0)
    }
    // Set minSize to prevent NSTextView from shrinking below content height
    // This ensures the scroll view maintains the full scrollable area when the view shrinks
    let newMinSize = CGSize(width: visibleWidth, height: minimumHeight)
    if minSize != newMinSize {
      minSize = newMinSize
    }
    // Ensure frame height matches our calculated height (prevents scroll indicator issues)
    // Use super.setFrameSize to avoid triggering the override while tiling
    if frame.size.height != minimumHeight {
      super.setFrameSize(NSSize(width: frame.size.width, height: minimumHeight))
    }
#elseif os(iOS) || os(visionOS)
    if textContainerInset.left != gutterWidth {
      textContainerInset = UIEdgeInsets(top: 0, left: gutterWidth, bottom: 0, right: 0)
    }
    // Ensure content size reflects the full document height for proper scrolling
    // UITextView inherits from UIScrollView, so contentSize determines the scrollable area
    let newContentSize = CGSize(width: bounds.width, height: minimumHeight)
    if contentSize != newContentSize {
      contentSize = newContentSize
    }
#endif

    // Set the width of the text container for the minimap just like that for the code view as the layout engine works
    // on the original code view metrics. (Only after the layout is done, we scale it down to the size of the minimap.)
    let minimapTextContainerWidth = codeContainerWidth
    let minimapTextContainer = minimapView?.textContainer
    if minimapWidth != minimapView?.frame.width || minimapTextContainerWidth != minimapTextContainer?.size.width {

      minimapTextContainer?.exclusionPaths      = [minimapExclusionPath]
      minimapTextContainer?.size                = CGSize(width: minimapTextContainerWidth,
                                                               height: CGFloat.greatestFiniteMagnitude)
      minimapTextContainer?.lineFragmentPadding = 0

    }

    // NOTE: Removed highlight updates from tile() - these are now only called on selection/message changes
    // updateCurrentLineHighlight() is called from updateBackgroundFor() when selection changes
    // updateMessageLineHighlights() is called from update(messages:) when messages change

    // Update viewport predictor with scroll position
    viewportPredictor.update(scrollOffset: visibleRect.origin.y)

    // Notify background tokenizer of viewport changes for deferred tokenization (debounced)
    // This reduces tokenization triggers from 60+ per second during scrolling to ~20
    viewportChangeWorkItem?.cancel()
    viewportChangeWorkItem = DispatchWorkItem { [weak self] in
      guard let self,
            let textLayoutManager = self.optTextLayoutManager,
            let viewportRange = textLayoutManager.textViewportLayoutController.viewportRange,
            let textContentStorage = self.optTextContentStorage
      else { return }
      let charRange = textContentStorage.range(for: viewportRange)
      let visibleLines = self.codeStorageDelegate.lineMap.linesContaining(range: charRange)

      // Update background tokenizer with visible viewport
      self.backgroundTokenizer.viewportDidChange(startLine: visibleLines.lowerBound,
                                                  endLine: visibleLines.upperBound)

      // Set priority viewport for pre-tokenization based on scroll velocity
      let totalLines = self.codeStorageDelegate.lineMap.lines.count
      let predictedViewport = self.viewportPredictor.predictedViewport(current: visibleLines, totalLines: totalLines)
      self.backgroundTokenizer.setPriorityViewport(predictedViewport)

      // Update document height when word wrap is enabled
      // This allows progressive height refinement as the user scrolls and new lines are measured
      if self.viewLayout.wrapText {
        self.updateDocumentHeightsFromLineCount()
        // Update frame if height changed significantly (prevents jitter during scroll)
        if let estimatedHeight = self.cachedCodeHeight {
          let currentHeight = self.frame.size.height
          let minHeight = max(estimatedHeight, self.documentVisibleRect.height)
          // Only update if difference is significant (more than one line height)
          if abs(currentHeight - minHeight) > self.theme.font.lineHeight {
#if os(macOS)
            self.setFrameSize(NSSize(width: self.frame.size.width, height: minHeight))
#else
            self.frame.size.height = minHeight
            self.contentSize = CGSize(width: self.bounds.width, height: minHeight)
#endif
          }
        }
      }
    }
    if let workItem = viewportChangeWorkItem {
      DispatchQueue.main.asyncAfter(deadline: .now() + viewportChangeDebounceInterval, execute: workItem)
    }
  }


  // MARK: Scrolling

  /// Sets the scrolling position of the minimap in dependence of the scroll position of the main code view.
  ///
  func adjustScrollPositionOfMinimap() {
    guard viewLayout.showMinimap,
          minimapView?.textLayoutManager != nil,
          optTextLayoutManager != nil
    else { return }

    // Throttle minimap updates during rapid scrolling to avoid expensive frame updates
    let now = CFAbsoluteTimeGetCurrent()
    guard now - lastMinimapUpdateTime >= minimapUpdateThrottleInterval else { return }
    lastMinimapUpdateTime = now

    // Use cached heights from performFullDocumentLayout().
    // If cache is not yet populated, skip minimap positioning.
    guard let codeHeight = cachedCodeHeight,
          let minimapHeight = cachedMinimapHeight
    else { return }

    // Use cached documentVisibleRect if available (set by tile()) to avoid forcing layout
    let visibleRect = cachedDocumentVisibleRect ?? documentVisibleRect
    let visibleHeight = visibleRect.size.height

#if os(iOS) || os(visionOS)
    // We need to force the scroll view (superclass of `UITextView`) to accomodate the whole content without scrolling
    // and to extent over the whole visible height. (On macOS, the latter is enforced by setting `minSize` in `tile()`.)
    let minimapMinimalHeight = max(minimapHeight, visibleRect.height)
    if let currentHeight = minimapView?.frame.size.height,
       minimapMinimalHeight > currentHeight
    {
      minimapView?.frame.size.height = minimapMinimalHeight
    }
#endif

    let scrollFactor: CGFloat = if minimapHeight < visibleHeight || codeHeight <= visibleHeight { 1 }
                                else { 1 - (minimapHeight - visibleHeight) / (codeHeight - visibleHeight) }

    // We box the positioning of the minimap at the top and the bottom of the code view (with the `max` and `min`
    // expessions. This is necessary as the minimap will otherwise be partially cut off by the enclosing clip view.
    // To get Xcode-like behaviour, where the minimap sticks to the top, it being a floating view is not sufficient.
    let newOriginY = floor(min(max(visibleRect.origin.y * scrollFactor, 0),
                               codeHeight - minimapHeight))
    if minimapView?.frame.origin.y != newOriginY { minimapView?.frame.origin.y = newOriginY }  // don't update frames in vain

    let heightRatio: CGFloat = if codeHeight <= minimapHeight { 1 } else { minimapHeight / codeHeight }
    let minimapVisibleY      = visibleRect.origin.y * heightRatio,
        minimapVisibleHeight = visibleHeight * heightRatio,
        documentVisibleFrame = CGRect(x: 0,
                                      y: minimapVisibleY,
                                      width: minimapView?.bounds.size.width ?? 0,
                                      height: minimapVisibleHeight).integral
    if documentVisibleBox?.frame != documentVisibleFrame { documentVisibleBox?.frame = documentVisibleFrame }  // don't update frames in vain
  }


  // MARK: Message views

  /// Update the layout of the specified message view if its geometry got invalidated by
  /// `CodeTextContainer.lineFragmentRect(forProposedRect:at:writingDirection:remaining:)`.
  ///
  fileprivate func layoutMessageView(identifiedBy id: UUID) {

    guard let textLayoutManager  = textLayoutManager,
          let textContentManager = textLayoutManager.textContentManager as? NSTextContentStorage,
          let codeContainer      = optTextContainer as? CodeContainer,
          let messageBundle      = messageViews[id]
    else { return }

    if messageBundle.geometry == nil {

      guard let startLocation         = textContentManager.textLocation(for: messageBundle.characterIndex),
            let textLayoutFragment    = textLayoutManager.textLayoutFragment(for: startLocation),
            let firstLineFragmentRect = textLayoutFragment.textLineFragments.first?.typographicBounds
      else { return }

      // Compute the message view geometry from the text layout information
      let geometry = MessageView.Geometry(lineWidth: messageBundle.lineFragementRect.width - firstLineFragmentRect.maxX,
                                          lineHeight: firstLineFragmentRect.height,
                                          popupWidth:
                                            (codeContainer.size.width - MessageView.popupRightSideOffset) * 0.75,
                                          popupOffset: textLayoutFragment.layoutFragmentFrame.height + 2)
      messageViews[id]?.geometry = geometry

      // Configure the view with the new geometry
      messageBundle.view.geometry = geometry
      if messageBundle.view.superview == nil {

        // Add the messages view
        addSubview(messageBundle.view)
        let topOffset           = textContainerOrigin.y + messageBundle.lineFragementRect.minY,
            topAnchorConstraint = messageBundle.view.topAnchor.constraint(equalTo: self.topAnchor,
                                                                          constant: topOffset)
        let leftOffset            = textContainerOrigin.x + messageBundle.lineFragementRect.maxX,
            rightAnchorConstraint = messageBundle.view.rightAnchor.constraint(equalTo: self.leftAnchor,
                                                                              constant: leftOffset)
        messageViews[id]?.topAnchorConstraint   = topAnchorConstraint
        messageViews[id]?.rightAnchorConstraint = rightAnchorConstraint
        NSLayoutConstraint.activate([topAnchorConstraint, rightAnchorConstraint])

        // Also add the corresponding background highlight view, such that it lies on top of the current line highlight.
        if let currentLineHighlightView {
          insertSubview(messageBundle.backgroundView, aboveSubview: currentLineHighlightView)
        }

      } else {

        // Update the messages view constraints
        let topOffset  = textContainerOrigin.y + messageBundle.lineFragementRect.minY,
            leftOffset = textContainerOrigin.x + messageBundle.lineFragementRect.maxX
        messageViews[id]?.topAnchorConstraint?.constant   = topOffset
        messageViews[id]?.rightAnchorConstraint?.constant = leftOffset

      }
    }
  }
  
  /// Update the whole set of current messages to a new set.
  ///
  /// - Parameter messages: The new set of messages.
  ///
  func update(messages: Set<TextLocated<Message>>) {

    // FIXME: Retracting all and then adding them again my be bad with animation if we re-add many of the same.
    retractMessages()
    for message in messages { report(message: message) }

    lastMessages = messages
  }

  /// Adds a new message to the set of messages for this code view.
  ///
  func report(message: TextLocated<Message>) {
    guard let messageBundle = codeStorageDelegate.add(message: message) else { return }

    updateMessageView(for: messageBundle, at: message.location.zeroBasedLine)
  }

  /// Removes a given message. If it doesn't exist, do nothing. This function is quite expensive.
  ///
  func retract(message: Message) {
    guard let (messageBundle, line) = codeStorageDelegate.remove(message: message) else { return }

    updateMessageView(for: messageBundle, at: line)
  }

  /// Given a new or updated message bundle, update the corresponding message view appropriately. This includes covering
  /// the two special cases, where we create a new view or we remove a view for good (as its last message got deleted).
  ///
  /// NB: The `line` argument is zero-based.
  ///
  private func updateMessageView(for messageBundle: LineInfo.MessageBundle, at line: Int) {
    guard let charRange = codeStorageDelegate.lineMap.lookup(line: line)?.range else { return }

    // NB: If the message info with that id has been invalidated, it just gets removed here, and hence, we don't have to
    //      worry about a mix of invalidated and new messages.
    removeMessageViews(withIDs: [messageBundle.id])

    // If we removed the last message of this view, we don't need to create a new version
    if messageBundle.messages.isEmpty { return }

    // TODO: CodeEditor needs to be parameterised by message theme
    let messageTheme = Message.defaultTheme

    #if os(iOS) || os(visionOS)
    let background  = SwiftUI.Color(backgroundColor!)
    #elseif os(macOS)
    let background  = SwiftUI.Color(backgroundColor)
    #endif

    let messageView = StatefulMessageView.HostingView(messages: messageBundle.messages.sorted{  $0.0 < $1.0 },
                                                      theme: messageTheme,
                                                      background: background,
                                                      geometry: MessageView.Geometry(lineWidth: 100,
                                                                                     lineHeight: 15,
                                                                                     popupWidth: 300,
                                                                                     popupOffset: 16),
                                                      fontSize: font?.pointSize ?? OSFont.systemFontSize,
                                                      colourScheme: theme.colourScheme),
        principalCategory = messagesByCategory(messageBundle.messages.map(\.1))[0].key,
        colour            = messageTheme(principalCategory).colour,
        backgroundView    = CodeBackgroundHighlightView(color: colour.withAlphaComponent(0.1)),
        telescope: Int?   = if messageBundle.messages.count == 1 { messageBundle.messages[0].1.telescope } else { nil }

    messageViews[messageBundle.id] = MessageInfo(view: messageView,
                                                 backgroundView: backgroundView,
                                                 characterIndex: 0,
                                                 telescope: telescope,
                                                 characterIndexTelescope: telescope.map{ _ in 0 },
                                                 lineFragementRect: .zero,
                                                 geometry: nil,
                                                 colour: colour,
                                                 invalidated: false)

    // We invalidate the layout of the line where the message belongs as their may be less space for the text now and
    // because the layout process for the text fills the `lineFragmentRect` property of the above `MessageInfo`.
    if let textRange = optTextContentStorage?.textRange(for: charRange) {

      optTextLayoutManager?.invalidateLayout(for: textRange)

    }
    updateMessageLineHighlights()
  }

  /// Remove the messages associated with a specified range of lines.
  ///
  /// - Parameter onLines: The line range where messages are to be removed. If `nil`, all messages on this code view are
  ///     to be removed.
  ///
  func retractMessages(onLines lines: Range<Int>? = nil) {
    var messageIds: [LineInfo.MessageBundle.ID] = []

    // Remove all message bundles in the line map and collect their ids for subsequent view removal.
    for line in lines ?? codeStorageDelegate.lineMap.lines.indices {

      if let messageBundle = codeStorageDelegate.messages(at: line) {

        messageIds.append(messageBundle.id)
        codeStorageDelegate.removeMessages(at: line)

      }

    }

    // Make sure to remove all views that are still around if necessary.
    if lines == nil { removeMessageViews() } else { removeMessageViews(withIDs: messageIds) }
  }

  /// Invalidate the message views with the given ids.
  ///
  /// - Parameter ids: The IDs of the message bundles that ought to be invalidated. If `nil`, invalidate all.
  ///
  /// IDs that do not have an associated message view cause no harm.
  ///
  fileprivate func invalidateMessageViews(withIDs ids: [LineInfo.MessageBundle.ID]? = nil) {

    for id in ids ?? Array<LineInfo.MessageBundle.ID>(messageViews.keys) {
      messageViews[id]?.invalidated = true
      if let info = messageViews[id] {

        info.backgroundView.color = OSColor.gray.withAlphaComponent(0.1)
        info.view.invalidated     = true

      }
    }
  }

  /// Remove the message views with the given ids.
  ///
  /// - Parameter ids: The IDs of the message bundles that ought to be removed. If `nil`, remove all.
  ///
  /// IDs that do not have an associated message view cause no harm.
  ///
  fileprivate func removeMessageViews(withIDs ids: [LineInfo.MessageBundle.ID]? = nil) {

    for id in ids ?? Array<LineInfo.MessageBundle.ID>(messageViews.keys) {

      if let info = messageViews[id] {
        info.view.removeFromSuperview()
        info.backgroundView.removeFromSuperview()
      }
      messageViews.removeValue(forKey: id)

    }
  }

  /// Ensure that all message views are in their collapsed state.
  ///
  func collapseMessageViews() {
    for messageView in messageViews {
      messageView.value.view.unfolded = false
    }
  }

  // MARK: Events


  func process(event: LanguageServiceEvent) {
    guard let codeStorage = optCodeStorage else { return }

    switch event {

    case .tokensAvailable(lineRange: let lineRange):
      Task { await codeStorageDelegate.requestSemanticTokens(for: lineRange, in: codeStorage) }
    }
  }
}


// MARK: Code container

final class CodeContainer: NSTextContainer {

  #if os(iOS) || os(visionOS)
  weak var textView: UITextView?
  #endif

  // We adapt line fragment rects in two ways: (1) we leave `gutterWidth` space on the left hand side and (2) on every
  // line that contains a message, we leave `MessageView.minimumInlineWidth` space on the right hand side (but only for
  // the first line fragment of a layout fragment).
  override func lineFragmentRect(forProposedRect proposedRect: CGRect,
                                 at characterIndex: Int,
                                 writingDirection baseWritingDirection: NSWritingDirection,
                                 remaining remainingRect: UnsafeMutablePointer<CGRect>?)
  -> CGRect
  { 
    let superRect      = super.lineFragmentRect(forProposedRect: proposedRect,
                                                at: characterIndex,
                                                writingDirection: baseWritingDirection,
                                                remaining: remainingRect),
        calculatedRect = CGRect(x: 0, y: superRect.minY, width: size.width, height: superRect.height)

    guard let codeView    = textView as? CodeView,
          let codeStorage = codeView.optCodeStorage,
          let delegate    = codeStorage.delegate as? CodeStorageDelegate,
          let line        = delegate.lineMap.lineOf(index: characterIndex),
          let oneLine     = delegate.lineMap.lookup(line: line),
          characterIndex == oneLine.range.location     // do the following only for the first line fragment of a line
    else { return calculatedRect }

    // On lines that contain messages, we reduce the width of the available line fragement rect such that there is
    // always space for a minimal truncated message (provided the text container is wide enough to accomodate that).
    if let messageBundleId = delegate.messages(at: line)?.id,
       calculatedRect.width > 2 * MessageView.minimumInlineWidth
    {

      codeView.messageViews[messageBundleId]?.characterIndex    = characterIndex
      codeView.messageViews[messageBundleId]?.lineFragementRect = calculatedRect
      codeView.messageViews[messageBundleId]?.geometry = nil                      // invalidate the geometry

      // If the bundle has a telescope, determine the telescope character index.

      if let lines   = codeView.messageViews[messageBundleId]?.telescope,
         let oneLine = delegate.lineMap.lookup(line: line + lines)
      {
        codeView.messageViews[messageBundleId]?.characterIndexTelescope = oneLine.range.max
      }

      // To fully determine the layout of the message view, typesetting needs to complete for this line; hence, we defer
      // configuring the view.
      DispatchQueue.main.async { codeView.layoutMessageView(identifiedBy: messageBundleId) }

      return CGRect(origin: calculatedRect.origin,
                    size: CGSize(width: calculatedRect.width - MessageView.minimumInlineWidth,
                                 height: calculatedRect.height))

    } else { return calculatedRect }
  }
}


// MARK: [Note NSTextViewportLayoutControllerDelegate]
//
// According to the TextKit 2 documentation, a 'NSTextViewportLayoutControllerDelegate' is the right place to be
// notified of the start and end of a layout pass. When using TextKit 2 with a standard 'NS/UITextView' there curiously
// is already a delegate set for the 'NSTextViewportLayoutController'. It uses a private class, so we cannot subclass
// it. The obvious alternative is to wrap it as in the code below. However, this leads to redraw problems on iOS (when
// repeatedly inserting and again deleting lines).
//
//final class CodeViewportLayoutControllerDelegate: NSObject, NSTextViewportLayoutControllerDelegate {
//
//  /// When TextKit 2 initialises a text view, it provides a default delegate for the `NSTextViewportLayoutController`.
//  /// We keep that here when overwriting it with an instance of this very class.
//  ///
//  let systemDelegate: any NSTextViewportLayoutControllerDelegate
//  
//  /// The code view to which this delegate belongs.
//  ///
//  weak var codeView: CodeView?
//
//  init(systemDelegate: any NSTextViewportLayoutControllerDelegate, codeView: CodeView) {
//    self.systemDelegate = systemDelegate
//    self.codeView       = codeView
//  }
//
//  public func viewportBounds(for textViewportLayoutController: NSTextViewportLayoutController) -> CGRect {
//    systemDelegate.viewportBounds(for: textViewportLayoutController)
//  }
//
//  public func textViewportLayoutController(_ textViewportLayoutController: NSTextViewportLayoutController,
//                                           configureRenderingSurfaceFor textLayoutFragment: NSTextLayoutFragment)
//  {
//    systemDelegate.textViewportLayoutController(textViewportLayoutController,
//                                                configureRenderingSurfaceFor: textLayoutFragment)
//  }
//
//  public func textViewportLayoutControllerWillLayout(_ textViewportLayoutController: NSTextViewportLayoutController) {
//    systemDelegate.textViewportLayoutControllerWillLayout?(textViewportLayoutController)
//  }
//
//  public func textViewportLayoutControllerDidLayout(_ textViewportLayoutController: NSTextViewportLayoutController) {
//    systemDelegate.textViewportLayoutControllerDidLayout?(textViewportLayoutController)
//
//    if let location     = codeView?.selectedRange.location,
//       let textLocation = codeView?.optTextContentStorage?.textLocation(for: location) {
//      codeView?.updateCurrentLineHighlight(for: textLocation)
//    }
//    codeView?.updateMessageLineHighlights()
//  }
//}


// MARK: Selection change management

/// Common code view actions triggered on a selection change.
///
func selectionDidChange<TV: TextView>(_ textView: TV) {
  guard let codeStorage  = textView.optCodeStorage,
        let visibleLines = textView.documentVisibleLines
  else { return }

  if let location             = textView.insertionPoint,
     let matchingBracketRange = codeStorage.matchingBracket(at: location, in: visibleLines)
  {
    textView.showFindIndicator(for: matchingBracketRange)
  }
}


// MARK: NSRange

/// Combine selection ranges into the smallest ranges encompassing them all.
///
private func combinedRanges(ranges: [NSValue]) -> NSRange {
  let actualranges = ranges.compactMap{ $0 as? NSRange }
  return actualranges.dropFirst().reduce(actualranges.first ?? .zero) {
    NSUnionRange($0, $1)
  }
}
