//
//  TreeSitterTokenizerTests.swift
//

import XCTest
@testable import LanguageSupport

final class TreeSitterTokenizerTests: XCTestCase {

  func testInterpolatedStringHighlightsEmbeddedExpression() throws {
    let code = #"Text("Hello \(counter)")"#
    let tokens = try freshSwiftTokens(in: code)
    let counterRange = range(of: "counter", in: code)
    let interpolationStartRange = range(of: "\\(", in: code)
    let interpolationEndRange = range(of: ")", in: code, after: counterRange)

    XCTAssertEqual(token(in: tokens, at: interpolationStartRange), .symbol)
    XCTAssertEqual(token(in: tokens, at: interpolationEndRange), .symbol)
    XCTAssertEqual(token(in: tokens, at: counterRange), .identifier(.variable))
    XCTAssertFalse(tokens.contains {
      $0.token == .string && ($0.range.intersection(counterRange)?.length ?? 0) > 0
    })
  }

  func testRawStringInterpolationHighlightsEmbeddedExpression() throws {
    let code = ##"Text(#"Hello \#(counter)"#)"##
    let tokens = try freshSwiftTokens(in: code)
    let counterRange = range(of: "counter", in: code)
    let interpolationStartRange = range(of: "\\#(", in: code)
    let interpolationEndRange = range(of: ")", in: code, after: counterRange)

    XCTAssertEqual(token(in: tokens, at: interpolationStartRange), .symbol)
    XCTAssertEqual(token(in: tokens, at: interpolationEndRange), .symbol)
    XCTAssertEqual(token(in: tokens, at: counterRange), .identifier(.variable))
    XCTAssertFalse(tokens.contains {
      $0.token == .string && ($0.range.intersection(counterRange)?.length ?? 0) > 0
    })
  }

  func testMultilineStringInterpolationHighlightsEmbeddedExpression() throws {
    let code = #"""
Text("""
Hello \(counter)
""")
"""#
    let tokens = try freshSwiftTokens(in: code)
    let counterRange = range(of: "counter", in: code)
    let interpolationStartRange = range(of: "\\(", in: code)
    let interpolationEndRange = range(of: ")", in: code, after: counterRange)

    XCTAssertEqual(token(in: tokens, at: interpolationStartRange), .symbol)
    XCTAssertEqual(token(in: tokens, at: interpolationEndRange), .symbol)
    XCTAssertEqual(token(in: tokens, at: counterRange), .identifier(.variable))
    XCTAssertFalse(tokens.contains {
      $0.token == .string && ($0.range.intersection(counterRange)?.length ?? 0) > 0
    })
  }

  func testEscapedCharactersStayStringColored() throws {
    let code = #"Text("Line\n\"quote\"")"#
    let tokens = try freshSwiftTokens(in: code)

    XCTAssertEqual(token(in: tokens, at: range(of: "\\n", in: code)), .string)
    XCTAssertEqual(token(in: tokens, at: range(of: "\\\"", in: code)), .string)
  }

  func testCapitalizedCallsHighlightAsTypesAndLowercaseCallsAsFunctions() throws {
    let code = #"ScrollView { Text("Hi"); Button("Tap") {}; print("x") }"#
    let tokens = try freshSwiftTokens(in: code)

    XCTAssertEqual(token(in: tokens, at: range(of: "ScrollView", in: code)), .identifier(.type(.other)))
    XCTAssertEqual(token(in: tokens, at: range(of: "Text", in: code)), .identifier(.type(.other)))
    XCTAssertEqual(token(in: tokens, at: range(of: "Button", in: code)), .identifier(.type(.other)))
    XCTAssertEqual(token(in: tokens, at: range(of: "print", in: code)), .identifier(.function))
  }

  func testExactRangeCapturePrecedenceIsDeterministic() throws {
    let code = #"Text("Hi")"#
    let tokens = try freshSwiftTokens(in: code)
    let textRange = range(of: "Text", in: code)
    let exactTokens = tokens.filter { $0.range == textRange }

    XCTAssertEqual(exactTokens, [
      LanguageConfiguration.Tokeniser.Token(token: .identifier(.type(.other)), range: textRange)
    ])
  }

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

  private func range(of needle: String, in text: String) -> NSRange {
    let range = (text as NSString).range(of: needle)
    XCTAssertNotEqual(range.location, NSNotFound, "Missing '\(needle)' in '\(text)'")
    return range
  }

  private func range(of needle: String, in text: String, after precedingRange: NSRange) -> NSRange {
    let searchRange = NSRange(location: precedingRange.max, length: (text as NSString).length - precedingRange.max)
    let range = (text as NSString).range(of: needle, range: searchRange)
    XCTAssertNotEqual(range.location, NSNotFound, "Missing '\(needle)' after \(precedingRange) in '\(text)'")
    return range
  }

  private func token(in tokens: [LanguageConfiguration.Tokeniser.Token],
                     at range: NSRange) -> LanguageConfiguration.Token? {
    tokens.first { $0.range == range }?.token
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
