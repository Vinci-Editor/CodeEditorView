//
//  MinimapBitmapCache.swift
//
//
//  Performance optimization: renders minimap to a bitmap for fast display during resize.
//

import SwiftUI

#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Cache for pre-rendered minimap bitmap.
/// Renders the minimap content to a CGImage for fast display, avoiding expensive TextKit 2 layout during resize.
///
@MainActor
final class MinimapBitmapCache {

  /// The cached bitmap image.
  private(set) var cachedImage: CGImage?

  /// Size of the cached bitmap.
  private(set) var cachedSize: CGSize = .zero

  /// Hash of document content when bitmap was generated.
  private var contentHash: Int = 0

  /// Theme ID when bitmap was generated.
  private var themeId: String = ""

  /// Container width when bitmap was generated.
  private var containerWidth: CGFloat = 0

  /// Work item for debounced regeneration.
  private var regenerationWorkItem: DispatchWorkItem?

  /// Debounce interval for regeneration (100ms).
  private let regenerationDebounce: TimeInterval = 0.1

  /// Whether a regeneration is pending.
  private(set) var isRegenerationPending: Bool = false

  /// Invalidate the cache and schedule regeneration.
  /// - Parameters:
  ///   - contentHash: Hash of the current document content.
  ///   - themeId: Current theme identifier.
  ///   - containerWidth: Current container width.
  ///   - regenerate: Closure to call for regeneration.
  func invalidateIfNeeded(
    contentHash: Int,
    themeId: String,
    containerWidth: CGFloat,
    regenerate: @escaping () -> Void
  ) {
    // Check if regeneration is needed
    let needsRegeneration = self.contentHash != contentHash
                         || self.themeId != themeId
                         || self.containerWidth != containerWidth

    guard needsRegeneration else { return }

    // Update tracked values
    self.contentHash = contentHash
    self.themeId = themeId
    self.containerWidth = containerWidth

    // Debounce regeneration
    regenerationWorkItem?.cancel()
    isRegenerationPending = true

    let workItem = DispatchWorkItem { [weak self] in
      self?.isRegenerationPending = false
      regenerate()
    }
    regenerationWorkItem = workItem
    DispatchQueue.main.asyncAfter(deadline: .now() + regenerationDebounce, execute: workItem)
  }

  /// Update the cached bitmap.
  /// - Parameters:
  ///   - image: The new bitmap image.
  ///   - size: Size of the bitmap.
  func updateCache(image: CGImage?, size: CGSize) {
    cachedImage = image
    cachedSize = size
  }

  /// Force immediate regeneration (skip debounce).
  func forceRegeneration(regenerate: @escaping () -> Void) {
    regenerationWorkItem?.cancel()
    isRegenerationPending = false
    regenerate()
  }

  /// Clear the cache.
  func clear() {
    cachedImage = nil
    cachedSize = .zero
    contentHash = 0
    themeId = ""
    containerWidth = 0
    regenerationWorkItem?.cancel()
    isRegenerationPending = false
  }
}

// MARK: - Bitmap Rendering

extension MinimapBitmapCache {

  /// Render the minimap content to a bitmap.
  /// - Parameters:
  ///   - textLayoutManager: The layout manager with minimap content.
  ///   - textContentStorage: The content storage.
  ///   - theme: Current theme for colors.
  ///   - size: Size of the bitmap to render.
  ///   - scale: Scale factor for retina displays.
  /// - Returns: The rendered bitmap, or nil if rendering failed.
  static func renderBitmap(
    textLayoutManager: NSTextLayoutManager,
    textContentStorage: NSTextContentStorage,
    theme: Theme,
    size: CGSize,
    scale: CGFloat
  ) -> CGImage? {
    guard size.width > 0 && size.height > 0 else { return nil }

    // Create bitmap context
    let width = Int(size.width * scale)
    let height = Int(size.height * scale)
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue

    guard let context = CGContext(
      data: nil,
      width: width,
      height: height,
      bitsPerComponent: 8,
      bytesPerRow: 0,
      space: colorSpace,
      bitmapInfo: bitmapInfo
    ) else { return nil }

    // Scale for retina
    context.scaleBy(x: scale, y: scale)

    // Flip coordinate system for text rendering
    context.translateBy(x: 0, y: size.height)
    context.scaleBy(x: 1, y: -1)

    // Fill background
    context.setFillColor(theme.backgroundColour.cgColor)
    context.fill(CGRect(origin: .zero, size: size))

    // Enumerate and draw layout fragments
    let documentRange = textLayoutManager.documentRange
    textLayoutManager.enumerateTextLayoutFragments(
      from: documentRange.location,
      options: [.ensuresLayout, .ensuresExtraLineFragment]
    ) { fragment in
      // Draw each text line fragment
      for lineFragment in fragment.textLineFragments {
        lineFragment.draw(at: fragment.layoutFragmentFrame.origin, in: context)
      }
      return true
    }

    return context.makeImage()
  }
}
