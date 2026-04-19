import Foundation
import XCTest
@testable import CodeEditorView

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

  func testShiftRightUsesConfiguredIndentationWidth() {
    let indentation = CodeEditor.IndentationConfiguration(preference: .preferSpaces,
                                                         tabWidth: 4,
                                                         indentWidth: 4,
                                                         tabKey: .identsInWhitespace,
                                                         indentOnReturn: true)
    XCTAssertEqual(indentation.defaultIndentation.utf16.count, 4)
  }
}

private final class UndoTarget {
  var didUndo = false
}
