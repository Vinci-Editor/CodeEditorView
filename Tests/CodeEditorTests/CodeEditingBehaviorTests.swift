import Foundation
import XCTest
@testable import CodeEditorView
@testable import LanguageSupport

#if os(macOS)
import AppKit
#endif

final class CodeEditingBehaviorTests: XCTestCase {

  func testDefaultPairsIncludeXcodeDelimiters() {
    XCTAssertEqual(CodeEditingContext.pair(opening: "(")?.closing, ")")
    XCTAssertEqual(CodeEditingContext.pair(opening: "[")?.closing, "]")
    XCTAssertEqual(CodeEditingContext.pair(opening: "{")?.closing, "}")
    XCTAssertEqual(CodeEditingContext.pair(opening: "\"")?.closing, "\"")
    XCTAssertEqual(CodeEditingContext.pair(opening: "'")?.closing, "'")
  }

  func testClosingPairLookupSupportsSkipOver() {
    XCTAssertEqual(CodeEditingContext.pair(closing: ")")?.opening, "(")
    XCTAssertEqual(CodeEditingContext.pair(closing: "]")?.opening, "[")
    XCTAssertEqual(CodeEditingContext.pair(closing: "}")?.opening, "{")
  }

  func testImmediatePairInsertionDefersCurlyBraceUntilReturn() {
    XCTAssertEqual(CodeEditingContext.pairForImmediateInsertion(opening: "(")?.closing, ")")
    XCTAssertEqual(CodeEditingContext.pairForImmediateInsertion(opening: "[")?.closing, "]")
    XCTAssertNil(CodeEditingContext.pairForImmediateInsertion(opening: "{"))
  }

  func testReturnInsideCurlyBraceInsertsMissingClosingBrace() {
    let indentation = CodeEditor.IndentationConfiguration(preference: .preferSpaces,
                                                         tabWidth: 4,
                                                         indentWidth: 2,
                                                         tabKey: .identsInWhitespace,
                                                         indentOnReturn: true)

    let edit = CodeEditingContext.returnInsideCurlyBrace(baseIndent: 2,
                                                         indentation: indentation,
                                                         hasClosingBraceAfter: false)

    XCTAssertEqual(edit.replacementText, "\n    \n  }")
    XCTAssertEqual(edit.selectionOffset, 5)
  }

  func testReturnInsideCurlyBracePreservesExistingClosingBrace() {
    let indentation = CodeEditor.IndentationConfiguration(preference: .preferSpaces,
                                                         tabWidth: 4,
                                                         indentWidth: 2,
                                                         tabKey: .identsInWhitespace,
                                                         indentOnReturn: true)

    let edit = CodeEditingContext.returnInsideCurlyBrace(baseIndent: 2,
                                                         indentation: indentation,
                                                         hasClosingBraceAfter: true)

    XCTAssertEqual(edit.replacementText, "\n    \n  ")
    XCTAssertEqual(edit.selectionOffset, 5)
  }

  func testReturnCompletionRequiresJustTypedOpeningBraceLocation() {
    XCTAssertTrue(CodeEditingContext.shouldCompleteCurlyBraceOnReturn(
      at: 4,
      pendingOpeningCurlyBraceLocations: [4],
      isAfterOpeningCurlyBrace: true,
      completeOnEnter: true
    ))

    XCTAssertFalse(CodeEditingContext.shouldCompleteCurlyBraceOnReturn(
      at: 4,
      pendingOpeningCurlyBraceLocations: [],
      isAfterOpeningCurlyBrace: true,
      completeOnEnter: true
    ))

    XCTAssertFalse(CodeEditingContext.shouldCompleteCurlyBraceOnReturn(
      at: 4,
      pendingOpeningCurlyBraceLocations: [5],
      isAfterOpeningCurlyBrace: true,
      completeOnEnter: true
    ))
  }

  func testReturnCompletionHonorsAutoBraceConfiguration() {
    XCTAssertFalse(CodeEditingContext.shouldCompleteCurlyBraceOnReturn(
      at: 4,
      pendingOpeningCurlyBraceLocations: [4],
      isAfterOpeningCurlyBrace: true,
      completeOnEnter: false
    ))
  }

  func testWithoutUndoRegistrationSkipsUndoEntries() {
    let undoManager = UndoManager()
    let target = UndoTarget()

    CodeEditor.withoutUndoRegistration(using: undoManager) {
      undoManager.registerUndo(withTarget: target) { target in
        target.didUndo = true
      }
    }

    XCTAssertFalse(undoManager.canUndo)

    undoManager.registerUndo(withTarget: target) { target in
      target.didUndo = true
    }

    XCTAssertTrue(undoManager.canUndo)
  }

#if os(macOS)
  func testMessageViewInitialCharacterIndexUsesDiagnosticLine() {
    let codeView = makeCodeView()
    codeView.string = "one\ntwo\nthree"

    let message = TextLocated(
      location: TextLocation(oneBasedLine: 3, column: 1),
      entity: Message(category: .error, length: 5, summary: "broken", description: nil)
    )

    codeView.update(messages: [message])

    let messageInfo = try XCTUnwrap(codeView.messageViews.values.first)
    XCTAssertEqual(messageInfo.characterIndex, ("one\ntwo\n" as NSString).length)
    XCTAssertEqual(messageInfo.lineFragementRect, .zero)
  }

  func testMacCodeViewRoutesUndoRedoThroughDocumentUndoManager() {
    let undoManager = UndoManager()
    let target = UndoTarget()
    let codeView = makeCodeView(undoManager: undoManager)

    undoManager.registerUndo(withTarget: target) { target in
      target.didUndo = true
      undoManager.registerUndo(withTarget: target) { target in
        target.didRedo = true
      }
    }

    XCTAssertTrue(codeView.validateUserInterfaceItem(ValidatedItem(action: #selector(CodeView.undo(_:)))))
    codeView.undo(nil)
    XCTAssertTrue(target.didUndo)

    XCTAssertTrue(codeView.validateUserInterfaceItem(ValidatedItem(action: #selector(CodeView.redo(_:)))))
    codeView.redo(nil)
    XCTAssertTrue(target.didRedo)

    codeView.shutdown()
  }
#endif

  func testShiftRightUsesConfiguredIndentationWidth() {
    let indentation = CodeEditor.IndentationConfiguration(preference: .preferSpaces,
                                                         tabWidth: 4,
                                                         indentWidth: 4,
                                                         tabKey: .identsInWhitespace,
                                                         indentOnReturn: true)
    XCTAssertEqual(indentation.defaultIndentation.utf16.count, 4)
  }
}

#if os(macOS)
private func makeCodeView(undoManager: UndoManager? = nil) -> CodeView {
  CodeView(
    frame: CGRect(x: 0, y: 0, width: 320, height: 240),
    with: .none,
    viewLayout: .standard,
    documentID: "test.swift",
    undoManager: undoManager,
    indentation: .standard,
    theme: .defaultLight,
    setText: { _ in },
    setMessages: { _ in }
  )
}

private struct ValidatedItem: NSValidatedUserInterfaceItem {
  let action: Selector?
  var tag: Int = 0
}
#endif

private final class UndoTarget {
  var didUndo = false
  var didRedo = false
}
