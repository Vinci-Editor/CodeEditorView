import XCTest
@testable import CodeEditorView

final class DocumentVersioningTests: XCTestCase {

  func testDocumentVersionOrdering() {
    let initial = DocumentVersion.initial
    let next = initial.advanced()

    XCTAssertLessThan(initial, next)
    XCTAssertEqual(next.rawValue, initial.rawValue + 1)
  }

  func testCheckedStringRangeUsesUTF16Offsets() {
    let text = "a😀e\u{301}"
    let emojiRange = NSRange(location: 1, length: 2)
    let combiningRange = NSRange(location: 3, length: 2)

    XCTAssertEqual(String(text[emojiRange.checkedStringRange(in: text)!]), "😀")
    XCTAssertEqual(String(text[combiningRange.checkedStringRange(in: text)!]), "e\u{301}")
    XCTAssertNil(NSRange(location: 2, length: 1).checkedStringRange(in: text))
  }
}
