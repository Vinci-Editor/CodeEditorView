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

  func testShiftRightUsesConfiguredIndentationWidth() {
    let indentation = CodeEditor.IndentationConfiguration(preference: .preferSpaces,
                                                         tabWidth: 4,
                                                         indentWidth: 4,
                                                         tabKey: .identsInWhitespace,
                                                         indentOnReturn: true)
    XCTAssertEqual(indentation.defaultIndentation.utf16.count, 4)
  }
}
