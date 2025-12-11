//
//  TreeSitterTokenizer.swift
//
//  Tree-sitter based tokenizer for incremental syntax highlighting.
//

import Foundation
import SwiftTreeSitter

/// A tokenizer that uses tree-sitter for incremental parsing.
///
/// Tree-sitter provides:
/// - Incremental parsing: Only re-parses changed portions of the document
/// - Syntax tree: Enables accurate scope detection
/// - Industry standard grammars: Many languages supported
///
public final class TreeSitterTokenizer {

  /// The tree-sitter parser.
  ///
  private let parser: Parser

  /// The current syntax tree (updated incrementally).
  ///
  private var tree: MutableTree?

  /// The tree-sitter language.
  ///
  private let language: Language

  /// Highlight query for extracting tokens.
  ///
  private let highlightQuery: Query?

  /// Mapping from tree-sitter capture names to Token types.
  ///
  private let captureMapping: [String: LanguageConfiguration.Token]

  /// Cache of the last parsed text for incremental parsing.
  ///
  private var lastText: String = ""

  // MARK: - Initialization

  /// Creates a tree-sitter tokenizer for a specific language.
  ///
  /// - Parameters:
  ///   - language: The tree-sitter Language object.
  ///   - highlightQuerySource: The highlight query source (SCM format).
  ///   - captureMapping: Mapping from capture names to Token types.
  ///
  public init(language: Language,
              highlightQuerySource: String,
              captureMapping: [String: LanguageConfiguration.Token]) throws {
    self.parser = Parser()
    try parser.setLanguage(language)
    self.language = language
    self.captureMapping = captureMapping

    // Try to compile the highlight query
    if let queryData = highlightQuerySource.data(using: .utf8) {
      self.highlightQuery = try? Query(language: language, data: queryData)
    } else {
      self.highlightQuery = nil
    }
  }

  // MARK: - Parsing

  /// Parse the entire document.
  ///
  /// - Parameter text: The source code to parse.
  /// - Returns: Array of tokens extracted from the parse tree.
  ///
  public func parse(_ text: String) -> [LanguageConfiguration.Tokeniser.Token] {
    tree = parser.parse(text)
    lastText = text
    return extractTokens(from: tree, in: text)
  }

  /// Parse incrementally after an edit.
  ///
  /// - Parameters:
  ///   - oldText: The text before the edit.
  ///   - newText: The text after the edit.
  ///   - editedRange: The range that was edited (in the old text).
  ///   - delta: The change in length (positive for insertion, negative for deletion).
  /// - Returns: Array of tokens extracted from the updated parse tree.
  ///
  public func parseIncremental(oldText: String,
                               newText: String,
                               editedRange: NSRange,
                               delta: Int) -> [LanguageConfiguration.Tokeniser.Token] {
    guard let oldTree = tree else {
      // No previous tree, do a full parse
      return parse(newText)
    }

    // Create the input edit for tree-sitter
    let edit = createInputEdit(oldText: oldText, newText: newText, editedRange: editedRange, delta: delta)

    // Apply the edit to the old tree
    oldTree.edit(edit)

    // Parse with the edited old tree
    let newTree = parser.parse(tree: oldTree, string: newText)
    tree = newTree
    lastText = newText

    return extractTokens(from: newTree, in: newText)
  }

  // MARK: - Token Extraction

  /// Extract tokens from the parse tree using the highlight query.
  ///
  private func extractTokens(from tree: MutableTree?, in text: String) -> [LanguageConfiguration.Tokeniser.Token] {
    guard let tree = tree,
          tree.rootNode != nil,
          let query = highlightQuery
    else { return [] }

    var tokens: [LanguageConfiguration.Tokeniser.Token] = []
    let cursor = query.execute(in: tree)

    while let match = cursor.next() {
      for capture in match.captures {
        guard let captureName = query.captureName(for: capture.index),
              let tokenType = captureMapping[captureName]
        else { continue }

        // Get the range from the captured node
        let nodeRange = capture.node.range
        let charRange = NSRange(location: nodeRange.location, length: nodeRange.length)

        tokens.append(LanguageConfiguration.Tokeniser.Token(token: tokenType, range: charRange))
      }
    }

    // Sort by location and remove duplicates (some captures may overlap)
    return tokens.sorted { $0.range.location < $1.range.location }
  }

  // MARK: - Helpers

  /// Create a tree-sitter InputEdit from edit information.
  ///
  private func createInputEdit(oldText: String,
                               newText: String,
                               editedRange: NSRange,
                               delta: Int) -> InputEdit {
    // Convert character positions to byte positions
    let startIndex = oldText.index(oldText.startIndex, offsetBy: min(editedRange.location, oldText.count))
    let startByte = UInt32(oldText.utf8.distance(from: oldText.startIndex, to: startIndex))

    let oldEndLocation = min(editedRange.location + editedRange.length, oldText.count)
    let oldEndIndex = oldText.index(oldText.startIndex, offsetBy: oldEndLocation)
    let oldEndByte = UInt32(oldText.utf8.distance(from: oldText.startIndex, to: oldEndIndex))

    let newEndLocation = min(editedRange.location + editedRange.length + delta, newText.count)
    let newEndIndex = newText.index(newText.startIndex, offsetBy: newEndLocation)
    let newEndByte = UInt32(newText.utf8.distance(from: newText.startIndex, to: newEndIndex))

    // Calculate points
    let startPoint = pointFor(offset: editedRange.location, in: oldText)
    let oldEndPoint = pointFor(offset: oldEndLocation, in: oldText)
    let newEndPoint = pointFor(offset: newEndLocation, in: newText)

    return InputEdit(
      startByte: startByte,
      oldEndByte: oldEndByte,
      newEndByte: newEndByte,
      startPoint: startPoint,
      oldEndPoint: oldEndPoint,
      newEndPoint: newEndPoint
    )
  }

  /// Calculate a Point (row, column) for a character offset.
  ///
  private func pointFor(offset: Int, in text: String) -> Point {
    var row: UInt32 = 0
    var column: UInt32 = 0
    var currentOffset = 0

    for char in text {
      if currentOffset >= offset { break }
      if char == "\n" {
        row += 1
        column = 0
      } else {
        column += UInt32(char.utf8.count)
      }
      currentOffset += 1
    }

    return Point(row: row, column: column)
  }
}

// MARK: - Standard Capture Mappings

/// Standard tree-sitter capture name to Token mappings.
///
public struct TreeSitterCaptureMappings {

  /// Swift language capture mapping.
  ///
    nonisolated(unsafe) public static let swift: [String: LanguageConfiguration.Token] = [
    // Keywords
    "keyword": .keyword,
    "keyword.function": .keyword,
    "keyword.return": .keyword,
    "keyword.control": .keyword,
    "keyword.storage": .keyword,
    "keyword.import": .keyword,
    "keyword.operator": .keyword,

    // Literals
    "string": .string,
    "string.special": .string,
    "character": .character,
    "number": .number,
    "number.float": .number,
    "boolean": .keyword,

    // Comments
    "comment": .singleLineComment,
    "comment.line": .singleLineComment,
    "comment.block": .nestedCommentOpen,

    // Identifiers
    "type": .identifier(.type(.other)),
    "type.builtin": .identifier(.type(.other)),
    "function": .identifier(.function),
    "function.method": .identifier(.method),
    "variable": .identifier(.variable),
    "variable.parameter": .identifier(.parameter),
    "property": .identifier(.property),
    "constant": .identifier(nil),

    // Operators and punctuation
    "operator": .operator(nil),
    "punctuation.delimiter": .symbol,
    "punctuation.bracket": .roundBracketOpen,  // Generic, specific brackets below

    // Brackets
    "punctuation.bracket.round.open": .roundBracketOpen,
    "punctuation.bracket.round.close": .roundBracketClose,
    "punctuation.bracket.square.open": .squareBracketOpen,
    "punctuation.bracket.square.close": .squareBracketClose,
    "punctuation.bracket.curly.open": .curlyBracketOpen,
    "punctuation.bracket.curly.close": .curlyBracketClose,
  ]

  /// Python language capture mapping.
  ///
    nonisolated(unsafe) public static let python: [String: LanguageConfiguration.Token] = [
    "keyword": .keyword,
    "string": .string,
    "number": .number,
    "comment": .singleLineComment,
    "function": .identifier(.function),
    "variable": .identifier(.variable),
    "type": .identifier(.type(.other)),
    "operator": .operator(nil),
    "punctuation.delimiter": .symbol,
    "punctuation.bracket": .roundBracketOpen,
  ]

  /// Haskell language capture mapping.
  ///
    nonisolated(unsafe) public static let haskell: [String: LanguageConfiguration.Token] = [
    "keyword": .keyword,
    "string": .string,
    "number": .number,
    "comment": .singleLineComment,
    "comment.block": .nestedCommentOpen,
    "function": .identifier(.function),
    "type": .identifier(.type(.other)),
    "constructor": .identifier(.enumCase),
    "operator": .operator(nil),
    "punctuation.delimiter": .symbol,
    "punctuation.bracket": .roundBracketOpen,
  ]
}
