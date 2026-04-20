//
//  Theme.swift
//  
//
//  Created by Manuel M T Chakravarty on 14/05/2021.
//
//  This module defines code highlight themes.

import SwiftUI


/// A code highlighting theme. Different syntactic elements are purely distinguished by colour.
///
/// NB: Themes are `Identifiable`. To ensure that a theme's identity changes when any of its properties is being changed
///     the `id` is updated on setting any property. This makes mutating properties fairly expensive, but it should also
///     not be a particularily frequent operation.
///
public struct Theme: Identifiable {
  public private(set) var id = UUID()

  /// The colour scheme of the theme.
  ///
  public var colourScheme: ColorScheme {
    didSet { id = UUID() }
  }

  /// The name of the font to use.
  ///
  public var fontName: String {
    didSet { id = UUID() }
  }

  /// The point size of the font to use.
  ///
  public var fontSize: CGFloat {
    didSet { id = UUID() }
  }

  /// The default foreground text colour.
  ///
  public var textColour: OSColor {
    didSet { id = UUID() }
  }

  /// The colour for (all kinds of) comments.
  ///
  public var commentColour: OSColor {
    didSet { id = UUID() }
  }

  /// The colour for string literals.
  ///
  public var stringColour: OSColor {
    didSet { id = UUID() }
  }

  /// The colour for character literals.
  ///
  public var characterColour: OSColor {
    didSet { id = UUID() }
  }

  /// The colour for number literals.
  ///
  public var numberColour: OSColor {
    didSet { id = UUID() }
  }

  /// The colour for identifiers.
  ///
  public var identifierColour: OSColor {
    didSet { id = UUID() }
  }

  /// The colour for operators.
  ///
  public var operatorColour: OSColor {
    didSet { id = UUID() }
  }

  /// The colour for keywords.
  ///
  public var keywordColour: OSColor {
    didSet { id = UUID() }
  }

  /// The colour for reserved symbols.
  ///
  public var symbolColour: OSColor {
    didSet { id = UUID() }
  }

  /// The colour for type names (identifiers and operators).
  ///
  public var typeColour: OSColor {
    didSet { id = UUID() }
  }

  /// The colour for field names.
  ///
  public var fieldColour: OSColor {
    didSet { id = UUID() }
  }

  /// The colour for names of alternatives.
  ///
  public var caseColour: OSColor {
    didSet { id = UUID() }
  }

  /// The colour for function and method names.
  ///
  public var functionColour: OSColor {
    didSet { id = UUID() }
  }

  /// The colour for parameter names.
  ///
  public var parameterColour: OSColor {
    didSet { id = UUID() }
  }

  /// The colour for macro names.
  ///
  public var macroColour: OSColor {
    didSet { id = UUID() }
  }

  /// The background colour.
  ///
  public var backgroundColour: OSColor {
    didSet { id = UUID() }
  }

  /// The colour of the current line highlight.
  ///
  public var currentLineColour: OSColor {
    didSet { id = UUID() }
  }

  /// The colour to use for the selection highlight.
  ///
  public var selectionColour: OSColor {
    didSet { id = UUID() }
  }

  /// The cursor colour.
  ///
  public var cursorColour: OSColor {
    didSet { id = UUID() }
  }

  /// The colour to use if invisibles are drawn.
  ///
  public var invisiblesColour: OSColor {
    didSet { id = UUID() }
  }

  public init(colourScheme: ColorScheme,
              fontName: String,
              fontSize: CGFloat,
              textColour: OSColor,
              commentColour: OSColor,
              stringColour: OSColor,
              characterColour: OSColor,
              numberColour: OSColor,
              identifierColour: OSColor,
              operatorColour: OSColor,
              keywordColour: OSColor,
              symbolColour: OSColor,
              typeColour: OSColor,
              fieldColour: OSColor,
              caseColour: OSColor,
              functionColour: OSColor,
              parameterColour: OSColor,
              macroColour: OSColor,
              backgroundColour: OSColor,
              currentLineColour: OSColor,
              selectionColour: OSColor,
              cursorColour: OSColor,
              invisiblesColour: OSColor)
  {
    self.colourScheme = colourScheme
    self.fontName = fontName
    self.fontSize = fontSize
    self.textColour = textColour
    self.commentColour = commentColour
    self.stringColour = stringColour
    self.characterColour = characterColour
    self.numberColour = numberColour
    self.identifierColour = identifierColour
    self.operatorColour = operatorColour
    self.keywordColour = keywordColour
    self.symbolColour = symbolColour
    self.typeColour = typeColour
    self.fieldColour = fieldColour
    self.caseColour = caseColour
    self.functionColour = functionColour
    self.parameterColour = parameterColour
    self.macroColour = macroColour
    self.backgroundColour = backgroundColour
    self.currentLineColour = currentLineColour
    self.selectionColour = selectionColour
    self.cursorColour = cursorColour
    self.invisiblesColour = invisiblesColour
  }
}

extension Theme: Equatable {

  public static func ==(lhs: Theme, rhs: Theme) -> Bool { lhs.id == rhs.id }
}

extension Theme {

  /// Compare the logical visual contents of a theme instead of its mutation identity.
  ///
  /// SwiftUI callers often rebuild equivalent `Theme` values during normal view updates. The public `Equatable`
  /// conformance intentionally remains identity-based, but editor view updates need value semantics so identical
  /// themes don't repeatedly invalidate TextKit layout and rendering.
  func isVisuallyEquivalent(to other: Theme) -> Bool {
    colourScheme == other.colourScheme
      && fontName == other.fontName
      && fontSize == other.fontSize
      && textColour.isEqual(other.textColour)
      && commentColour.isEqual(other.commentColour)
      && stringColour.isEqual(other.stringColour)
      && characterColour.isEqual(other.characterColour)
      && numberColour.isEqual(other.numberColour)
      && identifierColour.isEqual(other.identifierColour)
      && operatorColour.isEqual(other.operatorColour)
      && keywordColour.isEqual(other.keywordColour)
      && symbolColour.isEqual(other.symbolColour)
      && typeColour.isEqual(other.typeColour)
      && fieldColour.isEqual(other.fieldColour)
      && caseColour.isEqual(other.caseColour)
      && functionColour.isEqual(other.functionColour)
      && parameterColour.isEqual(other.parameterColour)
      && macroColour.isEqual(other.macroColour)
      && backgroundColour.isEqual(other.backgroundColour)
      && currentLineColour.isEqual(other.currentLineColour)
      && selectionColour.isEqual(other.selectionColour)
      && cursorColour.isEqual(other.cursorColour)
      && invisiblesColour.isEqual(other.invisiblesColour)
  }
}

/// A theme catalog indexing themes by name
///
typealias Themes = [String: Theme]

extension Theme {

  nonisolated(unsafe) public static let defaultDark: Theme
    = Theme(colourScheme: .dark,
            fontName: "SFMono-Medium",
            fontSize: 13.0,
            textColour: OSColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 0.85),
            commentColour: OSColor(red: 0.423943, green: 0.474618, blue: 0.525183, alpha: 1.0),
            stringColour: OSColor(red: 0.989117, green: 0.41558, blue: 0.365684, alpha: 1.0),
            characterColour: OSColor(red: 0.815686, green: 0.74902, blue: 0.411765, alpha: 1.0),
            numberColour: OSColor(red: 0.814983, green: 0.749393, blue: 0.412334, alpha: 1.0),
            identifierColour: OSColor(red: 0.405383, green: 0.717051, blue: 0.642088, alpha: 1.0),
            operatorColour: OSColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 0.85),
            keywordColour: OSColor(red: 0.988394, green: 0.37355, blue: 0.638329, alpha: 1.0),
            symbolColour: OSColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 0.85),
            typeColour: OSColor(red: 0.621449, green: 0.943864, blue: 0.868194, alpha: 1.0),
            fieldColour: OSColor(red: 0.405383, green: 0.717051, blue: 0.642088, alpha: 1.0),
            caseColour: OSColor(red: 0.405383, green: 0.717051, blue: 0.642088, alpha: 1.0),
            functionColour: OSColor(red: 0.403922, green: 0.717647, blue: 0.643137, alpha: 1.0),
            parameterColour: OSColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 0.85),
            macroColour: OSColor(red: 0.991311, green: 0.560764, blue: 0.246107, alpha: 1.0),
            backgroundColour: OSColor(red: 0.120543, green: 0.122844, blue: 0.141312, alpha: 1.0),
            currentLineColour: OSColor(red: 0.138526, green: 0.146864, blue: 0.169283, alpha: 1.0),
            selectionColour: OSColor(red: 0.317647, green: 0.356862, blue: 0.439215, alpha: 1.0),
            cursorColour: OSColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 1.0),
            invisiblesColour: OSColor(red: 0.258298, green: 0.300954, blue: 0.355207, alpha: 1.0))

  nonisolated(unsafe) public static let defaultLight: Theme
    = Theme(colourScheme: .light,
            fontName: "SFMono-Medium",
            fontSize: 13.0,
            textColour: OSColor(red: 0.0, green: 0.0, blue: 0.0, alpha: 0.85),
            commentColour: OSColor(red: 0.36526, green: 0.421879, blue: 0.475154, alpha: 1.0),
            stringColour: OSColor(red: 0.77, green: 0.102, blue: 0.086, alpha: 1.0),
            characterColour: OSColor(red: 0.11, green: 0.0, blue: 0.81, alpha: 1.0),
            numberColour: OSColor(red: 0.11, green: 0.0, blue: 0.81, alpha: 1.0),
            identifierColour: OSColor(red: 0.194184, green: 0.429349, blue: 0.454553, alpha: 1.0),
            operatorColour: OSColor(red: 0.0, green: 0.0, blue: 0.0, alpha: 0.85),
            keywordColour: OSColor(red: 0.607592, green: 0.137526, blue: 0.576284, alpha: 1.0),
            symbolColour: OSColor(red: 0.0, green: 0.0, blue: 0.0, alpha: 0.85),
            typeColour: OSColor(red: 0.109812, green: 0.272761, blue: 0.288691, alpha: 1.0),
            fieldColour: OSColor(red: 0.194184, green: 0.429349, blue: 0.454553, alpha: 1.0),
            caseColour: OSColor(red: 0.194184, green: 0.429349, blue: 0.454553, alpha: 1.0),
            functionColour: OSColor(red: 0.194184, green: 0.429349, blue: 0.454553, alpha: 1.0),
            parameterColour: OSColor(red: 0.0, green: 0.0, blue: 0.0, alpha: 0.85),
            macroColour: OSColor(red: 0.391471, green: 0.220311, blue: 0.124457, alpha: 1.0),
            backgroundColour: OSColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 1.0),
            currentLineColour: OSColor(red: 0.909804, green: 0.94902, blue: 1.0, alpha: 1.0),
            selectionColour: OSColor(red: 0.642038, green: 0.802669, blue: 0.999195, alpha: 1.0),
            cursorColour: OSColor(red: 0.0, green: 0.0, blue: 0.0, alpha: 1.0),
            invisiblesColour: OSColor(red: 0.8, green: 0.8, blue: 0.8, alpha: 1.0))
}

extension Theme {

  /// Font object on the basis of the font name and size of the theme.
  ///
  var font: OSFont {
    if fontName.hasPrefix("SFMono-") {

      let weightString = fontName.dropFirst("SFMono-".count)
      let weight       : OSFont.Weight
      switch weightString {
      case "UltraLight": weight = .ultraLight
      case "Thin":       weight = .thin
      case "Light":      weight = .light
      case "Regular":    weight = .regular
      case "Medium":     weight = .medium
      case "Semibold":   weight = .semibold
      case "Bold":       weight = .bold
      case "Heavy":      weight = .heavy
      case "Black":      weight = .black
      default:           weight = .regular
      }
      return OSFont.monospacedSystemFont(ofSize: fontSize, weight: weight)

    } else {

      return OSFont(name: fontName, size: fontSize) ?? OSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)

    }
  }

  #if os(iOS) || os(visionOS)

  /// Tint colour on the basis of the cursor and selection colour of the theme.
  ///
  var tintColour: UIColor {
    var selectionHue        = CGFloat(0.0),
        selectionSaturation = CGFloat(0.0),
        selectionBrigthness = CGFloat(0.0),
        cursorHue           = CGFloat(0.0),
        cursorSaturation    = CGFloat(0.0),
        cursorBrigthness    = CGFloat(0.0)

    // TODO: This is awkward...
    selectionColour.getHue(&selectionHue,
                           saturation: &selectionSaturation,
                           brightness: &selectionBrigthness,
                           alpha: nil)
    cursorColour.getHue(&cursorHue, saturation: &cursorSaturation, brightness: &cursorBrigthness, alpha: nil)
    return UIColor(hue: selectionHue,
                   saturation: 1.0,
                   brightness: selectionBrigthness,
                   alpha: 1.0)
  }

  #endif
}
