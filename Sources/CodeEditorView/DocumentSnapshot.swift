//
//  DocumentSnapshot.swift
//  CodeEditorView
//
//  Immutable editor snapshot metadata for versioned async pipelines.
//

import Foundation
import LanguageSupport

struct DocumentVersion: Equatable, Comparable, Hashable, Sendable {
  var rawValue: Int

  static let initial = DocumentVersion(rawValue: 0)

  static func < (lhs: DocumentVersion, rhs: DocumentVersion) -> Bool {
    lhs.rawValue < rhs.rawValue
  }

  func advanced() -> DocumentVersion {
    DocumentVersion(rawValue: rawValue + 1)
  }
}

struct DocumentSnapshot {
  var version: DocumentVersion
  var utf16Length: Int
  var lineRanges: [NSRange]
  var diagnostics: Set<TextLocated<Message>>
  var semanticOverlays: [Int: [(token: LanguageConfiguration.Token, range: NSRange)]]

  init(version: DocumentVersion,
       text: String,
       lineMap: LineMap<LineInfo>,
       diagnostics: Set<TextLocated<Message>> = [],
       semanticOverlays: [Int: [(token: LanguageConfiguration.Token, range: NSRange)]] = [:])
  {
    self.version = version
    self.utf16Length = text.utf16.count
    self.lineRanges = lineMap.lines.map(\.range)
    self.diagnostics = diagnostics
    self.semanticOverlays = semanticOverlays
  }
}

extension NSRange {
  func checkedStringRange(in string: String) -> Range<String.Index>? {
    guard location >= 0, length >= 0, max <= string.utf16.count else { return nil }
    let startUTF16 = string.utf16.index(string.utf16.startIndex, offsetBy: location)
    let endUTF16 = string.utf16.index(startUTF16, offsetBy: length)
    guard let start = String.Index(startUTF16, within: string),
          let end = String.Index(endUTF16, within: string)
    else { return nil }
    return start..<end
  }
}
