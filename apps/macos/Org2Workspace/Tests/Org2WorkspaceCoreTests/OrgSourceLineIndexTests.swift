import Foundation
import XCTest
@testable import Org2WorkspaceCore

final class OrgSourceLineIndexTests: XCTestCase {
  func testLineIndexTracksUTF16OffsetsAcrossEdits() {
    let text = NSMutableString(string: "first\nemoji 😀 line\nlast")
    let index = OrgSourceLineIndex(text: text)

    assertIndex(index, matches: text)

    apply(
      NSRange(location: 0, length: 0),
      replacement: "intro\n",
      to: text,
      index: index
    )
    apply(
      text.range(of: "😀 "),
      replacement: "two\nnew ",
      to: text,
      index: index
    )
    apply(
      text.range(of: "line\n"),
      replacement: "",
      to: text,
      index: index
    )
  }

  func testRanksAtEveryUTF16BoundarySurviveEditsAndResets() {
    let index = OrgSourceLineIndex()
    for source in ["α\n\n😀\nend\n", "", "one\n", "no newline"] {
      let text = NSMutableString(string: source)
      index.reset(with: text)
      for offset in -2...(text.length + 2) {
        XCTAssertEqual(index.lineNumber(atUTF16Offset: offset), naiveLineNumber(in: text, offset: offset))
      }
      apply(NSRange(location: 0, length: 0), replacement: "prefix\n😀\n", to: text, index: index)
      for offset in -2...(text.length + 2) {
        XCTAssertEqual(index.lineNumber(atUTF16Offset: offset), naiveLineNumber(in: text, offset: offset))
      }
    }
  }

  func testLineIndexMatchesNaiveLookupDuringManyEdits() {
    let text = NSMutableString(string: String(repeating: "one two three\n", count: 2_000))
    let index = OrgSourceLineIndex(text: text)
    var state: UInt64 = 0x123456789abcdef
    let replacements = ["x", "", "new\nline", "\n", "plain"]

    for edit in 0..<600 {
      state = state &* 6364136223846793005 &+ 1442695040888963407
      let location = Int(state % UInt64(text.length + 1))
      state = state &* 6364136223846793005 &+ 1442695040888963407
      let maximumLength = min(12, text.length - location)
      let length = maximumLength == 0 ? 0 : Int(state % UInt64(maximumLength + 1))
      let replacement = replacements[edit % replacements.count]
      apply(
        NSRange(location: location, length: length),
        replacement: replacement,
        to: text,
        index: index
      )
    }
  }

  private func apply(
    _ range: NSRange,
    replacement: String,
    to text: NSMutableString,
    index: OrgSourceLineIndex,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    index.replaceCharacters(in: range, with: replacement)
    text.replaceCharacters(in: range, with: replacement)
    assertIndex(index, matches: text, file: file, line: line)
  }

  private func assertIndex(
    _ index: OrgSourceLineIndex,
    matches text: NSString,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    XCTAssertEqual(index.documentUTF16Length, text.length, file: file, line: line)
    let expectedLineCount = 1 + (0..<text.length).reduce(into: 0) { count, offset in
      if text.character(at: offset) == 10 { count += 1 }
    }
    XCTAssertEqual(index.lineCount, expectedLineCount, file: file, line: line)

    let sampleOffsets = Set([
      0,
      min(1, text.length),
      text.length / 3,
      text.length / 2,
      max(0, text.length - 1),
      text.length
    ])
    for offset in sampleOffsets {
      XCTAssertEqual(
        index.lineNumber(atUTF16Offset: offset),
        naiveLineNumber(in: text, offset: offset),
        "offset \(offset)",
        file: file,
        line: line
      )
    }

    let sampleLines = Set([1, max(1, expectedLineCount / 2), expectedLineCount])
    for requestedLine in sampleLines {
      XCTAssertEqual(
        index.lineRange(forLine: requestedLine),
        naiveLineRange(in: text, line: requestedLine),
        "line \(requestedLine)",
        file: file,
        line: line
      )
    }
  }

  private func naiveLineNumber(in text: NSString, offset: Int) -> Int {
    let end = min(max(0, offset), text.length)
    var line = 1
    for location in 0..<end where text.character(at: location) == 10 {
      line += 1
    }
    return line
  }

  private func naiveLineRange(in text: NSString, line requestedLine: Int) -> NSRange {
    let target = max(1, requestedLine)
    var currentLine = 1
    var location = 0
    while currentLine < target, location < text.length {
      if text.character(at: location) == 10 { currentLine += 1 }
      location += 1
    }
    return text.lineRange(for: NSRange(location: min(location, text.length), length: 0))
  }
}
