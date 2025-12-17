//
//  ScrollView.swift
//  
//
//  Created by Manuel M T Chakravarty on 27/11/2021.
//

import SwiftUI


#if os(iOS) || os(visionOS)

// MARK: -
// MARK: UIKit version

extension UIScrollView {

  var verticalScrollPosition: CGFloat {
    get { contentOffset.y }
    set {
      let maxOffset = max(0, contentSize.height - bounds.height)
      let newOffset = max(0, min(newValue, maxOffset))
      if abs(newOffset - contentOffset.y) > 0.0001 {
        setContentOffset(CGPoint(x: contentOffset.x, y: newOffset), animated: false)
      }
    }
  }
}


#elseif os(macOS)

// MARK: -
// MARK: AppKit version

extension NSScrollView {

  @MainActor
  var verticalScrollPosition: CGFloat {
    get { documentVisibleRect.origin.y }
    set {

      // NOTE: Removed layoutViewport() call - it was forcing TextKit 2 to only layout the viewport,
      // discarding full-document layout state. This caused content to "load in" as user scrolled.
      // TextKit 2 handles viewport layout automatically via its textViewportLayoutController.

      let newOffset = max(0, min(newValue, (documentView?.bounds.height ?? 0) - contentSize.height))
      if abs(newOffset - documentVisibleRect.origin.y) > 0.0001 {
        contentView.scroll(to: CGPoint(x: documentVisibleRect.origin.x, y: newOffset))
      }

      // This is necessary as the floating subviews are otherwise *sometimes* not correctly re-positioned.
      reflectScrolledClipView(contentView)

    }
  }
}

#endif
