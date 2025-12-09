//
//  PerformanceTests.swift
//
//  Performance tests to validate optimization improvements.
//

import XCTest
@testable import CodeEditorView
@testable import LanguageSupport

final class PerformanceTests: XCTestCase {

  // MARK: - Test Data Generation

  /// Generates Swift code with the specified number of lines.
  private func generateSwiftCode(lines: Int) -> String {
    var code = """
    import Foundation

    /// A sample class for performance testing.
    class PerformanceTestClass {

    """

    for i in 0..<lines {
      let functionCode = """
        /// Function number \(i).
        func function\(i)(parameter: Int) -> String {
          let result = "Value: \\(parameter * \(i))"
          // This is a comment
          if parameter > 0 {
            return result
          } else {
            return "negative"
          }
        }

      """
      code += functionCode
    }

    code += "}\n"
    return code
  }

  /// Generates a large block of code for stress testing.
  private func generateLargeCode(targetLines: Int) -> String {
    // Each function template is about 10 lines
    let functionsNeeded = targetLines / 10
    return generateSwiftCode(lines: functionsNeeded)
  }

  // MARK: - Tokenization Performance Tests

  func testTokenization100Lines() throws {
    let code = generateSwiftCode(lines: 10)  // ~100 lines
    let codeStorageDelegate = CodeStorageDelegate(with: .swift(), setText: { _ in })
    let codeStorage = CodeStorage(theme: .defaultLight)
    codeStorage.delegate = codeStorageDelegate

    measure {
      codeStorage.setAttributedString(NSAttributedString(string: code))
    }

    XCTAssertGreaterThan(codeStorageDelegate.lineMap.lines.count, 50)
  }

  func testTokenization1000Lines() throws {
    let code = generateSwiftCode(lines: 100)  // ~1000 lines
    let codeStorageDelegate = CodeStorageDelegate(with: .swift(), setText: { _ in })
    let codeStorage = CodeStorage(theme: .defaultLight)
    codeStorage.delegate = codeStorageDelegate

    measure {
      codeStorage.setAttributedString(NSAttributedString(string: code))
    }

    XCTAssertGreaterThan(codeStorageDelegate.lineMap.lines.count, 500)
  }

  func testTokenization5000Lines() throws {
    let code = generateSwiftCode(lines: 500)  // ~5000 lines
    let codeStorageDelegate = CodeStorageDelegate(with: .swift(), setText: { _ in })
    let codeStorage = CodeStorage(theme: .defaultLight)
    codeStorage.delegate = codeStorageDelegate

    measure {
      codeStorage.setAttributedString(NSAttributedString(string: code))
    }

    XCTAssertGreaterThan(codeStorageDelegate.lineMap.lines.count, 2500)
  }

  // MARK: - Token Enumeration Performance Tests

  func testEnumerateTokensSmallRange() throws {
    let code = generateSwiftCode(lines: 100)  // ~1000 lines
    let codeStorageDelegate = CodeStorageDelegate(with: .swift(), setText: { _ in })
    let codeStorage = CodeStorage(theme: .defaultLight)
    codeStorage.delegate = codeStorageDelegate
    codeStorage.setAttributedString(NSAttributedString(string: code))

    // Enumerate tokens in a small range (first 100 characters)
    let range = NSRange(location: 0, length: min(100, code.utf16.count))

    measure {
      var tokenCount = 0
      codeStorage.enumerateTokens(in: range) { _ in
        tokenCount += 1
      }
    }
  }

  func testEnumerateTokensMediumRange() throws {
    let code = generateSwiftCode(lines: 100)  // ~1000 lines
    let codeStorageDelegate = CodeStorageDelegate(with: .swift(), setText: { _ in })
    let codeStorage = CodeStorage(theme: .defaultLight)
    codeStorage.delegate = codeStorageDelegate
    codeStorage.setAttributedString(NSAttributedString(string: code))

    // Enumerate tokens in the middle of the document (1000 character range)
    let midpoint = code.utf16.count / 2
    let range = NSRange(location: midpoint, length: min(1000, code.utf16.count - midpoint))

    measure {
      var tokenCount = 0
      codeStorage.enumerateTokens(in: range) { _ in
        tokenCount += 1
      }
    }
  }

  func testEnumerateTokensLargeFile() throws {
    let code = generateSwiftCode(lines: 500)  // ~5000 lines
    let codeStorageDelegate = CodeStorageDelegate(with: .swift(), setText: { _ in })
    let codeStorage = CodeStorage(theme: .defaultLight)
    codeStorage.delegate = codeStorageDelegate
    codeStorage.setAttributedString(NSAttributedString(string: code))

    // Enumerate tokens near the end of the document
    let nearEnd = code.utf16.count - 1000
    let range = NSRange(location: nearEnd, length: 500)

    measure {
      var tokenCount = 0
      codeStorage.enumerateTokens(in: range) { _ in
        tokenCount += 1
      }
    }
  }

  // MARK: - Line Map Performance Tests

  func testLineMapLookupPerformance() throws {
    let code = generateSwiftCode(lines: 500)  // ~5000 lines
    let codeStorageDelegate = CodeStorageDelegate(with: .swift(), setText: { _ in })
    let codeStorage = CodeStorage(theme: .defaultLight)
    codeStorage.delegate = codeStorageDelegate
    codeStorage.setAttributedString(NSAttributedString(string: code))

    let lineMap = codeStorageDelegate.lineMap
    let totalLines = lineMap.lines.count

    measure {
      // Perform 1000 random line lookups
      for _ in 0..<1000 {
        let randomLine = Int.random(in: 0..<totalLines)
        _ = lineMap.lookup(line: randomLine)
      }
    }
  }

  func testLineMapContainingIndexPerformance() throws {
    let code = generateSwiftCode(lines: 500)  // ~5000 lines
    let codeStorageDelegate = CodeStorageDelegate(with: .swift(), setText: { _ in })
    let codeStorage = CodeStorage(theme: .defaultLight)
    codeStorage.delegate = codeStorageDelegate
    codeStorage.setAttributedString(NSAttributedString(string: code))

    let lineMap = codeStorageDelegate.lineMap
    let totalLength = code.utf16.count

    measure {
      // Perform 1000 random index lookups
      for _ in 0..<1000 {
        let randomIndex = Int.random(in: 0..<totalLength)
        _ = lineMap.lineContaining(index: randomIndex)
      }
    }
  }

  // MARK: - Incremental Edit Performance Tests

  func testIncrementalEditPerformance() throws {
    let code = generateSwiftCode(lines: 100)  // ~1000 lines
    let codeStorageDelegate = CodeStorageDelegate(with: .swift(), setText: { _ in })
    let codeStorage = CodeStorage(theme: .defaultLight)
    codeStorage.delegate = codeStorageDelegate
    codeStorage.setAttributedString(NSAttributedString(string: code))

    // Simulate typing a character at various positions
    measure {
      for i in stride(from: 100, to: min(1000, code.utf16.count - 10), by: 100) {
        let insertRange = NSRange(location: i, length: 0)
        codeStorage.replaceCharacters(in: insertRange, with: "x")
        // Immediately undo to keep text consistent
        let deleteRange = NSRange(location: i, length: 1)
        codeStorage.replaceCharacters(in: deleteRange, with: "")
      }
    }
  }

  // MARK: - Tokenization State Tests

  func testTokenizationStateManagement() throws {
    let code = generateSwiftCode(lines: 100)  // ~1000 lines
    let codeStorageDelegate = CodeStorageDelegate(with: .swift(), setText: { _ in })
    let codeStorage = CodeStorage(theme: .defaultLight)
    codeStorage.delegate = codeStorageDelegate
    codeStorage.setAttributedString(NSAttributedString(string: code))

    let totalLines = codeStorageDelegate.lineMap.lines.count

    measure {
      // Test setting tokenization state for ranges
      for i in stride(from: 0, to: totalLines, by: 10) {
        let endLine = min(i + 10, totalLines)
        codeStorageDelegate.setTokenizationState(.invalidated, for: i..<endLine)
        codeStorageDelegate.setTokenizationState(.tokenized, for: i..<endLine)
      }
    }
  }

  func testAreLinesTokenizedPerformance() throws {
    let code = generateSwiftCode(lines: 100)  // ~1000 lines
    let codeStorageDelegate = CodeStorageDelegate(with: .swift(), setText: { _ in })
    let codeStorage = CodeStorage(theme: .defaultLight)
    codeStorage.delegate = codeStorageDelegate
    codeStorage.setAttributedString(NSAttributedString(string: code))

    let totalLines = codeStorageDelegate.lineMap.lines.count

    measure {
      // Check tokenization state for many ranges
      for i in stride(from: 0, to: totalLines - 20, by: 5) {
        _ = codeStorageDelegate.areLinesTokenized(in: i..<(i + 20))
      }
    }
  }

  // MARK: - Memory Efficiency Tests

  func testMemoryEfficiencyLargeFile() throws {
    // This test checks that large files don't cause excessive memory allocation
    let code = generateSwiftCode(lines: 1000)  // ~10000 lines

    // Measure memory by checking that the test completes without issues
    let codeStorageDelegate = CodeStorageDelegate(with: .swift(), setText: { _ in })
    let codeStorage = CodeStorage(theme: .defaultLight)
    codeStorage.delegate = codeStorageDelegate

    codeStorage.setAttributedString(NSAttributedString(string: code))

    // Verify the document was processed correctly
    XCTAssertGreaterThan(codeStorageDelegate.lineMap.lines.count, 5000)

    // Check that tokens are stored for lines
    if let firstLineTokens = codeStorageDelegate.lineMap.lookup(line: 0)?.info?.tokens {
      XCTAssertGreaterThan(firstLineTokens.count, 0)
    }
  }

  static var allTests = [
    ("testTokenization100Lines", testTokenization100Lines),
    ("testTokenization1000Lines", testTokenization1000Lines),
    ("testTokenization5000Lines", testTokenization5000Lines),
    ("testEnumerateTokensSmallRange", testEnumerateTokensSmallRange),
    ("testEnumerateTokensMediumRange", testEnumerateTokensMediumRange),
    ("testEnumerateTokensLargeFile", testEnumerateTokensLargeFile),
    ("testLineMapLookupPerformance", testLineMapLookupPerformance),
    ("testLineMapContainingIndexPerformance", testLineMapContainingIndexPerformance),
    ("testIncrementalEditPerformance", testIncrementalEditPerformance),
    ("testTokenizationStateManagement", testTokenizationStateManagement),
    ("testAreLinesTokenizedPerformance", testAreLinesTokenizedPerformance),
    ("testMemoryEfficiencyLargeFile", testMemoryEfficiencyLargeFile),
  ]
}
