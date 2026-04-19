//
//  CodePointerInteractionsUIKit.swift
//  CodeEditorView
//

#if os(iOS) || os(visionOS)
import UIKit

extension CodeView {

  override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
    clearPendingOpeningCurlyBraceReturnCompletion()
    super.touchesBegan(touches, with: event)
  }

  @objc func handleEditorHover(_ recognizer: UIHoverGestureRecognizer) {
    guard recognizer.state == .ended || recognizer.state == .cancelled else { return }
    if isCompletionVisible {
      becomeFirstResponder()
    }
  }
}
#endif

#if os(iOS)
extension CodeView: UIPointerInteractionDelegate {

  func pointerInteraction(_ interaction: UIPointerInteraction,
                          regionFor request: UIPointerRegionRequest,
                          defaultRegion: UIPointerRegion) -> UIPointerRegion?
  {
    guard window != nil else { return nil }
    return defaultRegion
  }

  func pointerInteraction(_ interaction: UIPointerInteraction,
                          styleFor region: UIPointerRegion) -> UIPointerStyle?
  {
    nil
  }
}
#endif
