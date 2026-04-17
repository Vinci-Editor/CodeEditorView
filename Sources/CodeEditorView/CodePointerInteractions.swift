//
//  CodePointerInteractions.swift
//  CodeEditorView
//
//  Pointer and command-hover behavior for editor semantic affordances.
//

#if os(macOS)
import AppKit
import ObjectiveC
import os
import SwiftUI

private let pointerLogger = Logger(subsystem: "org.justtesting.CodeEditorView", category: "PointerInteractions")
nonisolated(unsafe) private var commandHoverRangeKey: UInt8 = 0
nonisolated(unsafe) private var commandHoverTrackingAreaKey: UInt8 = 0

extension CodeView {

  private var commandHoverRange: NSRange? {
    get { (objc_getAssociatedObject(self, &commandHoverRangeKey) as? NSValue)?.rangeValue }
    set {
      let value = newValue.map { NSValue(range: $0) }
      objc_setAssociatedObject(self, &commandHoverRangeKey, value, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }
  }

  private var commandHoverTrackingArea: NSTrackingArea? {
    get { objc_getAssociatedObject(self, &commandHoverTrackingAreaKey) as? NSTrackingArea }
    set { objc_setAssociatedObject(self, &commandHoverTrackingAreaKey, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
  }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let commandHoverTrackingArea {
      removeTrackingArea(commandHoverTrackingArea)
    }
    let trackingArea = NSTrackingArea(rect: .zero,
                                      options: [.activeInKeyWindow, .inVisibleRect, .mouseMoved, .mouseEnteredAndExited],
                                      owner: self,
                                      userInfo: nil)
    addTrackingArea(trackingArea)
    commandHoverTrackingArea = trackingArea
  }

  override func flagsChanged(with event: NSEvent) {
    super.flagsChanged(with: event)
    updateCommandHover(with: event)
  }

  override func mouseMoved(with event: NSEvent) {
    super.mouseMoved(with: event)
    updateCommandHover(with: event)
  }

  override func mouseExited(with event: NSEvent) {
    super.mouseExited(with: event)
    clearCommandHover()
  }

  override func mouseDown(with event: NSEvent) {
    if event.modifierFlags.contains(.command),
       let range = commandHoverRange
    {
      showSemanticInfo(at: range.location, fallbackRange: range)
      return
    }
    super.mouseDown(with: event)
  }

  private func updateCommandHover(with event: NSEvent) {
    guard bracketMatching.commandHoverMatching,
          event.modifierFlags.contains(.command),
          let codeStorage = optCodeStorage
    else {
      clearCommandHover()
      return
    }

    let point = convert(event.locationInWindow, from: nil)
    let location = characterIndexForInsertion(at: point)
    let tokenHit = codeStorage.token(at: location)
    guard let token = tokenHit.token,
          token.token.isIdentifier || token.token.isOperator
    else {
      clearCommandHover()
      return
    }

    commandHoverRange = tokenHit.effectiveRange
    NSCursor.pointingHand.set()
  }

  private func clearCommandHover() {
    commandHoverRange = nil
    NSCursor.iBeam.set()
  }

  private func showSemanticInfo(at location: Int, fallbackRange: NSRange) {
    guard let languageService = optLanguageService else { return }
    let width = min((window?.frame.width ?? 250) * 0.75, 500)

    Task {
      do {
        if let info = try await languageService.info(at: location) {
          show(infoPopover: InfoPopover(displaying: info.view, width: width), for: info.anchor ?? fallbackRange)
        }
      } catch let error {
        pointerLogger.trace("Info action failed: \(error.localizedDescription)")
      }
    }
  }
}
#endif
