//
//  CodeActions.swift
//  
//
//  Created by Manuel M T Chakravarty on 31/01/2023.
//

import Combine
import SwiftUI
import os
@preconcurrency import ObjectiveC

import LanguageSupport


private let logger = Logger(subsystem: "org.justtesting.CodeEditorView", category: "CodeActions")


#if os(iOS) || os(visionOS)

// MARK: -
// MARK: UIKit version

import UIKit

// MARK: Completions support for iOS

/// The various operations that arise through the user interacting with the completion overlay on iOS.
///
public enum CompletionProgressiOS {

  /// Cancel code completion (e.g., user tapped outside).
  ///
  case cancel

  /// Completion selected and the range it replaces if available.
  ///
  case completion(String, NSRange?)
}

/// Overlay view used to display completions on iOS.
///
final class CompletionOverlayView: UIView {

  struct CompletionViewiOS: View {
    @Bindable var viewState: ObservableViewState

    @ViewBuilder
    var completionsList: some View {
      if viewState.completions.items.isEmpty {
        Text("No Completions")
          .foregroundStyle(.secondary)
          .padding()
      } else {
        ScrollViewReader { proxy in
          ScrollView {
            LazyVStack(spacing: 0) {
              ForEach(viewState.completions.items) { item in
                Button {
                  viewState.selectedId = item.id
                  viewState.onSelect?(item)
                } label: {
                  AnyView(item.rowView(viewState.selectedId == item.id))
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .id(item.id)
              }
            }
            .padding(10)
          }
          .onChange(of: viewState.selectedId) { oldValue, newValue in
            if let id = newValue {
              withAnimation(.easeInOut(duration: 0.15)) {
                proxy.scrollTo(id, anchor: .center)
              }
            }
          }
          .onAppear {
            // Scroll to initial selection
            if let id = viewState.selectedId {
              DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                proxy.scrollTo(id, anchor: .top)
              }
            }
          }
        }
      }
    }

    var body: some View {
      Group {
        if viewState.completions.items.isEmpty {
          Text("No Completions")
            .foregroundStyle(.secondary)
            .frame(width: 200, height: 50)
        } else {
          completionsList
            .frame(minHeight: 100, maxHeight: 250)
            .frame(minWidth: 280, maxWidth: 350)
        }
      }
      .containerShape(.rect(cornerRadius: 20))
      .clipShape(.rect(cornerRadius: 20))
      .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 20))
    }
  }

  /// This class encapsulates the state that may change while a completion overlay is being displayed.
  ///
  @Observable
  class ObservableViewState {
    var selectedId:  Int?
    var completions: Completions
    var onSelect:    ((Completions.Completion) -> Void)?

    init(completions: Completions = .none) {
      self.selectedId  = nil
      self.completions = completions
    }
  }

  /// The current set of completions and the `id` of the currently selected item.
  ///
  private(set) var viewState: ObservableViewState = ObservableViewState()

  /// Progress handler to report completion selection back to the code view.
  ///
  var progressHandler: ((CompletionProgressiOS) -> Void)?

  /// The hosting controller for the SwiftUI completion view.
  ///
  private var hostingController: UIHostingController<CompletionViewiOS>?

  /// The task resolving completion items (if active).
  ///
  private var resolveTask: Task<Void, any Error>?

  override init(frame: CGRect) {
    super.init(frame: frame)
    setupView()
  }

  required init?(coder: NSCoder) {
    super.init(coder: coder)
    setupView()
  }

  private func setupView() {
    backgroundColor = .clear

    let hostingController = UIHostingController(rootView: CompletionViewiOS(viewState: viewState))
    hostingController.view.backgroundColor = .clear
    self.hostingController = hostingController

    addSubview(hostingController.view)
    hostingController.view.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      hostingController.view.topAnchor.constraint(equalTo: topAnchor),
      hostingController.view.leadingAnchor.constraint(equalTo: leadingAnchor),
      hostingController.view.trailingAnchor.constraint(equalTo: trailingAnchor),
      hostingController.view.bottomAnchor.constraint(equalTo: bottomAnchor),
    ])

    // Set up selection handler
    viewState.onSelect = { [weak self] item in
      self?.progressHandler?(.completion(item.insertText, item.insertRange))
    }
  }

  /// Set a list of completions and position the overlay.
  ///
  /// - Parameters:
  ///   - completions: The new list of completions.
  ///   - handler: Closure used to report progress in the completion interaction back to the code view.
  ///
  func set(completions: Completions, handler: @escaping (CompletionProgressiOS) -> Void) {
    // Cancel any still running resolve task
    resolveTask?.cancel()

    self.viewState = ObservableViewState(completions: completions)
    self.progressHandler = handler

    // Re-setup selection handler for new viewState
    viewState.onSelect = { [weak self] item in
      self?.progressHandler?(.completion(item.insertText, item.insertRange))
    }

    // The initial selection is the first item marked as selected, if any, or otherwise, the first item in the list.
    viewState.selectedId = if let selected = (completions.items.first{ $0.selected }) { selected.id }
                           else { completions.items.first?.id }

    // Update the view
    hostingController?.rootView = CompletionViewiOS(viewState: self.viewState)

    // Resize to fit content
    hostingController?.view.invalidateIntrinsicContentSize()
    sizeToFit()

    // Refine all refinable items.
    resolveTask = Task { @MainActor [weak self] in
      guard let self else { return }
      for item in self.viewState.completions.items.enumerated() {
        if let refinedItem = try? await item.element.refine() {
          try Task.checkCancellation()
          self.viewState.completions.items[item.offset] = refinedItem
        }
      }
    }
  }

  override var intrinsicContentSize: CGSize {
    hostingController?.view.intrinsicContentSize ?? CGSize(width: 280, height: 150)
  }

  override func sizeThatFits(_ size: CGSize) -> CGSize {
    hostingController?.view.sizeThatFits(size) ?? CGSize(width: 280, height: 150)
  }

  /// Move selection up in the list.
  ///
  func selectPrevious() {
    guard let currentIndex = viewState.completions.items.firstIndex(where: { $0.id == viewState.selectedId }),
          currentIndex > 0
    else { return }
    viewState.selectedId = viewState.completions.items[currentIndex - 1].id
  }

  /// Move selection down in the list.
  ///
  func selectNext() {
    guard let currentIndex = viewState.completions.items.firstIndex(where: { $0.id == viewState.selectedId }),
          currentIndex + 1 < viewState.completions.items.count
    else { return }
    viewState.selectedId = viewState.completions.items[currentIndex + 1].id
  }

  /// Commit to the current selection.
  ///
  func commitSelection() {
    if let selectedCompletion = viewState.completions.items.first(where: { $0.id == viewState.selectedId }) {
      progressHandler?(.completion(selectedCompletion.insertText, selectedCompletion.insertRange))
    } else {
      progressHandler?(.cancel)
    }
  }
}

extension CodeView {

  // MARK: Completion overlay

  /// Holds the completion overlay view.
  ///
  private static var completionOverlayKey = "completionOverlayKey"
  private static var completionTaskKey = "completionTaskKey"

  var completionOverlay: CompletionOverlayView {
    if let overlay = objc_getAssociatedObject(self, &CodeView.completionOverlayKey) as? CompletionOverlayView {
      return overlay
    }
    let overlay = CompletionOverlayView(frame: .zero)
    objc_setAssociatedObject(self, &CodeView.completionOverlayKey, overlay, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    return overlay
  }

  var completionTask: Task<(), Error>? {
    get { objc_getAssociatedObject(self, &CodeView.completionTaskKey) as? Task<(), Error> }
    set { objc_setAssociatedObject(self, &CodeView.completionTaskKey, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
  }

  /// Whether the completion overlay is currently visible.
  ///
  var isCompletionVisible: Bool {
    completionOverlay.superview != nil
  }

  /// Dismiss the completion overlay.
  ///
  func dismissCompletion() {
    // Clear the handler first to prevent recursive calls (handler calls dismissCompletion on .cancel)
    completionOverlay.progressHandler = nil
    completionOverlay.removeFromSuperview()
  }

  /// Compute the range for user completion (the word prefix before the cursor).
  ///
  var rangeForUserCompletion: NSRange {
    guard let codeStorage = textStorage as? CodeStorage else {
      return NSRange(location: selectedRange.location, length: 0)
    }

    let text = codeStorage.string as NSString
    let location = selectedRange.location
    var start = location

    let identifierChars = CharacterSet.alphanumerics.union(.init(charactersIn: "_"))

    // Walk backwards to find the start of the identifier
    while start > 0 {
      let char = text.character(at: start - 1)
      if let scalar = UnicodeScalar(char), identifierChars.contains(scalar) {
        start -= 1
      } else {
        break
      }
    }

    return NSRange(location: start, length: location - start)
  }

  /// Sets a new list of completions and positions the completions overlay such that it is aligned with the cursor.
  ///
  /// - Parameters:
  ///   - completions: The new list of completions to be displayed.
  ///   - range: The characters range at whose leading edge the completion overlay is to be aligned.
  ///   - explicitTrigger: The completion computation was explicitly triggered.
  ///
  @MainActor
  func show(completions: Completions, for range: NSRange, explicitTrigger: Bool) {

    // Don't show if no completions and not explicitly triggered
    if completions.items.isEmpty && !explicitTrigger {
      dismissCompletion()
      return
    }

    completionOverlay.set(completions: completions) { [weak self] completionProgress in

      switch completionProgress {

      case .cancel:
        self?.dismissCompletion()

      case .completion(let insertText, let insertRange):
        // Replace the completion range with the insert text
        if let self,
           let rangeToReplace = insertRange ?? Optional(self.rangeForUserCompletion),
           let start = self.position(from: self.beginningOfDocument, offset: rangeToReplace.location),
           let end = self.position(from: self.beginningOfDocument, offset: rangeToReplace.location + rangeToReplace.length),
           let textRange = self.textRange(from: start, to: end)
        {
          self.replace(textRange, withText: insertText)
        }
        self?.dismissCompletion()
      }
    }

    // Position the overlay near the cursor
    positionCompletionOverlay(for: range)

    // Add to view if not already visible
    if !isCompletionVisible {
      addSubview(completionOverlay)
    }
  }

  /// Position the completion overlay near the given character range.
  ///
  private func positionCompletionOverlay(for range: NSRange) {
    guard let textLayoutManager = optTextLayoutManager,
          let textContentStorage = optTextContentStorage,
          let textRange = textContentStorage.textRange(for: range)
    else { return }

    // Get the bounding rect for the range
    var cursorRect = CGRect.zero
    textLayoutManager.enumerateTextSegments(in: textRange,
                                            type: .standard,
                                            options: []) { _, segmentFrame, _, _ in
      cursorRect = segmentFrame
      return false
    }

    if cursorRect == .zero {
      // Fallback: use caret rect
      if let position = position(from: beginningOfDocument, offset: range.location),
         let rect = caretRect(for: position) as CGRect? {
        cursorRect = rect
      }
    }

    // Offset by text container inset
    cursorRect = cursorRect.offsetBy(dx: textContainerInset.left, dy: textContainerInset.top)

    // Size the overlay
    let overlaySize = completionOverlay.sizeThatFits(CGSize(width: 350, height: 300))

    // Position below the cursor by default
    var overlayX = cursorRect.minX
    var overlayY = cursorRect.maxY + 4

    // Ensure the overlay stays within bounds
    let maxX = bounds.width - overlaySize.width - 8
    let maxY = bounds.height - overlaySize.height - 8

    overlayX = min(max(8, overlayX), maxX)

    // If there's not enough space below, show above
    if overlayY + overlaySize.height > bounds.height - 8 {
      overlayY = cursorRect.minY - overlaySize.height - 4
    }
    overlayY = max(8, overlayY)

    completionOverlay.frame = CGRect(x: overlayX, y: overlayY, width: overlaySize.width, height: overlaySize.height)
  }

  /// Actually do query the language service for code completions and display them.
  ///
  /// - Parameters:
  ///   - location: The character location for which code completions are requested.
  ///   - explicitTrigger: The completion computation was explicitly triggered.
  ///
  func computeAndShowCompletions(at location: Int, explicitTrigger: Bool) async throws {
    guard let languageService = optLanguageService else { return }

    do {

      let reason: CompletionTriggerReason = if isCompletionVisible { .incomplete } else { .standard },
          completions                     = try await languageService.completions(at: location, reason: reason)
      try Task.checkCancellation()   // may have been cancelled in the meantime due to further user action
      show(completions: completions, for: rangeForUserCompletion, explicitTrigger: explicitTrigger)

    } catch let error { logger.trace("Completion action failed: \(error.localizedDescription)") }
  }

  /// Explicitly user initiated completion action by a command or trigger character.
  ///
  func completionAction() {

    // Stop any already running completion task
    completionTask?.cancel()

    // If we already show the completion overlay close it — we want the shortcut to toggle visibility. Otherwise,
    // initiate a completion task.
    if isCompletionVisible {

      dismissCompletion()

    } else {

      let location = selectedRange.location
      if let codeStorageDelegate = optCodeStorage?.delegate as? CodeStorageDelegate,
         !codeStorageDelegate.lineMap.isWithinComment(range: NSRange(location: location, length: 0))
      {
        completionTask = Task {
          try await computeAndShowCompletions(at: location, explicitTrigger: true)
        }
      }

    }
  }

  /// FIXME: This is language dependent and should take the language configuration into account.
  private static let identifierCharacterSet = CharacterSet.alphanumerics.union(.init(charactersIn: "_"))

  /// This function needs to be invoked whenever the completion range changes; i.e., once a text change has been made.
  ///
  /// - Parameter range: The current completion range (range of partial word in front of the insertion point) as
  ///       reported by the text view.
  ///
  func considerCompletionFor(range: NSRange) {

    /// We don't want to automatically trigger completion for ranges that do not produce sensible results, such as
    /// ranges of purely numeric characters. Moreover, we do not automatically trigger completions for ranges that end
    /// in the middle of an identifier.
    ///
    func rangeContentsWarrantsAutoCompletion() -> Bool {
      guard let codeStorage = optCodeStorage,
            let substring   = codeStorage.string[range]
      else { return false }

      // For now, we look for at least one letter.
      let atLeastOneLetter = substring.unicodeScalars.first{ CharacterSet.letters.contains($0) } != nil

      let notInMiddleOfIndentifier = if let next = codeStorage.string[NSRange(location: range.max, length: 1)],
                                        let nextCharacter = next.unicodeScalars.first
                                     {
                                       !CodeView.identifierCharacterSet.contains(nextCharacter)
                                     } else { true }

      return atLeastOneLetter && notInMiddleOfIndentifier
    }

    guard let codeStorageDelegate = optCodeStorage?.delegate as? CodeStorageDelegate else { return }

    // Stop any already running completion task
    completionTask?.cancel()

    let withinComment = codeStorageDelegate.lineMap.isWithinComment(range: NSRange(location: range.max, length: 0))

    // Close overlay if range becomes empty
    if range.length == 0 && isCompletionVisible {
      dismissCompletion()
      return
    }

    // Trigger completion for valid ranges
    let shouldTriggerCompletion = range.length > 0 && !withinComment && rangeContentsWarrantsAutoCompletion()
    let isTypingOrDeleting = codeStorageDelegate.processingOneCharacterAddition || isCompletionVisible

    if shouldTriggerCompletion && isTypingOrDeleting {

      completionTask = Task {

        // Delay completion a bit at the start of a word (the user may still be typing) unless the completion window
        // is already open.
        // NB: throws if task gets cancelled in the meantime.
        if range.length < 3 && !isCompletionVisible { try await Task.sleep(until: .now + .seconds(0.2)) }

        // Trigger completion
        try await computeAndShowCompletions(at: range.max, explicitTrigger: false)
      }

    } else if isCompletionVisible {

      // Close overlay if we're in an invalid completion context (e.g., inside comment, no valid prefix)
      dismissCompletion()

    }
  }

  // MARK: Code info (TODO)

  func infoAction() {
    // TODO: Implement info action for iOS
  }

  // MARK: Keyboard actions for completions

  @objc func completionSelectPrevious() {
    completionOverlay.selectPrevious()
  }

  @objc func completionSelectNext() {
    completionOverlay.selectNext()
  }

  @objc func completionCommit() {
    completionOverlay.commitSelection()
  }

  @objc func completionCancel() {
    dismissCompletion()
  }

  @objc func triggerCompletion() {
    completionAction()
  }
}


#elseif os(macOS)

// MARK: -
// MARK: AppKit version

// MARK: Code info support

/// Popover used to display the result of an info code query.
///
final class InfoPopover: NSPopover {

  /// Create an info popover with the given view displaying the code info.
  ///
  /// - Parameter view: the view displaying the queried code information.
  ///
  init(displaying view: any View, width: CGFloat) {
    super.init()
    let rootView = ViewThatFits(in: .vertical) {

        // The info view without a scroll view if it is small enough to fit vertically.
        AnyView(view).padding().fixedSize(horizontal: false, vertical: true)

        // The info view wrapped in a scroll view if it exceeds the popover.
        ScrollView(.vertical){ AnyView(view).padding() }
      }
      .frame(width: width)
      .frame(maxHeight: 800)
      .environment(\.openURL, OpenURLAction{ url in
        print(url)
//        Task {
//          try await NSWorkspace.shared.open([url], withApplicationAt: URL(fileURLWithPath: "/Applications/Safari.app"), configuration: .init())
//        }
//        return .systemAction(URL(string: "safari://")!)
        return .handled
      })
    let hostingController = NSHostingController(rootView: rootView)
    hostingController.sizingOptions = [.standardBounds, .preferredContentSize]
    contentViewController = hostingController
    behavior = .transient
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }
}

extension CodeView {

  /// Retain and display the given info popover.
  ///
  /// - Parameters:
  ///   - infoPopover: The new info popover to be displayed.
  ///   - range: The range of characters that the popover ought to refer to.
  ///
  @MainActor
  func show(infoPopover: InfoPopover, for range: NSRange) {

    // If there is already a popover, close it first.
    self.infoPopover?.close()

    self.infoPopover = infoPopover

    let screenRect         = firstRect(forCharacterRange: range, actualRange: nil),
        nonEmptyScreenRect = if screenRect.isEmpty {
                               NSRect(origin: screenRect.origin, size: CGSize(width: 1, height: 1))
                             } else { screenRect },
        windowRect         = window!.convertFromScreen(nonEmptyScreenRect)

    infoPopover.show(relativeTo: convert(windowRect, from: nil), of: self, preferredEdge: .maxY)
  }

  func infoAction() {
    guard let languageService = optLanguageService else { return }

    let width = min((window?.frame.width ?? 250) * 0.75, 500)

    let range = selectedRange()
    Task {
      do {
        if let info = try await languageService.info(at: range.location) {

          showFindIndicator(for: info.anchor ?? range)
          show(infoPopover: InfoPopover(displaying: info.view, width: width), for: info.anchor ?? range)

        }
      } catch let error { logger.trace("Info action failed: \(error.localizedDescription)") }
    }
  }
}


// MARK: Completions support

/// The various operations that arise through the user interacting with the completion panel.
///
public enum CompletionProgress {

  /// Cancel code completion (e.g., user pressed ESC).
  ///
  case cancel

  /// Completion selected and the range it replaces if available.
  ///
  case completion(String, NSRange?)

  /// Addtional keystroke to refine the search.
  ///
  case input(NSEvent)
}

/// Panel used to display completions.
///
final class CompletionPanel: NSPanel {

  struct CompletionView: View {
    @Bindable var viewState: ObservableViewState

    @FocusState private var isFocused: Bool

    @ViewBuilder
    var completionsList: some View {
      if viewState.completions.items.isEmpty {
        Text("No Completions").padding()
      } else {
        ScrollViewReader { proxy in
          List(viewState.completions.items, selection: $viewState.selection) { item in
            AnyView(item.rowView(viewState.selection == item.id))
              .lineLimit(1)
              .truncationMode(.middle)
              .listRowInsets(EdgeInsets(top: 2, leading: 8, bottom: 2, trailing: 8))
              .listRowSeparator(.hidden)
              .listRowBackground(Color.clear)
              .id(item.id)
          }
          .scrollContentBackground(.hidden)
          .listStyle(.plain)
          .onChange(of: viewState.selection) { oldValue, newValue in
            if let id = newValue {
              withAnimation(.easeInOut(duration: 0.15)) {
                proxy.scrollTo(id, anchor: .center)
              }
            }
          }
          .onAppear {
            // Scroll to initial selection
            if let id = viewState.selection {
              DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                proxy.scrollTo(id, anchor: .top)
              }
            }
          }
        }
      }
    }

    var body: some View {
      Group {
        if viewState.completions.items.isEmpty {

          Text("No Completions")
            .focusable(true)
            .focusEffectDisabled()
            .frame(width: 200, height: 50)
            .focused($isFocused)

        } else {

          completionsList
            .focused($isFocused)
            .frame(minHeight: 100, maxHeight: 300)
            .frame(minWidth: 350, maxWidth: 450)

        }
      }
      .background(.clear)
      .clipShape(ConcentricRectangle(corners: .concentric(minimum: 12)))
      .glassEffect(.regular.interactive(), in: ConcentricRectangle(corners: .concentric(minimum: 12)))
      .onAppear { isFocused = true }
    }
  }

  class HostedCompletionView: NSHostingView<CompletionView> {

    override func becomeFirstResponder() -> Bool {

      // This is very dodgy, but I just don't know another way to make the initial first responder a SwiftUI view
      // somewhere inside the guts of this hosting view.
      DispatchQueue.main.async { [self] in
        window!.selectKeyView(following: self)
      }
      return true
    }

    @MainActor
    override func keyDown(with event: NSEvent) {
      guard let window = window as? CompletionPanel else { super.keyDown(with: event); return }

      if event.keyCode == keyCodeDownArrow || event.keyCode == keyCodeUpArrow {

        // Pass arrow keys to the panel view
        super.keyDown(with: event)

      } else if event.keyCode == keyCodeReturn {

        // Commit to current completion
        if let selectedCompletion = (window.viewState.completions.items.first{ $0.id == window.viewState.selection }) {

          window.progressHandler?(.completion(selectedCompletion.insertText, selectedCompletion.insertRange))

        } else {

          window.progressHandler?(.cancel)

        }

      } else if event.keyCode == keyCodeESC {

        // cancel completion on ESC
        window.progressHandler?(.cancel)

      } else if !event.modifierFlags.intersection([.command, .control, .option]).isEmpty {

        // cancel completion and pass event on on any editing commands
        window.progressHandler?(.input(event))
        window.close()

      } else {

        // just pass on on anything we don't know about
        window.progressHandler?(.input(event))

      }
    }
  }

  /// This class encapsulates the state that may change while a completion panel is being displayed. It needs to be
  /// observable, such that SwiftUI views update properly on states changes.
  ///
  @Observable
  class ObservableViewState {
    var selection:   Int?        = nil
    var completions: Completions

    init(completions: Completions = .none) {
      self.selection   = nil
      self.completions = completions
    }
  }

  /// The current set of completions and the `id` of the currently selected item from the completions.
  ///
  private(set) var viewState: ObservableViewState = ObservableViewState()

  /// Whenever there is progress in the completion interaction, this is fed back to the code view by reporting
  /// progress via this handler.
  ///
  /// NB: Whenver a finalising completion progress is being reported, this property is reset to `nil`. This allows
  ///     sending a `.cancel` from `close()` without risk of a superflous progress message.
  ///
  var progressHandler: ((CompletionProgress) -> Void)?

  /// The content view at its precise type.
  ///
  private let hostingView: HostedCompletionView

  /// The observer for the 'didResignKeyNotification' notification.
  ///
  private var didResignObserver: NSObjectProtocol?
  
  /// The task resolving completion items (if active).
  ///
  private var resolveTask: Task<Void, any Error>?

  init() {
    hostingView = HostedCompletionView(rootView: CompletionView(viewState: viewState))
    hostingView.sizingOptions = [.maxSize, .minSize]

    super.init(contentRect: NSRect(x: 0, y: 0, width: 500, height: 300),
               styleMask: [.nonactivatingPanel, .fullSizeContentView], backing: .buffered, defer: true)
    collectionBehavior.insert(.fullScreenAuxiliary)
    isFloatingPanel             = true
    titleVisibility             = .hidden
    titlebarAppearsTransparent  = true
    isMovableByWindowBackground = false
    hidesOnDeactivate           = true
    animationBehavior           = .utilityWindow
    backgroundColor             = .clear

    standardWindowButton(.closeButton)?.isHidden       = true
    standardWindowButton(.miniaturizeButton)?.isHidden = true
    standardWindowButton(.zoomButton)?.isHidden        = true

    contentView = hostingView

    self.didResignObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification,
                                                                    object: self,
                                                                    queue: nil) { [weak self] _notification in

      self?.close()
    }
  }

  deinit {
    if let didResignObserver { NotificationCenter.default.removeObserver(didResignObserver) }
  }

  // Don't become key window - this keeps the cursor visible in the main text view
  // Keyboard events are forwarded from the text view via handleCompletionKeyEvent
  override var canBecomeKey: Bool { false }

  override func close() {
    // We cancel the completion process if the window gets closed (and the `progressHandler` is still active (i.e., it
    // is non-`nil`).
    progressHandler?(.cancel)
    super.close()
  }

  /// Handle keyboard events forwarded from the text view.
  /// Returns true if the event was handled, false if it should be passed through to the text view.
  ///
  func handleKeyEvent(_ event: NSEvent) -> Bool {
    guard isVisible else { return false }

    if event.keyCode == keyCodeDownArrow {
      // Move selection down
      if let currentIndex = viewState.completions.items.firstIndex(where: { $0.id == viewState.selection }),
         currentIndex + 1 < viewState.completions.items.count {
        viewState.selection = viewState.completions.items[currentIndex + 1].id
      }
      return true

    } else if event.keyCode == keyCodeUpArrow {
      // Move selection up
      if let currentIndex = viewState.completions.items.firstIndex(where: { $0.id == viewState.selection }),
         currentIndex > 0 {
        viewState.selection = viewState.completions.items[currentIndex - 1].id
      }
      return true

    } else if event.keyCode == keyCodeReturn || event.keyCode == keyCodeTab {
      // Commit to current completion
      if let selectedCompletion = viewState.completions.items.first(where: { $0.id == viewState.selection }) {
        progressHandler?(.completion(selectedCompletion.insertText, selectedCompletion.insertRange))
      } else {
        progressHandler?(.cancel)
      }
      return true

    } else if event.keyCode == keyCodeESC {
      // Cancel completion on ESC
      progressHandler?(.cancel)
      return true
    }

    return false
  }

  /// Set a list of completions and ensure that the completion panel is shown if the completion list is non-empty.
  ///
  /// - Parameters:
  ///   - completions: The new list of completions.
  ///   - screenRect: The rectangle enclosing the range of characters that form the prefix of the word that is being
  ///       completed. If no `rect` is provided, it is assumed that the last provided one is still valid. The
  ///       rectangle is in screen coordinates.
  ///   - explicitTrigger: The completion computation was explicitly triggered.
  ///   - handler: Closure used to report progress in the completion interaction back to the code view.
  ///
  /// The completion panel gets aligned such that `rect` leading aligns with the completion labels in the completion
  /// panel.
  ///
  func set(completions: Completions,
           anchoredAt screenRect: CGRect? = nil,
           explicitTrigger: Bool,
           handler: @escaping (CompletionProgress) -> Void)
  {
    // Cancel any still running reolve task before updating the completions that are being resolved; otherwise, we can
    // get oout-of-bounds indexing.
    resolveTask?.cancel()

    // Note: We don't sort here - the language service provides pre-sorted completions
    // with proper relevance ordering (prefix matches first, etc.)
    self.viewState       = ObservableViewState(completions: completions)
    self.progressHandler = handler

    if let screenRect {
      // FIXME: the panel needs to be above or below the rectangle depending on its position and size
      // FIXME: the panel needs to be aligned at the completion labels and not at its leading edge
      setFrameTopLeftPoint(CGPoint(x: screenRect.minX, y: screenRect.minY))
    }

    // The initial selection is the first item marked as selected, if any, or otherwise, the first item in the list.
    viewState.selection = if let selected = (completions.items.first{ $0.selected }) { selected.id }
                          else { completions.items.first?.id }

    // Update the view and show the window if and only if there are completion items to show.
    if completions.items.isEmpty && !explicitTrigger { close() }
    else {

      hostingView.rootView = CompletionView(viewState: self.viewState)
      if !isVisible {
        // Use orderFront instead of makeKeyAndOrderFront to keep cursor visible in text view
        orderFront(nil)
      }

      // Refine all refinable items.
      resolveTask = Task { @MainActor [weak self] in
        guard let self else { return }
        for item in self.viewState.completions.items.enumerated() {
          if let refinedItem = try? await item.element.refine() {

            try Task.checkCancellation()    // NB: Important if a new completion request has been made in the meantime.
            self.viewState.completions.items[item.offset] = refinedItem
          }
        }
      }
    }
  }
}


#Preview {
  @Previewable @State var viewState
    = CompletionPanel.ObservableViewState(completions:
                                            Completions(isIncomplete: false,
                                                        items: [
                                                          Completions.Completion(id: 1,
                                                                                 rowView: { _ in Text("foo") },
                                                                                 documentationView: Text("Best function!"),
                                                                                 selected: false,
                                                                                 sortText: "foo",
                                                                                 filterText: "foo",
                                                                                 insertText: "foo",
                                                                                 insertRange: NSRange(location: 0, length: 1),
                                                                                 commitCharacters: [],
                                                                                 refine: { nil }),
                                                          Completions.Completion(id: 2,
                                                                                 rowView: { _ in Text("fop") },
                                                                                 documentationView: Text("Second best function!"),
                                                                                 selected: false,
                                                                                 sortText: "fop",
                                                                                 filterText: "fop",
                                                                                 insertText: "fop",
                                                                                 insertRange: NSRange(location: 0, length: 1),
                                                                                 commitCharacters: [],
                                                                                 refine: { nil }),
                                                          Completions.Completion(id: 3,
                                                                                 rowView: { _ in Text("fabc") },
                                                                                 documentationView: Text("My best function!"),
                                                                                 selected: false,
                                                                                 sortText: "fabc",
                                                                                 filterText: "fabc",
                                                                                 insertText: "fabc",
                                                                                 insertRange: NSRange(location: 0, length: 1),
                                                                                 commitCharacters: [],
                                                                                 refine: { nil }),
                                                        ]))

  CompletionPanel.CompletionView(viewState: viewState)
}

extension CodeView {

  /// Sets a new list of completions and positions the completions panel such that it aligned with the given character
  /// range.
  ///
  /// - Parameters:
  ///   - completions: The new list of completions to be displayed.
  ///   - range: The characters range at whose leading edge the completion panel is to be aligned.
  ///   - explicitTrigger: The completion computation was explicitly triggered.
  ///
  @MainActor
  func show(completions: Completions, for range: NSRange, explicitTrigger: Bool) {

    completionPanel.set(completions: completions, 
                        anchoredAt: firstRect(forCharacterRange: range, actualRange: nil),
                        explicitTrigger: explicitTrigger) {
      [weak self] completionProgress in

      switch completionProgress {

      case .cancel:
        self?.completionPanel.progressHandler = nil
        self?.completionPanel.close()

      case .completion(let insertText, let insertRange):
        // FIXME: Using `range` when there is no `insertRange` is dangerous. It requires `rangeForUserCompletion` to match what the LSP service regards as the word prefix. Better would be to scan the code storage for the prefix of `insertText`.
        self?.insertText(insertText, replacementRange: insertRange ?? range)
        self?.completionPanel.progressHandler = nil
        self?.completionPanel.close()

      case .input(let event):
        self?.interpretKeyEvents([event])
      }
    }
  }

  /// Actually do query the language service for code completions and display them.
  ///
  /// - Parameters:
  ///   - location: The character location for which code completions are requested.
  ///   - explicitTrigger: The completion computation was explicitly triggered.
  ///
  func computeAndShowCompletions(at location: Int, explicitTrigger: Bool) async throws {
    guard let languageService = optLanguageService else { return }

    do {

      let reason: CompletionTriggerReason = if completionPanel.isVisible { .incomplete } else { .standard },
          completions                     = try await languageService.completions(at: location, reason: reason)
      try Task.checkCancellation()   // may have been cancelled in the meantime due to further user action
      show(completions: completions, for: rangeForUserCompletion, explicitTrigger: explicitTrigger)

    } catch let error { logger.trace("Completion action failed: \(error.localizedDescription)") }
  }
  
  /// Explicitly user initiated completion action by a command or trigger character.
  ///
  func completionAction() {

    // Stop any already running completion task
    completionTask?.cancel()

    // If we already show the completion panel close it — we want the shortcut to toggle visbility. Otherwise,
    // initiate a completion task.
    if completionPanel.isVisible {

      completionPanel.close()

    } else {

      let location = selectedRange().location
      if let codeStorageDelegate = optCodeStorage?.delegate as? CodeStorageDelegate,
         !codeStorageDelegate.lineMap.isWithinComment(range: NSRange(location: location, length: 0))
      {
        completionTask = Task {
          try await computeAndShowCompletions(at: location, explicitTrigger: true)
        }
      }

    }
  }
  
  /// FIXME: This is language dependent and should take the language configuration into account. (In Haskell, it
  /// FIXME: should, .e.g., include "'" as well.)
  private static let identifierCharacterSet = CharacterSet.alphanumerics.union(.init(charactersIn: "_"))

  /// This function needs to be invoked whenever the completion range changes; i.e., once a text change has been made.
  ///
  /// - Parameter range: The current completion range (range of partial word in front of the insertion point) as
  ///       reported by the text view.
  ///
  func considerCompletionFor(range: NSRange) {

    /// We don't want to automatically trigger completion for ranges that do not produce sensible results, such as
    /// ranges of purely numeric characters. Moreover, we do not automatically trigger completions for ranges that end
    /// in the middle of an identifier.
    ///
    func rangeContentsWarrantsAutoCompletion() -> Bool {
      guard let codeStorage = optCodeStorage,
            let substring   = codeStorage.string[range]
      else { return false }

      // FIXME: For languages with user-definable symbol identifiers, it would make sense to trigger auto-completion
      // FIXME: for ranges that consist of symbols only, but, e.g., the Haskell Language Server doesn't seem to return
      // FIXME: sensible results. This ought to be improved.

      // For now, we look for at least one letter.
      let atLeastOneLetter = substring.unicodeScalars.first{ CharacterSet.letters.contains($0) } != nil

      let notInMiddleOfIndentifier = if let next = codeStorage.string[NSRange(location: range.max, length: 1)],
                                        let nextCharacter = next.unicodeScalars.first
                                     {
                                       !CodeView.identifierCharacterSet.contains(nextCharacter)
                                     } else { true }

      return atLeastOneLetter && notInMiddleOfIndentifier
    }

    guard let codeStorageDelegate = optCodeStorage?.delegate as? CodeStorageDelegate else { return }

    // Stop any already running completion task
    completionTask?.cancel()

    let withinComment = codeStorageDelegate.lineMap.isWithinComment(range: NSRange(location: range.max, length: 0))

    // Close panel if range becomes empty
    if range.length == 0 && completionPanel.isVisible {
      completionPanel.close()
      return
    }

    // Trigger completion for valid ranges
    let shouldTriggerCompletion = range.length > 0 && !withinComment && rangeContentsWarrantsAutoCompletion()
    let isTypingOrDeleting = codeStorageDelegate.processingOneCharacterAddition || completionPanel.isVisible

    if shouldTriggerCompletion && isTypingOrDeleting {

      completionTask = Task {

        // Delay completion a bit at the start of a word (the user may still be typing) unless the completion window
        // is already open.
        // NB: throws if task gets cancelled in the meantime.
        if range.length < 3 && !completionPanel.isVisible { try await Task.sleep(until: .now + .seconds(0.2)) }

        // Trigger completion
        try await computeAndShowCompletions(at: range.max, explicitTrigger: false)
      }

    } else if completionPanel.isVisible {

      // Close panel if we're in an invalid completion context (e.g., inside comment, no valid prefix)
      completionPanel.close()

    }
  }

}

#endif
