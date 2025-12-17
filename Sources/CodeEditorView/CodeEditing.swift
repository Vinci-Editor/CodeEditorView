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
    commands.append(UIKeyCommand(input: " ", modifierFlags: .control, action: #selector(triggerCompletion)))

    return commands
  }

  @objc func insertReturnCommand() {
    insertReturn()
  }

#endif
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
        return range.adjustSelection(forReplacing: replacementRange, by: 2)

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

    // Determine the column index of the first character that is neither a space nor a tab character. It can be a
    // newline or the end of the line.
    func currentIndentation(of line: Int) -> Int? {

      guard let lineInfo  = codeStorageDelegate.lineMap.lookup(line: line),
            let textRange = Range<String.Index>(lineInfo.range, in: codeStorage.string)
      else { return nil }
      return indentation.currentIndentation(in: codeStorage.string[textRange])
    }

    // Determine the column index of the first non-whitespace character.
    func startOfText(of line: Int) -> Int? {

      guard let lineInfo  = codeStorageDelegate.lineMap.lookup(line: line),
            let textRange = Range<String.Index>(lineInfo.range, in: codeStorage.string)
      else { return nil }
      return indentation.startOfText(in: codeStorage.string[textRange]) ?? 0
    }

    // Check if a line starts with a closing bracket (for proper dedentation)
    func lineStartsWithClosingBracket(_ line: Int) -> Bool {
      guard let lineInfo  = codeStorageDelegate.lineMap.lookup(line: line),
            let textRange = Range<String.Index>(lineInfo.range, in: codeStorage.string)
      else { return false }
      let trimmed = codeStorage.string[textRange].drop(while: { $0 == " " || $0 == "\t" })
      guard let firstChar = trimmed.first else { return false }
      return firstChar == "}" || firstChar == ")" || firstChar == "]"
    }

    func predictedIndentation(for line: Int) -> Int {
      if language.indentationSensitiveScoping {

        // FIXME: We might want to cache that information.

        var scannedLine = line
        while scannedLine >= 0 {

          if let index = startOfText(of: scannedLine) { return index }
          else {
            scannedLine -= 1
          }

        }
        return 0

      } else {

        // FIXME: Only languages in the C tradition use curly braces for scoping. Needs to be more flexible.
        guard let lineInfo = codeStorageDelegate.lineMap.lookup(line: line) else { return 0 }
        var depth = lineInfo.info?.curlyBracketDepthStart ?? 0

        // Closing brackets should be at parent level (depth - 1)
        if lineStartsWithClosingBracket(line) && depth > 0 {
          depth -= 1
        }

        return depth * indentation.indentWidth

      }
    }

    let lines = codeStorageDelegate.lineMap.linesContaining(range: range)
    guard let firstLine = lines.first else { return range }

    if range.length == 0 {

      let desiredIndent = predictedIndentation(for: firstLine)
      guard let currentIndent = currentIndentation(of: firstLine),
            let lineInfo      = codeStorageDelegate.lineMap.lookup(line: firstLine)
      else { return range }
      let indentString = indentation.indentation(for: desiredIndent)
      codeStorage.replaceCharacters(in: NSRange(location: lineInfo.range.location, length: currentIndent),
                                    with: indentString)
      return NSRange(location: lineInfo.range.location + indentString.count, length: 0)

    } else {

      // Multi-line selection: use language.reindent() for proper relative indentation
      // This ensures the selection is treated as standalone code and reindented consistently
      guard let firstLineInfo = codeStorageDelegate.lineMap.lookup(line: firstLine),
            let lastLine = lines.last,
            let lastLineInfo = codeStorageDelegate.lineMap.lookup(line: lastLine)
      else { return range }

      // Get the full range of all affected lines
      let linesRange = NSRange(location: firstLineInfo.range.location,
                               length: lastLineInfo.range.location + lastLineInfo.range.length - firstLineInfo.range.location)

      guard let stringRange = Range<String.Index>(linesRange, in: codeStorage.string) else { return range }

      let selectedText = String(codeStorage.string[stringRange])
      let reindentedText = language.reindent(selectedText,
                                             indentWidth: indentation.indentWidth,
                                             useTabs: indentation.preference == .preferTabs,
                                             tabWidth: indentation.tabWidth)

      codeStorage.replaceCharacters(in: linesRange, with: reindentedText)

      // Adjust the selection to account for length change
      let lengthDiff = reindentedText.utf16.count - linesRange.length
      return NSRange(location: range.location, length: max(0, range.length + lengthDiff))

    }
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
      guard index > 0 else { return false }
      if let token = codeStorage.tokenOnly(at: index - 1),
         token.token == .curlyBracketOpen,
         token.range.upperBound == index
      {
        return true
      }
      return false
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
      guard index < codeStorage.length else { return false }
      if let token = codeStorage.tokenOnly(at: index),
         token.token == .curlyBracketClose,
         token.range.lowerBound == index
      {
        return true
      }
      return false
    }

    /// Check if the document has unmatched opening braces by scanning the entire text.
    /// If there are more `{` than `}`, the document is unbalanced and we should add a `}`.
    ///
    func documentHasUnmatchedOpenBrace() -> Bool {
      var depth = 0
      for char in codeStorage.string {
        if char == "{" {
          depth += 1
        } else if char == "}" {
          depth -= 1
        }
      }
      return depth > 0
    }

    textContentStorage.performEditingTransaction {
      processSelectedRanges { range in

        let desiredIndent = if indentation.indentOnReturn { predictedIndentation(after: range.location) } else { 0 },
            indentString  = indentation.indentation(for: desiredIndent)

        // Check if we're pressing enter right after a `{` and auto-brace is enabled
        if autoBrace.completeOnEnter && isAfterOpeningCurlyBrace(at: range.location) {
          // Use the current line's indentation as base, then add one indent level for the cursor
          let baseIndent        = baseIndentation(at: range.location)
          let innerIndent       = baseIndent + indentation.indentWidth
          let baseIndentString  = indentation.indentation(for: baseIndent)
          let innerIndentString = indentation.indentation(for: innerIndent)

          // Check if there's already a closing brace right after the cursor (from auto-completion)
          if hasClosingCurlyBraceAfter(at: range.location) {
            // There's already a `}` right after cursor — just insert newlines before it
            // The `}` will naturally be pushed down and we add base indentation before it
            let insertText = "\n" + innerIndentString + "\n" + baseIndentString
            codeStorage.replaceCharacters(in: range, with: insertText)
            return NSRange(location: range.location + 1 + innerIndentString.count, length: 0)
          } else if documentHasUnmatchedOpenBrace() {
            // Document has more `{` than `}` — add a closing brace
            let closingBrace = language.lexeme(of: .curlyBracketClose) ?? "}"
            let insertText   = "\n" + innerIndentString + "\n" + baseIndentString + closingBrace
            codeStorage.replaceCharacters(in: range, with: insertText)
            return NSRange(location: range.location + 1 + innerIndentString.count, length: 0)
          } else {
            // Document braces are balanced — just insert newline with indentation
            codeStorage.replaceCharacters(in: range, with: "\n" + innerIndentString)
            return NSRange(location: range.location + 1 + innerIndentString.count, length: 0)
          }
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
    if !newSelected.isEmpty { selectedRanges = newSelected.map{ NSValue(range: $0) } }
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
