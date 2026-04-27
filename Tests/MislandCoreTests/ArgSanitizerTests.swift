import XCTest
@testable import MislandCore

final class ArgSanitizerTests: XCTestCase {
    func testPlainTextUntouched() {
        XCTAssertEqual(ArgSanitizer.sanitize("ls -la /tmp"), "ls -la /tmp")
    }

    func testStripsCSI() {
        let red = "\u{1B}[31mERROR\u{1B}[0m"
        XCTAssertEqual(ArgSanitizer.sanitize(red), "ERROR")
    }

    func testStripsCursorMovement() {
        // ESC[2J = clear screen, ESC[H = home cursor — common in malicious input.
        let evil = "before\u{1B}[2J\u{1B}[Hafter"
        XCTAssertEqual(ArgSanitizer.sanitize(evil), "beforeafter")
    }

    func testStripsOSC() {
        // OSC sequence: set window title.
        let osc = "hi\u{1B}]0;EvilTitle\u{07}there"
        XCTAssertEqual(ArgSanitizer.sanitize(osc), "hithere")
    }

    func testStripsControlCharsExceptNewlineTab() {
        let s = "a\u{01}\u{08}b\nc\td\u{7F}e"
        XCTAssertEqual(ArgSanitizer.sanitize(s), "ab\nc\tde")
    }

    func testStripsC1Controls() {
        // C1 controls (0x80-0x9F) are dangerous in some terminals.
        let s = "ok\u{0085}danger"
        XCTAssertEqual(ArgSanitizer.sanitize(s), "okdanger")
    }

    func testTruncationAtMaxBytes() {
        let s = String(repeating: "a", count: 5_000)
        let out = ArgSanitizer.sanitize(s, maxBytes: 100)
        XCTAssertLessThanOrEqual(out.utf8.count, 100)
        XCTAssertTrue(out.hasSuffix(ArgSanitizer.truncationMarker),
                      "should end with truncation marker, got: \(out)")
    }

    func testTruncationMarkerShownWhenCutoffNeeded() {
        let s = String(repeating: "a", count: 200)
        let out = ArgSanitizer.sanitize(s, maxBytes: 100)
        XCTAssertTrue(out.contains(ArgSanitizer.truncationMarker),
                      "should mention truncation: \(out)")
    }

    func testNoTruncationWhenWithinBudget() {
        let s = "hello"
        let out = ArgSanitizer.sanitize(s, maxBytes: 100)
        XCTAssertEqual(out, "hello")
    }

    func testUTF8MultibyteCharsHandled() {
        let s = "你好世界" + String(repeating: "x", count: 200)
        let out = ArgSanitizer.sanitize(s, maxBytes: 50)
        XCTAssertLessThanOrEqual(out.utf8.count, 50)
        // Must not corrupt UTF-8 (i.e. valid string).
        XCTAssertEqual(out.utf8.count, Array(out.utf8).count)
    }

    func testHtmlEscape() {
        XCTAssertEqual(ArgSanitizer.htmlEscape("<a href=\"x\">'&'</a>"),
                       "&lt;a href=&quot;x&quot;&gt;&#39;&amp;&#39;&lt;/a&gt;")
    }

    func testStripAnsiPreservesBrackets() {
        // Square brackets that aren't part of a CSI sequence must survive.
        XCTAssertEqual(ArgSanitizer.sanitize("array[0]"), "array[0]")
    }

    func testCombinedAttack() {
        let evil = "ls\u{1B}[2J -la \u{07}\u{01}/tmp\u{1B}[0m"
        XCTAssertEqual(ArgSanitizer.sanitize(evil), "ls -la /tmp")
    }
}
