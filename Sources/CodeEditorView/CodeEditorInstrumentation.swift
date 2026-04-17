//
//  CodeEditorInstrumentation.swift
//  CodeEditorView
//
//  Internal counters and signposts for editor responsiveness work.
//

import Foundation
import os

enum CodeEditorInstrumentation {

  enum Counter: String, CaseIterable {
    case typing
    case scroll
    case layout
    case tokenization
    case renderingValidation
    case diagnostics
    case completion
    case lifecycle
    case fileLoadSave
    case themeApplied
    case tile
    case layoutViewport
    case setFrameSize
    case contentSizeWrite
    case renderingAttributesValidated
    case syncTokenizedLines
    case backgroundTokenBatch
    case setTextScheduled
    case setTextFlushed
    case completionTaskCancelled
    case staleAsyncResultDropped
  }

  private static let log = OSLog(subsystem: "org.justtesting.CodeEditorView", category: .pointsOfInterest)
  private static let counterLock = NSLock()
  nonisolated(unsafe) private static var counters: [Counter: Int] = [:]

  static var isEnabled: Bool {
    #if DEBUG
    ProcessInfo.processInfo.environment["CODE_EDITOR_METRICS"] == "1"
    #else
    false
    #endif
  }

  static func record(_ counter: Counter) {
    #if DEBUG
    counterLock.withLock {
      counters[counter, default: 0] += 1
    }

    guard isEnabled else { return }
    signpost(counter)
    #endif
  }

  static func dumpCounters() -> String {
    #if DEBUG
    return counterLock.withLock {
      Counter.allCases
        .map { "\($0.rawValue)=\(counters[$0, default: 0])" }
        .joined(separator: " ")
    }
    #else
    return ""
    #endif
  }

  private static func signpost(_ counter: Counter) {
    #if DEBUG
    switch counter {
    case .typing: os_signpost(.event, log: log, name: "typing")
    case .scroll: os_signpost(.event, log: log, name: "scroll")
    case .layout: os_signpost(.event, log: log, name: "layout")
    case .tokenization: os_signpost(.event, log: log, name: "tokenization")
    case .renderingValidation: os_signpost(.event, log: log, name: "renderingValidation")
    case .diagnostics: os_signpost(.event, log: log, name: "diagnostics")
    case .completion: os_signpost(.event, log: log, name: "completion")
    case .lifecycle: os_signpost(.event, log: log, name: "lifecycle")
    case .fileLoadSave: os_signpost(.event, log: log, name: "fileLoadSave")
    case .themeApplied: os_signpost(.event, log: log, name: "themeApplied")
    case .tile: os_signpost(.event, log: log, name: "tile")
    case .layoutViewport: os_signpost(.event, log: log, name: "layoutViewport")
    case .setFrameSize: os_signpost(.event, log: log, name: "setFrameSize")
    case .contentSizeWrite: os_signpost(.event, log: log, name: "contentSizeWrite")
    case .renderingAttributesValidated: os_signpost(.event, log: log, name: "renderingAttributesValidated")
    case .syncTokenizedLines: os_signpost(.event, log: log, name: "syncTokenizedLines")
    case .backgroundTokenBatch: os_signpost(.event, log: log, name: "backgroundTokenBatch")
    case .setTextScheduled: os_signpost(.event, log: log, name: "setTextScheduled")
    case .setTextFlushed: os_signpost(.event, log: log, name: "setTextFlushed")
    case .completionTaskCancelled: os_signpost(.event, log: log, name: "completionTaskCancelled")
    case .staleAsyncResultDropped: os_signpost(.event, log: log, name: "staleAsyncResultDropped")
    }
    #endif
  }
}
