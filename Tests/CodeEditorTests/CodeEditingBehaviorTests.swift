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

  func testShiftRightUsesConfiguredIndentationWidth() {
    let indentation = CodeEditor.IndentationConfiguration(preference: .preferSpaces,
                                                         tabWidth: 4,
                                                         indentWidth: 4,
                                                         tabKey: .identsInWhitespace,
                                                         indentOnReturn: true)
    XCTAssertEqual(indentation.defaultIndentation.utf16.count, 4)
  }
}
