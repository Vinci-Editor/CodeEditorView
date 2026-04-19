//
//  TreeSitterTokenizerTests.swift
//

import XCTest
@testable import LanguageSupport

final class TreeSitterTokenizerTests: XCTestCase {

  func testIncrementalInsertDeleteAndRedoMatchFullParse() throws {
    let original =
"""
import SwiftUI

struct ContentView: View {
  var body: some View {
    Text("Hi")
  }
}
"""

    let insertion = "    Button(\"Tap\") { }\n"
    let insertionLocation = (original as NSString).range(of: "    Text").location
    let edited = (original as NSString).replacingCharacters(
      in: NSRange(location: insertionLocation, length: 0),
      with: insertion
    )
    let insertionLength = insertion.utf16.count

    let tokenizer = try makeSwiftTokenizer()
    tokenizer.ensureParsed(original)

    tokenizer.applyEdit(
      newText: edited,
      editedRange: NSRange(location: insertionLocation, length: 0),
      delta: insertionLength
    )
    XCTAssertEqual(tokenizer.tokens(), try freshSwiftTokens(in: edited))

    tokenizer.applyEdit(
      newText: original,
      editedRange: NSRange(location: insertionLocation, length: insertionLength),
      delta: -insertionLength
    )
    XCTAssertEqual(tokenizer.tokens(), try freshSwiftTokens(in: original))

    tokenizer.applyEdit(
      newText: edited,
      editedRange: NSRange(location: insertionLocation, length: 0),
      delta: insertionLength
    )
    XCTAssertEqual(tokenizer.tokens(), try freshSwiftTokens(in: edited))
  }

  private func freshSwiftTokens(in text: String) throws -> [LanguageConfiguration.Tokeniser.Token] {
    let tokenizer = try makeSwiftTokenizer()
    tokenizer.ensureParsed(text)
    return tokenizer.tokens()
  }

  private func makeSwiftTokenizer() throws -> TreeSitterTokenizer {
    let configuration = LanguageConfiguration.swift()
    let language = try XCTUnwrap(configuration.treeSitterLanguage?())
    let query = try XCTUnwrap(configuration.treeSitterHighlightQuery)
    let captureMapping = try XCTUnwrap(configuration.treeSitterCaptureMapping)
    return try TreeSitterTokenizer(language: language,
                                   highlightQuerySource: query,
                                   captureMapping: captureMapping)
  }
}
