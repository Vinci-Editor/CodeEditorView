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

  /// Whether we have an initialized parse tree.
  ///
  private var isParsed: Bool { tree != nil }

  /// Captured token plus the originating capture name for deterministic conflict resolution.
  ///
  private struct CapturedToken {
    var token: LanguageConfiguration.Tokeniser.Token
    var captureName: String
    var priority: Int
  }

  private struct RangeKey: Hashable {
    var location: Int
    var length: Int

    init(_ range: NSRange) {
      self.location = range.location
      self.length = range.length
    }
  }

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

    if let queryData = highlightQuerySource.data(using: .utf8) {
      self.highlightQuery = try Query(language: language, data: queryData)
    } else {
      self.highlightQuery = nil
    }
  }

  // MARK: - Parsing

  /// Ensure the tree is parsed and matches the given text.
  ///
  /// This does a full parse if we don't have a tree yet or if the text changed without edit metadata.
  ///
  public func ensureParsed(_ text: String) {
    guard !isParsed || lastText != text else { return }
    tree = parser.parse(text)
    lastText = text
  }

  /// Apply an edit and incrementally update the parse tree.
  ///
  /// Tree-sitter bytes are in UTF-16LE for SwiftTreeSitter (2 bytes per UTF-16 code unit).
  ///
  public func applyEdit(newText: String, editedRange: NSRange, delta: Int) {
    guard let existingTree = tree else {
      ensureParsed(newText)
      return
    }

    let edit = createInputEdit(oldText: lastText, newText: newText, editedRange: editedRange, delta: delta)
    existingTree.edit(edit)
    tree = parser.parse(tree: existingTree, string: newText)
    lastText = newText
  }

  // MARK: - Token Extraction

  /// Extract tokens using the highlight query.
  ///
  /// - Parameter range: Optional range to limit captures (viewport highlighting).
  /// - Returns: Tokens sorted by start location.
  ///
  public func tokens(in range: NSRange? = nil) -> [LanguageConfiguration.Tokeniser.Token] {
    guard let tree,
          tree.rootNode != nil,
          let query = highlightQuery
    else { return [] }

    let cursor = query.execute(in: tree)
    if let range {
      cursor.setRange(range)
    }

    let context = Predicate.Context(string: lastText)

    var tokens: [CapturedToken] = []
    var tokenIndicesByRange: [RangeKey: Int] = [:]
    for match in cursor.resolve(with: context) {
      for capture in match.captures {
        guard let captureName = capture.name,
              let tokenType = captureMapping[captureName]
        else { continue }

        let captureRange = capture.node.range
        if let range, (captureRange.intersection(range)?.length ?? 0) <= 0 { continue }
        let capturedToken = CapturedToken(
          token: LanguageConfiguration.Tokeniser.Token(token: tokenType, range: captureRange),
          captureName: captureName,
          priority: Self.capturePriority(for: captureName, token: tokenType)
        )
        let rangeKey = RangeKey(captureRange)
        if let existingIndex = tokenIndicesByRange[rangeKey] {
          let existingToken = tokens[existingIndex]
          if Self.shouldReplace(existingToken, with: capturedToken) {
            tokens[existingIndex] = capturedToken
          }
        } else {
          tokenIndicesByRange[rangeKey] = tokens.count
          tokens.append(capturedToken)
        }
      }
    }

    tokens.sort {
      if $0.token.range.location != $1.token.range.location {
        return $0.token.range.location < $1.token.range.location
      }
      if $0.token.range.length != $1.token.range.length {
        return $0.token.range.length > $1.token.range.length
      }
      if $0.priority != $1.priority {
        return $0.priority > $1.priority
      }
      return $0.captureName < $1.captureName
    }
    return tokens.map(\.token)
  }

  // MARK: - Helpers

  private static func shouldReplace(_ existing: CapturedToken, with candidate: CapturedToken) -> Bool {
    if candidate.priority != existing.priority {
      return candidate.priority > existing.priority
    }

    return candidate.captureName < existing.captureName
  }

  private static func capturePriority(for captureName: String, token: LanguageConfiguration.Token) -> Int {
    switch captureName {
    case "string.escape":
      return 900
    case "type.constructor", "constructor", "type.builtin", "type":
      return 850
    case "function.macro", "constant.macro", "attribute":
      return 800
    case "function.method", "function.call":
      return 700
    case "variable.member", "property":
      return 650
    case "variable.parameter":
      return 600
    case "keyword", "keyword.function", "keyword.modifier", "keyword.type", "keyword.coroutine",
         "keyword.directive", "keyword.import", "keyword.repeat", "keyword.conditional",
         "keyword.conditional.ternary", "keyword.return", "keyword.exception", "keyword.operator":
      return 550
    case "operator", "punctuation.special", "punctuation.bracket", "punctuation.delimiter":
      return 500
    case "string", "string.regexp":
      return 450
    default:
      switch token {
      case .identifier(let flavour):
        switch flavour {
        case .type(_):
          return 850
        case .macro:
          return 800
        case .function, .method:
          return 700
        case .property:
          return 650
        case .parameter, .typeParameter:
          return 600
        default:
          return 100
        }
      case .keyword:
        return 550
      case .operator, .symbol:
        return 500
      case .string, .regexp:
        return 450
      default:
        return 100
      }
    }
  }

  /// Create a tree-sitter InputEdit from edit information.
  ///
  private func createInputEdit(oldText: String,
                               newText: String,
                               editedRange: NSRange,
                               delta: Int) -> InputEdit {
    // SwiftTreeSitter uses UTF-16LE input encoding.
    // Tree-sitter expects byte offsets; for UTF-16, that's 2 bytes per UTF-16 code unit.
    let oldLength = oldText.utf16.count
    let newLength = newText.utf16.count

    let start = min(editedRange.location, oldLength)
    let oldEnd = min(editedRange.location + editedRange.length, oldLength)
    let newEnd = min(editedRange.location + editedRange.length + delta, newLength)

    let startByte = UInt32(start * 2)
    let oldEndByte = UInt32(oldEnd * 2)
    let newEndByte = UInt32(newEnd * 2)

    // Calculate points (row, column in bytes).
    let startPoint = pointFor(utf16Offset: start, in: oldText)
    let oldEndPoint = pointFor(utf16Offset: oldEnd, in: oldText)
    let newEndPoint = pointFor(utf16Offset: newEnd, in: newText)

    return InputEdit(
      startByte: startByte,
      oldEndByte: oldEndByte,
      newEndByte: newEndByte,
      startPoint: startPoint,
      oldEndPoint: oldEndPoint,
      newEndPoint: newEndPoint
    )
  }

  /// Calculate a Point (row, column in bytes) for a UTF-16 code unit offset.
  ///
  private func pointFor(utf16Offset offset: Int, in text: String) -> Point {
    var row: UInt32 = 0
    var columnUnits: UInt32 = 0
    var currentOffset = 0

    for unit in text.utf16 {
      if currentOffset >= offset { break }
      if unit == 0x0A {
        row += 1
        columnUnits = 0
      } else {
        columnUnits += 1
      }
      currentOffset += 1
    }

    return Point(row: row, column: columnUnits * 2)
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
    "keyword.modifier": .keyword,
    "keyword.type": .keyword,
    "keyword.coroutine": .keyword,
    "keyword.directive": .keyword,
    "keyword.import": .keyword,
    "keyword.repeat": .keyword,
    "keyword.conditional": .keyword,
    "keyword.conditional.ternary": .keyword,
    "keyword.return": .keyword,
    "keyword.exception": .keyword,
    "keyword.operator": .keyword,

    // Literals
    "string": .string,
    "string.escape": .string,
    "string.regexp": .regexp,
    "character": .character,
    "character.special": .character,
    "number": .number,
    "number.float": .number,
    "boolean": .keyword,
    "constant.builtin": .keyword,

    // Comments
    "comment": .singleLineComment,
    "comment.documentation": .singleLineComment,

    // Identifiers
    "attribute": .identifier(.macro),
    "type": .identifier(.type(.other)),
    "type.constructor": .identifier(.type(.other)),
    "type.builtin": .identifier(.type(.other)),
    "variable": .identifier(.variable),
    "variable.builtin": .identifier(.variable),
    "variable.parameter": .identifier(.parameter),
    "variable.member": .identifier(.property),
    "property": .identifier(.property),
    "function.method": .identifier(.method),
    "function.call": .identifier(.function),
    "function.macro": .identifier(.macro),
    "constant.macro": .identifier(.macro),
    "constructor": .identifier(.function),
    "module": .identifier(.module),
    "label": .identifier(nil),

    // Operators and punctuation
    "operator": .operator(nil),
    "punctuation.delimiter": .symbol,
    "punctuation.bracket": .symbol,
    "punctuation.special": .symbol,
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
