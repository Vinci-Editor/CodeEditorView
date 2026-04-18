//
//  CodeEditing.swift
//  CodeEditorView
//
//  Created by Manuel M T Chakravarty on 06/01/2025.
//
//  This file implements common code editing operations.

import SwiftUI

import LanguageSupport

// MARK: -
// MARK: Pure editing core

struct EditingPair: Equatable, Sendable {
  var opening: String
  var closing: String
  var isQuote: Bool
}

struct EditorEditContext: Sendable {
  var textUTF16Length: Int
  var selections: [NSRange]
  var typedText: String
  var indentation: CodeEditor.IndentationConfiguration
  var pairEditing: CodeEditor.PairEditingConfiguration
}

struct SelectionTransform: Sendable {
  var replacementRange: NSRange
  var replacementText: String
  var selection: NSRange
}

struct PairEditResult: Sendable {
  var edits: [SelectionTransform]
  var textChanged: Bool
  var shouldBreakUndoCoalescing: Bool
}

struct ReturnEditResult: Sendable {
  var replacementText: String
  var selectionOffset: Int
}

private struct ReindentEdit {
  var replacementRange: NSRange
  var replacementText: String
  var replacementStartLine: Int
}

enum CodeEditingContext {

  static let defaultPairs: [EditingPair] = [
    EditingPair(opening: "(", closing: ")", isQuote: false),
    EditingPair(opening: "[", closing: "]", isQuote: false),
    EditingPair(opening: "{", closing: "}", isQuote: false),
    EditingPair(opening: "\"", closing: "\"", isQuote: true),
    EditingPair(opening: "'", closing: "'", isQuote: true)
  ]

  static func pair(opening: String) -> EditingPair? {
    defaultPairs.first { $0.opening == opening }
  }

  /// Curly braces are completed by Return, matching Xcode's block editing behavior.
  static func pairForImmediateInsertion(opening: String) -> EditingPair? {
    guard let pair = pair(opening: opening), pair.opening != "{" else { return nil }
    return pair
  }

  static func pair(closing: String) -> EditingPair? {
    defaultPairs.first { $0.closing == closing }
  }

  static func returnInsideCurlyBrace(baseIndent: Int,
                                     indentation: CodeEditor.IndentationConfiguration,
                                     hasClosingBraceAfter: Bool)
  -> ReturnEditResult {
    let innerIndent       = baseIndent + indentation.indentWidth
    let baseIndentString  = indentation.indentation(for: baseIndent)
    let innerIndentString = indentation.indentation(for: innerIndent)
    let closingText       = hasClosingBraceAfter ? "" : "}"

    return ReturnEditResult(replacementText: "\n" + innerIndentString + "\n" + baseIndentString + closingText,
                            selectionOffset: 1 + innerIndentString.utf16.count)
  }
}


// MARK: -
// MARK: Actions and commands

//extension CodeView {
//
//#if os(macOS)
//  override func performKeyEquivalent(with event: NSEvent) -> Bool {
//
//    if event.charactersIgnoringModifiers == "/"
//        && event.modifierFlags.intersection([.command, .control, .option]) == .command
//    {
//
//      comment()
//      return true
//
//    } else {
//      return super.performKeyEquivalent(with: event)
//    }
//  }
//#endif
//}

/// Adds an "Editor" menu with code editing commands and adds a duplicate command to the pasteboard commands.
///
public struct CodeEditingCommands: Commands {

  public init() { }

  public var body: some Commands {

    CommandGroup(after: .pasteboard) {
      CodeEditingDuplicateCommandView()
    }

    CommandMenu("Editor") {
      CodeEditingCommandsView()
    }
  }
}

@MainActor private func send(_ action: Selector) {
#if os(macOS)
  NSApplication.shared.sendAction(action, to: nil, from: nil)
#elseif os(iOS) || os(visionOS)
  UIApplication.shared.sendAction(action, to: nil, from: nil, for: nil)
#endif
}

/// Menu item for the duplicate command.
///
public struct CodeEditingDuplicateCommandView: View {

  public init() { }

  public var body: some View {

    Button {
      send(#selector(CodeEditorActions.duplicate(_:)))
    } label: {
      Label("Duplicate", systemImage: "plus.square.on.square")
    }
    .keyboardShortcut("D", modifiers: [.command])
  }
}

/// Code editing commands that can, for example, be used in a `CommandMenu` or `CommandGroup`.
///
public struct CodeEditingCommandsView: View {

  public init() { }

  public var body: some View {

    Button {
      send(#selector(CodeEditorActions.reindent(_:)))
    } label: {
      Label("Re-Indent", systemImage: "text.alignleft")
    }
    .keyboardShortcut("I", modifiers: [.control])

    Button {
      send(#selector(CodeEditorActions.shiftLeft(_:)))
    } label: {
      Label("Shift Left", systemImage: "decrease.indent")
    }
    .keyboardShortcut("[", modifiers: [.command])

    Button {
      send(#selector(CodeEditorActions.shiftRight(_:)))
    } label: {
      Label("Shift Right", systemImage: "increase.indent")
    }
    .keyboardShortcut("]", modifiers: [.command])

    Divider()

    Button {
      send(#selector(CodeEditorActions.commentSelection(_:)))
    } label: {
      Label("Comment Selection", systemImage: "text.bubble")
    }
    .keyboardShortcut("/", modifiers: [.command])
  }
}

/// Protocol with all code editor actions for maximum flexibility in invoking them via the responder chain.
///
@objc public protocol CodeEditorActions {

  func duplicate(_ sender: Any?)
  func reindent(_ sender: Any?)
  func shiftLeft(_ sender: Any?)
  func shiftRight(_ sender: Any?)
  func commentSelection(_ sender: Any?)
}

extension CodeView: @preconcurrency CodeEditorActions {

#if os(macOS)
  @objc public func duplicate(_ sender: Any?) { duplicate() }
#elseif os(iOS) || os(visionOS)
  @objc public override func duplicate(_ sender: Any?) { duplicate() }
#endif
  @objc public func reindent(_ sender: Any?) { reindent() }
  @objc public func shiftLeft(_ sender: Any?) { shiftLeftOrRight(doShiftLeft: true) }
  @objc public func shiftRight(_ sender: Any?) { shiftLeftOrRight(doShiftLeft: false) }
  @objc public func commentSelection(_ sender: Any?) { comment() }
}

// MARK: -
// MARK: Override tab key behaviour

extension CodeView {

#if os(macOS)

  override public func insertText(_ insertString: Any, replacementRange: NSRange) {
    let string = (insertString as? NSAttributedString)?.string ?? insertString as? String
    if let string,
       replacementRange.location == NSNotFound,
       performPairTextInsertion(string)
    {
      return
    }

    super.insertText(insertString, replacementRange: replacementRange)
    if let string { triggerCompletionIfNeeded(afterInserting: string) }
    if string == "}" { reindentAfterTypingClosingBrace() }
  }

  override public func deleteBackward(_ sender: Any?) {
    if performPairedDeletion(backward: true) { return }
    super.deleteBackward(sender)
  }

  override public func deleteForward(_ sender: Any?) {
    if performPairedDeletion(backward: false) { return }
    super.deleteForward(sender)
  }

  override public func keyDown(with event: NSEvent) {

    // Forward relevant events to completion panel if visible
    if completionPanel.isVisible && completionPanel.handleKeyEvent(event) {
      return
    }

    let noModifiers = event.modifierFlags.intersection([.shift, .control, .option, .command]) == []
    if event.keyCode == keyCodeTab && noModifiers {
      insertTab()
    } else if event.keyCode == keyCodeReturn && noModifiers {
      insertReturn()
    } else {
      super.keyDown(with: event)
    }
  }

#elseif os(iOS) || os(visionOS)

  override public func insertText(_ text: String) {
    if performPairTextInsertion(text) { return }
    super.insertText(text)
    triggerCompletionIfNeeded(afterInserting: text)
    if text == "}" { reindentAfterTypingClosingBrace() }
  }

  override public func deleteBackward() {
    if performPairedDeletion(backward: true) { return }
    super.deleteBackward()
  }

  override var keyCommands: [UIKeyCommand]? {
    var commands: [UIKeyCommand] = []

    // Completion navigation commands (when completion is visible)
    if isCompletionVisible {
      // Arrow up/down for navigation
      commands.append(UIKeyCommand(input: UIKeyCommand.inputUpArrow, modifierFlags: [], action: #selector(completionSelectPrevious)))
      commands.append(UIKeyCommand(input: UIKeyCommand.inputDownArrow, modifierFlags: [], action: #selector(completionSelectNext)))
      // Tab or Return to commit
      commands.append(UIKeyCommand(input: "\t", modifierFlags: [], action: #selector(completionCommit)))
      commands.append(UIKeyCommand(input: "\r", modifierFlags: [], action: #selector(completionCommit)))
      // Escape to cancel
      commands.append(UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(completionCancel)))
    } else {
      // Default tab/return handling when completion is not visible
      commands.append(UIKeyCommand(input: "\t", modifierFlags: [], action: #selector(insertTab)))
      commands.append(UIKeyCommand(input: "\r", modifierFlags: [], action: #selector(insertReturnCommand)))
    }

    // Ctrl+Space to trigger completion (always available)
    commands.append(UIKeyCommand(input: " ", modifierFlags: .control, action: #selector(triggerCompletion),
                                 discoverabilityTitle: "Complete"))
    commands.append(UIKeyCommand(input: "D", modifierFlags: .command, action: #selector(duplicate(_:)),
                                 discoverabilityTitle: "Duplicate"))
    commands.append(UIKeyCommand(input: "I", modifierFlags: .control, action: #selector(reindent(_:)),
                                 discoverabilityTitle: "Re-Indent"))
    commands.append(UIKeyCommand(input: "/", modifierFlags: .command, action: #selector(commentSelection(_:)),
                                 discoverabilityTitle: "Comment Selection"))
    commands.append(UIKeyCommand(input: "[", modifierFlags: .command, action: #selector(shiftLeft(_:)),
                                 discoverabilityTitle: "Shift Left"))
    commands.append(UIKeyCommand(input: "]", modifierFlags: .command, action: #selector(shiftRight(_:)),
                                 discoverabilityTitle: "Shift Right"))
    commands.append(UIKeyCommand(input: "\t", modifierFlags: .shift, action: #selector(shiftLeft(_:)),
                                 discoverabilityTitle: "Shift Left"))

    return commands
  }

  @objc func insertReturnCommand() {
    insertReturn()
  }

#endif
}

extension CodeView {

  private func performPairTextInsertion(_ text: String) -> Bool {
    guard text.utf16.count == 1,
          pairEditing.insertsPairs || pairEditing.skipsClosers,
          let codeStorage = optCodeStorage,
          let textContentStorage = optTextContentStorage
    else { return false }

    if pairEditing.skipsClosers,
       let pair = CodeEditingContext.pair(closing: text),
       skipOverClosingPair(pair, in: codeStorage)
    {
      if pair.closing == "}" { reindentAfterTypingClosingBrace() }
      return true
    }

    guard pairEditing.insertsPairs,
          let pair = CodeEditingContext.pairForImmediateInsertion(opening: text),
          shouldInsertPair(pair, in: codeStorage)
    else { return false }

    textContentStorage.performEditingTransaction {
      processSelectedRanges { range in
        if range.length > 0 && pairEditing.wrapsSelection,
           let selectedText = codeStorage.string[range]
        {
          let replacement = pair.opening + selectedText + pair.closing
          codeStorage.replaceCharacters(in: range, with: replacement)
          return NSRange(location: range.location + pair.opening.utf16.count, length: range.length)
        } else {
          let replacement = pair.opening + pair.closing
          codeStorage.replaceCharacters(in: range, with: replacement)
          return NSRange(location: range.location + pair.opening.utf16.count, length: 0)
        }
      }
    }

    CodeEditorInstrumentation.record(.typing)
    return true
  }

  private func skipOverClosingPair(_ pair: EditingPair, in codeStorage: CodeStorage) -> Bool {
    var skipped = false

#if os(macOS)
    let ranges = selectedRanges.map { $0.rangeValue }
#else
    let ranges = [selectedRange]
#endif
    guard ranges.allSatisfy({ range in
      range.length == 0 && character(at: range.location, in: codeStorage) == pair.closing
    }) else { return false }

    processSelectedRanges { range in
      skipped = true
      return NSRange(location: range.location + pair.closing.utf16.count, length: 0)
    }
    if skipped { CodeEditorInstrumentation.record(.typing) }
    return skipped
  }

  private func performPairedDeletion(backward: Bool) -> Bool {
    guard pairEditing.deletesEmptyPairs,
          let codeStorage = optCodeStorage,
          let textContentStorage = optTextContentStorage
    else { return false }

    var changed = false
    textContentStorage.performEditingTransaction {
      processSelectedRanges { range in
        guard range.length == 0 else { return range }

        if backward,
           let pair = CodeEditingContext.pair(opening: character(before: range.location, in: codeStorage) ?? ""),
           character(at: range.location, in: codeStorage) == pair.closing
        {
          let replacementRange = NSRange(location: range.location - pair.opening.utf16.count,
                                         length: pair.opening.utf16.count + pair.closing.utf16.count)
          codeStorage.replaceCharacters(in: replacementRange, with: "")
          changed = true
          return NSRange(location: replacementRange.location, length: 0)
        }

        if !backward,
           let pair = CodeEditingContext.pair(opening: character(at: range.location, in: codeStorage) ?? ""),
           character(at: range.location + pair.opening.utf16.count, in: codeStorage) == pair.closing
        {
          let replacementRange = NSRange(location: range.location,
                                         length: pair.opening.utf16.count + pair.closing.utf16.count)
          codeStorage.replaceCharacters(in: replacementRange, with: "")
          changed = true
          return NSRange(location: replacementRange.location, length: 0)
        }

        return range
      }
    }

    if changed { CodeEditorInstrumentation.record(.typing) }
    return changed
  }

  private func shouldInsertPair(_ pair: EditingPair, in codeStorage: CodeStorage) -> Bool {
    let location = currentInsertionLocation
    guard !isInCommentOrString(at: location, in: codeStorage) else { return false }

    if pair.isQuote && pairEditing.pairsQuotesInCodeContextOnly {
      let before = character(before: location, in: codeStorage)
      let after = character(at: location, in: codeStorage)
      if isIdentifierCharacter(before) || isIdentifierCharacter(after) { return false }
    }

    return true
  }

  private var currentInsertionLocation: Int {
#if os(macOS)
    selectedRange().location
#else
    selectedRange.location
#endif
  }

  private func isInCommentOrString(at location: Int, in codeStorage: CodeStorage) -> Bool {
    guard let codeStorageDelegate = codeStorage.delegate as? CodeStorageDelegate else { return false }
    let zeroLengthRange = NSRange(location: max(0, min(location, codeStorage.length)), length: 0)
    if codeStorageDelegate.lineMap.isWithinComment(range: zeroLengthRange) { return true }
    if location > 0, codeStorage.tokenOnly(at: location - 1)?.token == .string { return true }
    if codeStorage.tokenOnly(at: location)?.token == .string { return true }
    return false
  }

  private func character(before location: Int, in codeStorage: CodeStorage) -> String? {
    guard location > 0 else { return nil }
    return character(at: location - 1, in: codeStorage)
  }

  private func character(at location: Int, in codeStorage: CodeStorage) -> String? {
    guard location >= 0, location < codeStorage.length else { return nil }
    return (codeStorage.string as NSString).substring(with: NSRange(location: location, length: 1))
  }

  private func isIdentifierCharacter(_ character: String?) -> Bool {
    guard let character,
          let scalar = character.unicodeScalars.first
    else { return false }
    return CharacterSet.alphanumerics.union(.init(charactersIn: "_")).contains(scalar)
  }

  private func triggerCompletionIfNeeded(afterInserting text: String) {
    guard text.count == 1,
          let trigger = text.first,
          optLanguageService?.completionTriggerCharacters.value.contains(trigger) == true
    else { return }

    completionTask?.cancel()
    completionTask = Task {
#if os(macOS)
      let location = selectedRange().location
#else
      let location = selectedRange.location
#endif
      try await computeAndShowCompletions(at: location, explicitTrigger: false, reason: .character(trigger))
    }
  }
}

// MARK: -
// MARK: Selections

extension NSRange {

  /// Adjusts the selection represneted by `self` in accordance with replacing the characters in the given range with
  /// the given number of replacement characters.
  ///
  /// - Parameters:
  ///   - range: The range that is being replaced.
  ///   - delta: The number of characters in the replacement string.
  ///
  func adjustSelection(forReplacing range: NSRange, by length: Int) -> NSRange {

    let delta = length - range.length
    if let overlap = intersection(range) {

      if location <= range.location {

        if max >= range.max {
          // selection encompasses the whole replaced range
          return shifted(endBy: delta) ?? self
        } else {
          // selection overlaps with a proper prefix of the replaced range
          if range.length - overlap.length < -delta {
            // text shrinks sufficiently that the selection needs to shrink, too
            return shifted(endBy: -delta - (range.length - overlap.length)) ?? NSRange(location: location, length: 0)
          } else {
            return self
          }
        }

      } else {

        // selection overlaps with a proper suffix of the replaced range or is contained in the replaced range
        if range.length - overlap.length < -delta {
          // text shrinks sufficiently that the selection needs to shrink, too
          return shifted(endBy: -delta - (range.length - overlap.length)) ?? NSRange(location: location, length: 0)
        } else {
          return self
        }

      }

    } else {

      if location <= range.location {
        // selection is in front of the replaced text
        return self
      } else {
        // selection is behind the replaced text
        return shifted(by: delta) ?? self
      }
    }
  }
}


// MARK: -
// MARK: Editing functionality

extension CodeEditor.IndentationConfiguration {
  
  /// String of whitespace that indents from the start of the line to the first indentation point.
  ///
  var defaultIndentation: String { indentation(for: indentWidth) }
  
  /// Yield the whitespace string realising the indentation up to `column` under the current configuration.
  ///
  /// - Parameter column: The desired indentation.
  /// - Returns: A string that realises that indentation.
  ///
  func indentation(for column: Int) -> String {
    let safeColumn = max(0, column)
    switch preference {
    case .preferSpaces:
      return String(repeating: " ", count: safeColumn)
    case .preferTabs:
      return String(repeating: "\t", count: safeColumn / tabWidth) + String(repeating: " ", count: safeColumn % tabWidth)
    }
  }

  /// Determine the column index of the first character that is neither a tab or space character in the given line
  /// string or the end index of the line.
  ///
  /// - Parameter line: The string containing the characters of the line.
  /// - Returns: The (character) index of the first character that is neither space nor tab or the end index of the line.
  ///
  /// NB: If the line contains only space and tab characters, the result will be the length of the string.
  ///
  func currentIndentation(in line: any StringProtocol) -> Int {

    let index = (line.firstIndex{ !($0 == " " || $0 == "\t") }) ?? line.endIndex
    return index.utf16Offset(in: line)
  }

  /// Determine the column index of the first character that is neither a tab or space character in the given line
  /// string if there is any.
  ///
  /// - Parameter line: The string containing the characters of the line.
  /// - Returns: The (character) index of the first character that is neither space nor tab or nil if there is no such
  ///     character or if that character is a whitespace (notably a newline charachter).
  ///
  func startOfText(in line: any StringProtocol) -> Int? {

    if let index = (line.firstIndex{ !($0 == " " || $0 == "\t") }) {
      if line[index].isWhitespace { return nil } else { return index.utf16Offset(in: line) }
    } else { return nil }
  }
}

extension CodeView {
  
  /// Shift all lines that are part of the current selection one indentation level to the left or right.
  ///
  func shiftLeftOrRight(doShiftLeft: Bool) {
    guard let textContentStorage  = optTextContentStorage,
          let codeStorage         = optCodeStorage,
          let codeStorageDelegate = codeStorage.delegate as? CodeStorageDelegate
    else { return }

    func shift(line: Int, adjusting range: NSRange) -> NSRange {
      guard let theLine = codeStorageDelegate.lineMap.lookup(line: line)
      else { return range }

      if doShiftLeft {

        var location        = theLine.range.location
        var length          = 0
        var remainingIndent = indentation.indentWidth
        var reminder        = ""
        while remainingIndent > 0 {

          guard let characterRange = Range<String.Index>(NSRange(location: location, length: 1), in: codeStorage.string)
          else { return range }
          let character = codeStorage.string[characterRange]
          if character == " " {

            remainingIndent -= 1
            length          += 1

          } else if character == "\t" {

            let tabWidth  = indentation.tabWidth,
                tabIndent = if length % tabWidth == 0 { tabWidth } else { tabWidth - length % tabWidth }
            if tabIndent > remainingIndent {

              // We got a tab character, but the remaining identation to remove is less than the tabs indentation at
              // this point => replace the tab by as many spaces as indentation needs to remain.
              remainingIndent = 0
              reminder += String(repeating: " ", count: tabIndent - remainingIndent)

            } else {
              remainingIndent -= tabIndent
            }
            length += 1

          } else {
            // Stop if we hit a character that is neither a space or tab character.
            remainingIndent = 0
          }
          location += 1
        }

        let replacementRange = NSRange(location: theLine.range.location, length: length)
        codeStorage.replaceCharacters(in: replacementRange, with: reminder)
        return range.adjustSelection(forReplacing: replacementRange, by: reminder.utf16.count)

      } else {

        let replacementRange = NSRange(location: theLine.range.location, length: 0)
        codeStorage.replaceCharacters(in: replacementRange, with: indentation.defaultIndentation)
        return range.adjustSelection(forReplacing: replacementRange, by: indentation.defaultIndentation.utf16.count)

      }
    }

    textContentStorage.performEditingTransaction {
      processSelectedRanges { range in

        let lines = codeStorageDelegate.lineMap.linesContaining(range: range)
        var newRange = range
        for line in lines {
          newRange = shift(line: line, adjusting: newRange)
        }
        return newRange
      }
    }
  }

  /// Comment or uncomment the selection or multiple lines.
  ///
  /// For each selection range in the current selection, proceed as follows:
  ///
  /// 1. If the selection has zero length (it is an insertion point), comment or uncomment the line where the selection
  ///    is located.
  /// 2. If the selection has a length greater zero, but does not extend across a line end, enclose the selection in
  ///    nested comments or remove the nested comment brackets, if the selection is already enclosed in comments. In the
  ///    latter case, the selection may (partially) include the comment brackets. This is unless the selected range
  ///    totally or partially covers commented text. In that case, proceed as if the selection had zero length.
  /// 3. If the selection extends across multiple lines, comment all lines, unless the first and last line are already
  ///    commented. In the latter case, uncomment all commented lines.
  ///
  func comment() {
    guard let textContentStorage  = optTextContentStorage,
          let codeStorage         = optCodeStorage,
          let codeStorageDelegate = codeStorage.delegate as? CodeStorageDelegate
    else { return }

    // Determine whether the leading token on the given line is a single line comment token.
    func isCommented(line: Int) -> Bool {
      guard let theLine = codeStorageDelegate.lineMap.lookup(line: line) else { return false }

      return theLine.info?.tokens.first?.token == .singleLineComment
    }

    // Insert single line comment token at the start of the line.
    func comment(line: Int, with range: NSRange) -> NSRange {
      guard let theLine                 = codeStorageDelegate.lineMap.lookup(line: line),
            let singleLineCommentString = language.singleLineComment
      else { return range }

      // Insert single line comment
      let replacementRange = NSRange(location: theLine.range.location, length: 0)
      codeStorage.replaceCharacters(in: replacementRange, with: singleLineCommentString)
      return range.adjustSelection(forReplacing: replacementRange, by: singleLineCommentString.count)
    }
    
    // Remove leading single line comment token (if any).
    func uncomment(line: Int, with range: NSRange) -> NSRange {
      guard let theLine = codeStorageDelegate.lineMap.lookup(line: line) else { return range }

      if let firstToken = theLine.info?.tokens.first,
         firstToken.token == .singleLineComment,
         let tokenRange = firstToken.range.shifted(by: theLine.range.location)
      {

        codeStorage.deleteCharacters(in: tokenRange)
        return range.adjustSelection(forReplacing: tokenRange, by: 0)

      } else {
        return range
      }
    }

    // Determine whether the selection is fully enclosed in a bracketed comment on the given line. If so, return the
    // comment range (wrt to the whole document).
    func isCommentBracketed(range: NSRange, on line: Int) -> NSRange? {
      guard let theLine       = codeStorageDelegate.lineMap.lookup(line: line),
            let tokens        = theLine.info?.tokens,
            let commentRanges = theLine.info?.commentRanges,
            let localRange    = range.shifted(by: -theLine.range.location)
      else { return nil }

      for commentRange in commentRanges {
        if commentRange.intersection(localRange) == localRange
            && (tokens.contains{ $0.range.location == commentRange.location && $0.token == .nestedCommentOpen })
        {
          return commentRange.shifted(by: theLine.range.location)
        }
      }
      return nil
    }

    // Add comment brackets around the given range.
    func commentBracket(range: NSRange) -> NSRange {
      guard let (openString, closeString) = language.nestedComment else { return range }

      codeStorage.replaceCharacters(in: NSRange(location: range.max, length: 0), with: closeString)
      codeStorage.replaceCharacters(in: NSRange(location: range.location, length: 0), with: openString)
      return range.shifted(by: openString.count) ?? range
    }

    // Remove comment brackets at the ends of the given comment range.
    func uncommentBracket(range: NSRange, in commentRange: NSRange) -> NSRange {
      guard let (openString, closeString) = language.nestedComment else { return range }

      codeStorage.deleteCharacters(in: NSRange(location: commentRange.max - closeString.count,
                                               length: closeString.count))
      codeStorage.deleteCharacters(in: NSRange(location: commentRange.location, length: openString.count))
      let newCommentRange = commentRange.shifted(by: -openString.count)?.shifted(endBy: -closeString.count) ?? commentRange
      return (range.shifted(by: -openString.count) ?? range).intersection(newCommentRange) ?? range
    }

    textContentStorage.performEditingTransaction {
      processSelectedRanges { range in

        let lines = codeStorageDelegate.lineMap.linesContaining(range: range)
        guard let firstLine = lines.first else { return range }

        var newRange = range
        if range.length == 0 {

          // Case 1 of the specification
          newRange = if isCommented(line: firstLine) {
                       uncomment(line: firstLine, with: range)
                     } else {
                       comment(line: firstLine, with: range)
                     }

        } else if lines.count == 1 {

          // Case 2 of the specification
          guard let theLine = codeStorageDelegate.lineMap.lookup(line: firstLine) else { return range }
          let lineLocation = range.location - theLine.range.location
          if let commentRange = isCommentBracketed(range: range, on: firstLine) {
            newRange = uncommentBracket(range: range, in: commentRange)
          } else {

            let partiallyCommented = theLine.info?.commentRanges.contains{ $0.contains(lineLocation)
                                      || $0.contains(lineLocation + range.length) }
            if partiallyCommented == true {

              if isCommented(line: firstLine) {
                newRange = uncomment(line: firstLine, with: range)
              } else {
                newRange = comment(line: firstLine, with: range)
              }

            } else {
              newRange = commentBracket(range: range)
            }

          }

        } else {

          // Case 3 of the specification
          // NB: It is crucial to process lines in reverse order as any text change invalidates ranges in the line map
          //     after the change.
          guard let lastLine = lines.last else { return range }
          if isCommented(line: firstLine) && isCommented(line: lastLine) {
            for line in lines.reversed() { newRange = uncomment(line: line, with: newRange) }
          } else {
            for line in lines.reversed() { newRange = comment(line: line, with: newRange) }
          }

        }
        return newRange
      }
    }
  }

  func duplicate() {
    guard let textContentStorage  = optTextContentStorage,
          let codeStorage         = optCodeStorage,
          let codeStorageDelegate = codeStorage.delegate as? CodeStorageDelegate
    else { return }

    /// Duplicate the given range right after the end of the original range and eturn the range of the duplicate.
    ///
    func duplicate(range: NSRange) -> NSRange {

      guard let text = codeStorage.string[range] else { return range }
      codeStorage.replaceCharacters(in: NSRange(location: range.max, length: 0), with: String(text))
      return NSRange(location: range.max, length: range.length)
    }

    textContentStorage.performEditingTransaction {
      processSelectedRanges { range in

        if range.length == 0 {

          guard let line      = codeStorageDelegate.lineMap.lineOf(index: range.location),
                let lineRange = codeStorageDelegate.lineMap.lookup(line: line)?.range
          else { return range }
          let _ = duplicate(range: lineRange)
          return NSRange(location: range.location + lineRange.length, length: 0)

        } else {
          return duplicate(range: range)
        }
      }
    }
  }
  
  /// Indent all lines currently selected.
  ///
  func reindent() {
    guard let textContentStorage = optTextContentStorage else { return }

    textContentStorage.performEditingTransaction {
      processSelectedRanges { reindent(range: $0) }
    }
  }

  private func reindent(range: NSRange) -> NSRange {

    guard let codeStorage         = optCodeStorage,
          let codeStorageDelegate = codeStorage.delegate as? CodeStorageDelegate else {
      return range
    }

    let lines = codeStorageDelegate.lineMap.linesContaining(range: range)
    guard let firstLine = lines.first else { return range }

    if range.length == 0 {

      guard let lineInfo = codeStorageDelegate.lineMap.lookup(line: firstLine),
            let textRange = Range<String.Index>(lineInfo.range, in: codeStorage.string),
            let edit = contextualReindentEdit(replacementLines: lines,
                                              in: codeStorage,
                                              lineMap: codeStorageDelegate.lineMap)
      else { return range }

      let lineText = codeStorage.string[textRange]
      let currentIndent = indentation.currentIndentation(in: lineText)
      let offsetAfterIndent = max(0, range.location - lineInfo.range.location - currentIndent)
      let newRange = reindentedInsertionPoint(forLine: firstLine,
                                              offsetAfterIndent: offsetAfterIndent,
                                              in: edit)
                    ?? range.adjustSelection(forReplacing: edit.replacementRange,
                                             by: edit.replacementText.utf16.count)
      codeStorage.replaceCharacters(in: edit.replacementRange, with: edit.replacementText)
      return newRange

    } else {

      guard let edit = contextualReindentEdit(replacementLines: lines,
                                              in: codeStorage,
                                              lineMap: codeStorageDelegate.lineMap)
      else { return range }

      codeStorage.replaceCharacters(in: edit.replacementRange, with: edit.replacementText)

      let lengthDiff = edit.replacementText.utf16.count - edit.replacementRange.length
      return NSRange(location: range.location, length: max(0, range.length + lengthDiff))

    }
  }

  private func reindentAfterTypingClosingBrace() {
    guard let textContentStorage  = optTextContentStorage,
          let codeStorage         = optCodeStorage,
          let codeStorageDelegate = codeStorage.delegate as? CodeStorageDelegate
    else { return }

    textContentStorage.performEditingTransaction {
      processSelectedRanges { range in
        let closeLocation = range.location - 1
        guard range.length == 0,
              closeLocation >= 0,
              character(at: closeLocation, in: codeStorage) == "}",
              let closeLine = codeStorageDelegate.lineMap.lineOf(index: closeLocation),
              let closeLineInfo = codeStorageDelegate.lineMap.lookup(line: closeLine),
              let closeLineRange = Range<String.Index>(closeLineInfo.range, in: codeStorage.string)
        else { return range }

        let bracketLines = enclosingBracketLines(before: closeLocation,
                                                 in: codeStorage,
                                                 lineMap: codeStorageDelegate.lineMap)
        guard let openingLine = bracketLines.innermostCurly,
              openingLine <= closeLine
        else { return range }

        let replacementLines = openingLine..<(closeLine + 1)
        guard let edit = contextualReindentEdit(replacementLines: replacementLines,
                                                contextStartLine: bracketLines.root ?? openingLine,
                                                contextEndLine: closeLine + 1,
                                                in: codeStorage,
                                                lineMap: codeStorageDelegate.lineMap)
        else { return range }

        let currentIndent = indentation.currentIndentation(in: codeStorage.string[closeLineRange])
        let offsetAfterIndent = max(0, range.location - closeLineInfo.range.location - currentIndent)
        let newRange = reindentedInsertionPoint(forLine: closeLine,
                                                offsetAfterIndent: offsetAfterIndent,
                                                in: edit)
                      ?? range.adjustSelection(forReplacing: edit.replacementRange,
                                               by: edit.replacementText.utf16.count)
        codeStorage.replaceCharacters(in: edit.replacementRange, with: edit.replacementText)
        return newRange
      }
    }
  }

  private func contextualReindentEdit(replacementLines: Range<Int>,
                                      contextStartLine: Int? = nil,
                                      contextEndLine: Int? = nil,
                                      in codeStorage: CodeStorage,
                                      lineMap: LineMap<LineInfo>) -> ReindentEdit? {
    guard let firstReplacementLine = replacementLines.first,
          replacementLines.endIndex <= lineMap.lines.count
    else { return nil }

    var bracketContextStart: Int?
    if contextStartLine == nil {
      let lineStart = lineMap.lookup(line: firstReplacementLine)?.range.location ?? 0
      bracketContextStart = enclosingBracketLines(before: lineStart,
                                                  in: codeStorage,
                                                  lineMap: lineMap).root
    }
    let inferredContextStart = contextStartLine ?? bracketContextStart ?? firstReplacementLine
    let safeContextStart = max(0, min(inferredContextStart, firstReplacementLine))
    let requestedContextEnd = contextEndLine ?? replacementLines.endIndex
    let safeContextEnd = min(lineMap.lines.count, max(replacementLines.endIndex, requestedContextEnd))
    guard safeContextStart < safeContextEnd else { return nil }

    let contextLines = safeContextStart..<safeContextEnd
    let contextRange = lineMap.charRangeOf(lines: contextLines)
    guard let contextStringRange = Range<String.Index>(contextRange, in: codeStorage.string)
    else { return nil }

    let contextString = String(codeStorage.string[contextStringRange])
    let reindentedContext = language.reindent(contextString,
                                              indentWidth: indentation.indentWidth,
                                              useTabs: indentation.preference == .preferTabs,
                                              tabWidth: indentation.tabWidth)
    let reindentedLineMap = LineMap<Void>(string: reindentedContext)
    let relativeReplacementStart = replacementLines.startIndex - safeContextStart
    let relativeReplacementEnd = replacementLines.endIndex - safeContextStart
    let relativeReplacementLines = relativeReplacementStart..<relativeReplacementEnd
    guard relativeReplacementLines.startIndex >= 0,
          relativeReplacementLines.endIndex <= reindentedLineMap.lines.count
    else { return nil }

    let replacementTextRange = reindentedLineMap.charRangeOf(lines: relativeReplacementLines)
    guard let replacementStringRange = Range<String.Index>(replacementTextRange, in: reindentedContext)
    else { return nil }

    return ReindentEdit(replacementRange: lineMap.charRangeOf(lines: replacementLines),
                        replacementText: String(reindentedContext[replacementStringRange]),
                        replacementStartLine: replacementLines.startIndex)
  }

  private func enclosingBracketLines(before location: Int,
                                     in codeStorage: CodeStorage,
                                     lineMap: LineMap<LineInfo>) -> (root: Int?, innermost: Int?, innermostCurly: Int?) {
    guard let tokeniser = LanguageConfiguration.Tokeniser(for: language.tokenDictionary,
                                                          caseInsensitiveReservedIdentifiers: language.caseInsensitiveReservedIdentifiers)
    else { return (nil, nil, nil) }

    let safeLocation = max(0, min(location, codeStorage.length))
    guard let prefixRange = Range<String.Index>(NSRange(location: 0, length: safeLocation), in: codeStorage.string)
    else { return (nil, nil, nil) }

    var stack: [(token: LanguageConfiguration.Token, location: Int)] = []
    for token in codeStorage.string[prefixRange].tokenise(with: tokeniser, state: LanguageConfiguration.State.tokenisingCode) {
      switch token.token {
      case .roundBracketOpen, .squareBracketOpen, .curlyBracketOpen:
        stack.append((token: token.token, location: token.range.location))

      case .roundBracketClose, .squareBracketClose, .curlyBracketClose:
        guard let matchingBracket = token.token.matchingBracket else { continue }
        if let matchingIndex = stack.lastIndex(where: { $0.token == matchingBracket }) {
          stack.removeSubrange(matchingIndex...)
        }

      default:
        continue
      }
    }

    return (root: stack.first.flatMap { lineMap.lineOf(index: $0.location) },
            innermost: stack.last.flatMap { lineMap.lineOf(index: $0.location) },
            innermostCurly: stack.last(where: { $0.token == .curlyBracketOpen }).flatMap {
              lineMap.lineOf(index: $0.location)
            })
  }

  private func reindentedInsertionPoint(forLine line: Int,
                                        offsetAfterIndent: Int,
                                        in edit: ReindentEdit) -> NSRange? {
    let relativeLine = line - edit.replacementStartLine
    guard relativeLine >= 0 else { return nil }

    let replacementLineMap = LineMap<Void>(string: edit.replacementText)
    guard let lineInfo = replacementLineMap.lookup(line: relativeLine),
          let lineRange = Range<String.Index>(lineInfo.range, in: edit.replacementText)
    else { return nil }

    let lineText = edit.replacementText[lineRange]
    let newIndent = indentation.currentIndentation(in: lineText)
    let locationInLine = min(lineInfo.range.length, newIndent + offsetAfterIndent)
    return NSRange(location: edit.replacementRange.location + lineInfo.range.location + locationInLine, length: 0)
  }

  /// Implements the indentation behaviour for the tab key.
  ///
  /// * Whether to insert a tab character or spaces depends on the indentation configuration, which also determines tab
  ///   and indentation width.
  /// * Depending on the setting, inserting a tab triggers indenting the current line or actually inserting a tab
  ///   equivalent.
  /// * If the selection has length greater 0, a tab equivalent is always inserted.
  /// * If the selection spans multiple lines, the lines are always indented.
  ///
  @objc func insertTab() {

    guard let textContentStorage  = optTextContentStorage,
          let codeStorage         = optCodeStorage,
          let codeStorageDelegate = codeStorage.delegate as? CodeStorageDelegate
    else { return }
    
    // Determine the column index of the first character that is neither a space nor a tab character. It can be a
    // newline or the end of the line.
    func currentIndentation(of line: Int) -> Int? {

      guard let lineInfo  = codeStorageDelegate.lineMap.lookup(line: line),
            let textRange = Range<String.Index>(lineInfo.range, in: codeStorage.string)
      else { return nil }
      return indentation.currentIndentation(in: codeStorage.string[textRange])
    }

    func insertTab(in range: NSRange) -> NSRange {
      guard let firstLine   = codeStorageDelegate.lineMap.lineOf(index: range.location),
            let lineInfo    = codeStorageDelegate.lineMap.lookup(line: firstLine)
      else { return range }

      let column            = range.location - lineInfo.range.location,
          nextTabStopIndex  = (column / indentation.tabWidth + 1) * indentation.tabWidth,
          replacementString = if indentation.preference == .preferTabs { "\t" }
                              else { String(repeating: " ", count: nextTabStopIndex - column) }
      codeStorage.replaceCharacters(in: range, with: replacementString)

      return NSRange(location: range.location + replacementString.utf16.count, length: 0)
    }

    switch indentation.tabKey {

    case .identsInWhitespace:
      textContentStorage.performEditingTransaction {
        processSelectedRanges { range in

          if range.length > 0 { return insertTab(in: range) }
          else {

            guard let firstLine   = codeStorageDelegate.lineMap.lineOf(index: range.location),
                  let lineInfo    = codeStorageDelegate.lineMap.lookup(line: firstLine),
                  let indentDepth = currentIndentation(of: firstLine)
            else { return range }
            let newRange = if range.location - lineInfo.range.location < indentDepth { reindent(range: range) }
                          else { insertTab(in: range) }
            return newRange

          }
        }
      }

    case .indentsAlways:
      textContentStorage.performEditingTransaction {
        processSelectedRanges { reindent(range: $0) }
      }

    case .insertsTab:
      textContentStorage.performEditingTransaction {
        processSelectedRanges { insertTab(in: $0) }
      }

    }
  }

  func insertReturn () {

    guard let textContentStorage  = optTextContentStorage,
          let codeStorage         = optCodeStorage,
          let codeStorageDelegate = codeStorage.delegate as? CodeStorageDelegate
    else { return }

    func predictedIndentation(after index: Int) -> Int {
      guard let line     = codeStorageDelegate.lineMap.lineOf(index: index),
            let lineInfo = codeStorageDelegate.lineMap.lookup(line: line)
      else { return 0 }
      let columnIndex = index - lineInfo.range.lowerBound

      if language.indentationSensitiveScoping {

        let range = NSRange(location: lineInfo.range.lowerBound, length: index - lineInfo.range.lowerBound)
        guard let stringRange = Range<String.Index>(range, in: codeStorage.string) else { return 0 }
        let indentString = codeStorage.string[stringRange].prefix(while: { $0 == " " || $0 == "\t" })
        return indentString.count

      } else {

        // FIXME: Only languages in the C tradition use curly braces for scoping. Needs to be more flexible.
        guard let info = lineInfo.info else { return 0 }
        let curlyBracketDepth = info.curlyBracketDepthStart,
            initialTokens     = info.tokens.prefix{ $0.range.lowerBound < columnIndex },
            openCurlyBrackets = initialTokens.reduce(0) {
              $0 + ($1.token == LanguageConfiguration.Token.curlyBracketOpen ? 1 : 0)
            },
            closeCurlyBrackets = initialTokens.reduce(0) {
              $0 + ($1.token == LanguageConfiguration.Token.curlyBracketClose ? 1 : 0)
            }
        return (curlyBracketDepth + openCurlyBrackets - closeCurlyBrackets) * indentation.indentWidth

      }
    }

    /// Check if the cursor is immediately after an opening curly brace.
    ///
    func isAfterOpeningCurlyBrace(at index: Int) -> Bool {
      guard index > 0,
            character(before: index, in: codeStorage) == "{"
      else { return false }

      if let token = codeStorage.tokenOnly(at: index - 1),
         token.token == .curlyBracketOpen,
         token.range.upperBound == index
      {
        return true
      }

      guard let tokeniser = LanguageConfiguration.Tokeniser(for: language.tokenDictionary,
                                                            caseInsensitiveReservedIdentifiers: language.caseInsensitiveReservedIdentifiers),
            let prefixRange = Range<String.Index>(NSRange(location: 0, length: index), in: codeStorage.string)
      else { return true }

      let lastToken = codeStorage.string[prefixRange]
        .tokenise(with: tokeniser, state: LanguageConfiguration.State.tokenisingCode)
        .last
      return lastToken?.token == .curlyBracketOpen && lastToken?.range.upperBound == index
    }

    /// Get the base indentation of the line containing the given index.
    ///
    func baseIndentation(at index: Int) -> Int {
      guard let line     = codeStorageDelegate.lineMap.lineOf(index: index),
            let lineInfo = codeStorageDelegate.lineMap.lookup(line: line)
      else { return 0 }

      let lineRange = lineInfo.range
      guard let stringRange = Range<String.Index>(lineRange, in: codeStorage.string) else { return 0 }
      let lineString = codeStorage.string[stringRange]
      return indentation.currentIndentation(in: lineString)
    }

    /// Check if there's a closing curly brace immediately after the cursor position.
    ///
    func hasClosingCurlyBraceAfter(at index: Int) -> Bool {
      guard index < codeStorage.length,
            character(at: index, in: codeStorage) == "}"
      else { return false }

      if let token = codeStorage.tokenOnly(at: index),
         token.token == .curlyBracketClose,
         token.range.lowerBound == index
      {
        return true
      }

      return true
    }

    textContentStorage.performEditingTransaction {
      processSelectedRanges { range in

        let desiredIndent = if indentation.indentOnReturn { predictedIndentation(after: range.location) } else { 0 },
            indentString  = indentation.indentation(for: desiredIndent)

        if autoBrace.completeOnEnter && isAfterOpeningCurlyBrace(at: range.location) {
          let edit = CodeEditingContext.returnInsideCurlyBrace(
            baseIndent: baseIndentation(at: range.location),
            indentation: indentation,
            hasClosingBraceAfter: hasClosingCurlyBraceAfter(at: range.location)
          )
          codeStorage.replaceCharacters(in: range, with: edit.replacementText)
          return NSRange(location: range.location + edit.selectionOffset, length: 0)
        } else {
          codeStorage.replaceCharacters(in: range, with: "\n" + indentString)
          return NSRange(location: range.location + 1 + indentString.count, length: 0)
        }
      }
    }
  }

  /// Execute a block for each selected range, from back to front.
  ///
  /// - Parameter block: The block to be executed for each selection range, which may modify the underlying text storage
  ///     and returns a new selection range.
  ///
  func processSelectedRanges(with block: (NSRange) -> NSRange) {

    // NB: It is crucial to process selected ranges in reverse order as any text change invalidates ranges in the line
    //     map after the change.
#if os(macOS)
    let ranges = selectedRanges.reversed()
#elseif os(iOS) || os(visionOS)
    let ranges = [NSValue(range: selectedRange)]
#endif
    var newSelected: [NSRange] = []
    for rangeAsValue in ranges {
      let range = rangeAsValue.rangeValue

      let newRange = block(range)
      newSelected.append(newRange)
    }
#if os(macOS)
    if !newSelected.isEmpty { selectedRanges = newSelected.reversed().map{ NSValue(range: $0) } }
#elseif os(iOS) || os(visionOS)
    if let selection = newSelected.first { selectedRange = selection }
#endif
  }
}


// MARK: -
// MARK: Standalone reindentation helper

extension LanguageConfiguration {

  /// Reindents the given string using the specified indentation configuration.
  ///
  /// - Parameters:
  ///   - string: The string to reindent.
  ///   - configuration: The indentation configuration to use.
  /// - Returns: The reindented string.
  ///
  /// This is a convenience wrapper around `reindent(_:indentWidth:useTabs:tabWidth:)` that uses
  /// `CodeEditor.IndentationConfiguration`.
  ///
  public func reindent(_ string: String, using configuration: CodeEditor.IndentationConfiguration) -> String {
    reindent(string,
             indentWidth: configuration.indentWidth,
             useTabs: configuration.preference == .preferTabs,
             tabWidth: configuration.tabWidth)
  }
}
