//
//  LayoutMetrics.swift
//  CodeEditorView
//
//  Shared pixel-aligned editor geometry calculations.
//

import Foundation

struct LayoutMetrics: Equatable, Sendable {

  struct Input: Equatable, Sendable {
    var visibleRect: CGRect
    var fontWidth: CGFloat
    var lineHeight: CGFloat
    var wrapText: Bool
    var showMinimap: Bool
    var gutterColumns: CGFloat
    var linePadding: CGFloat
    var dividerWidth: CGFloat
    var minimapRatio: CGFloat
    var contentInsets: EdgeInsets

    init(visibleRect: CGRect,
         fontWidth: CGFloat,
         lineHeight: CGFloat,
         wrapText: Bool,
         showMinimap: Bool,
         gutterColumns: CGFloat = 7,
         linePadding: CGFloat = 5,
         dividerWidth: CGFloat = 1,
         minimapRatio: CGFloat,
         contentInsets: EdgeInsets = .zero)
    {
      self.visibleRect = visibleRect
      self.fontWidth = fontWidth
      self.lineHeight = lineHeight
      self.wrapText = wrapText
      self.showMinimap = showMinimap
      self.gutterColumns = gutterColumns
      self.linePadding = linePadding
      self.dividerWidth = dividerWidth
      self.minimapRatio = minimapRatio
      self.contentInsets = contentInsets
    }
  }

  struct EdgeInsets: Equatable, Sendable {
    var top: CGFloat
    var left: CGFloat
    var bottom: CGFloat
    var right: CGFloat

    static let zero = EdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
  }

  var gutterFrame: CGRect
  var textContainerWidth: CGFloat
  var minimapWidth: CGFloat
  var minimapGutterFrame: CGRect
  var dividerFrame: CGRect
  var codeColumns: Int

  static func calculate(_ input: Input, documentHeight: CGFloat) -> LayoutMetrics {
    let visibleWidth = max(0, input.visibleRect.width - input.contentInsets.left - input.contentInsets.right)
    let visibleHeight = max(0, input.visibleRect.height - input.contentInsets.top - input.contentInsets.bottom)
    let height = ceil(max(documentHeight, visibleHeight))

    let gutterWidth = ceil(input.fontWidth * input.gutterColumns)
    let minimapFontWidth = input.fontWidth / input.minimapRatio
    let minimapGutterWidth = input.showMinimap ? ceil(minimapFontWidth * input.gutterColumns) : 0
    let minimapExtras = input.showMinimap ? minimapGutterWidth + input.dividerWidth : 0
    let gutterWithPadding = gutterWidth + input.linePadding
    let compositeFontWidth = input.showMinimap ? input.fontWidth + minimapFontWidth : input.fontWidth
    let availableWidth = max(0, visibleWidth - gutterWithPadding - minimapExtras)
    let columns = max(0, Int(floor(availableWidth / max(1, compositeFontWidth))))
    let codeAreaWidth = CGFloat(columns) * input.fontWidth
    let codeViewWidth = input.showMinimap ? gutterWithPadding + codeAreaWidth : visibleWidth
    let minimapWidth = input.showMinimap ? max(0, visibleWidth - codeViewWidth) : 0
    let minimapX = floor(input.contentInsets.left + visibleWidth - minimapWidth)

    return LayoutMetrics(
      gutterFrame: CGRect(x: input.contentInsets.left, y: 0, width: gutterWidth, height: height).integral,
      textContainerWidth: input.wrapText ? input.linePadding + codeAreaWidth : .greatestFiniteMagnitude,
      minimapWidth: minimapWidth,
      minimapGutterFrame: CGRect(x: 0, y: 0, width: minimapGutterWidth, height: height).integral,
      dividerFrame: CGRect(x: minimapX - input.dividerWidth, y: 0, width: input.dividerWidth, height: height).integral,
      codeColumns: columns
    )
  }
}
