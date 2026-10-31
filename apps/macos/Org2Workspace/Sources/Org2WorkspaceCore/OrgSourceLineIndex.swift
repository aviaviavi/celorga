import Foundation

/// Incremental UTF-16 line lookup for the source editor.
///
/// NSTextView and NSRange use UTF-16 offsets. Counting newlines from the start
/// of a multi-megabyte buffer on every scroll or caret event makes interaction
/// cost grow with the caret position. This index stores newline offsets in an
/// order-statistic treap: line queries and ordinary edits are logarithmic in
/// the number of lines, while suffix offsets move through one lazy shift.
final class OrgSourceLineIndex: @unchecked Sendable {
  private final class Node {
    var position: Int
    let priority: UInt64
    var left: Node?
    var right: Node?
    var lazyShift = 0
    var count = 1

    init(position: Int, priority: UInt64) {
      self.position = position
      self.priority = priority
    }
  }

  private var root: Node?
  // Reset already scans these offsets to build the treap. Retain that compact
  // snapshot for read-only navigation; edits switch queries to the lazy tree.
  private var resetNewlineOffsets: [Int]?
  private var priorityState: UInt64 = 0x9e3779b97f4a7c15

  private(set) var documentUTF16Length = 0

  init(text: NSString = "") {
    reset(with: text)
  }

  var lineCount: Int {
    (root?.count ?? 0) + 1
  }

  func reset(with text: NSString) {
    root = nil
    priorityState = 0x9e3779b97f4a7c15
    documentUTF16Length = text.length
    var stack: [Node] = []
    let offsets = Self.newlineOffsets(in: text)
    resetNewlineOffsets = offsets
    for offset in offsets {
      let node = Node(position: offset, priority: nextPriority())
      var leftSubtree: Node?
      while let previous = stack.last, previous.priority < node.priority {
        leftSubtree = stack.removeLast()
      }
      node.left = leftSubtree
      stack.last?.right = node
      stack.append(node)
    }
    root = stack.first
    recomputeCounts(root)
  }

  /// Applies a replacement expressed in the pre-edit coordinate space.
  func replaceCharacters(in requestedRange: NSRange, with replacement: String) {
    resetNewlineOffsets = nil
    let range = Self.clampedRange(requestedRange, utf16Length: documentUTF16Length)
    let end = NSMaxRange(range)
    let replacementLength = (replacement as NSString).length
    let delta = replacementLength - range.length

    let (prefix, remainder) = split(root, before: range.location)
    let (_, suffix) = split(remainder, before: end)
    applyShift(suffix, delta: delta)

    var inserted: Node?
    var relativeOffset = 0
    for unit in replacement.utf16 {
      if unit == 10 {
        inserted = merge(
          inserted,
          Node(position: range.location + relativeOffset, priority: nextPriority())
        )
      }
      relativeOffset += 1
    }

    root = merge(merge(prefix, inserted), suffix)
    documentUTF16Length += delta
  }

  func lineNumber(atUTF16Offset requestedOffset: Int) -> Int {
    let offset = min(max(0, requestedOffset), documentUTF16Length)
    if let offsets = resetNewlineOffsets {
      var lower = 0
      var upper = offsets.count
      while lower < upper {
        let middle = lower + (upper - lower) / 2
        if offsets[middle] < offset {
          lower = middle + 1
        } else {
          upper = middle
        }
      }
      return lower + 1
    }
    return count(of: root, before: offset) + 1
  }

  func utf16Offset(forLine requestedLine: Int) -> Int {
    let line = min(max(1, requestedLine), lineCount)
    guard line > 1, let newlineOffset = position(ofElementAt: line - 2, in: root) else {
      return 0
    }
    return min(documentUTF16Length, newlineOffset + 1)
  }

  func lineRange(forLine requestedLine: Int) -> NSRange {
    let line = min(max(1, requestedLine), lineCount)
    let start = utf16Offset(forLine: line)
    let end = line < lineCount
      ? utf16Offset(forLine: line + 1)
      : documentUTF16Length
    return NSRange(location: start, length: max(0, end - start))
  }

  func newlineCount(in requestedRange: NSRange) -> Int {
    let range = Self.clampedRange(requestedRange, utf16Length: documentUTF16Length)
    return count(of: root, before: NSMaxRange(range))
      - count(of: root, before: range.location)
  }

  private func nextPriority() -> UInt64 {
    // SplitMix64 gives stable, well-distributed priorities without relying on
    // global randomness. Stable priorities keep performance tests repeatable.
    priorityState &+= 0x9e3779b97f4a7c15
    var value = priorityState
    value = (value ^ (value >> 30)) &* 0xbf58476d1ce4e5b9
    value = (value ^ (value >> 27)) &* 0x94d049bb133111eb
    return value ^ (value >> 31)
  }

  private func split(_ node: Node?, before position: Int) -> (Node?, Node?) {
    guard let node else { return (nil, nil) }
    push(node)
    if node.position < position {
      let (leftOfSplit, rightOfSplit) = split(node.right, before: position)
      node.right = leftOfSplit
      updateCount(node)
      return (node, rightOfSplit)
    }

    let (leftOfSplit, rightOfSplit) = split(node.left, before: position)
    node.left = rightOfSplit
    updateCount(node)
    return (leftOfSplit, node)
  }

  private func merge(_ lhs: Node?, _ rhs: Node?) -> Node? {
    guard let lhs else { return rhs }
    guard let rhs else { return lhs }
    if lhs.priority >= rhs.priority {
      push(lhs)
      lhs.right = merge(lhs.right, rhs)
      updateCount(lhs)
      return lhs
    }

    push(rhs)
    rhs.left = merge(lhs, rhs.left)
    updateCount(rhs)
    return rhs
  }

  private func count(of node: Node?, before position: Int) -> Int {
    guard let node else { return 0 }
    push(node)
    if node.position >= position {
      return count(of: node.left, before: position)
    }
    return (node.left?.count ?? 0) + 1 + count(of: node.right, before: position)
  }

  private func position(ofElementAt requestedIndex: Int, in node: Node?) -> Int? {
    guard let node else { return nil }
    push(node)
    let leftCount = node.left?.count ?? 0
    if requestedIndex < leftCount {
      return position(ofElementAt: requestedIndex, in: node.left)
    }
    if requestedIndex == leftCount {
      return node.position
    }
    return position(ofElementAt: requestedIndex - leftCount - 1, in: node.right)
  }

  private func applyShift(_ node: Node?, delta: Int) {
    guard let node, delta != 0 else { return }
    node.position += delta
    node.lazyShift += delta
  }

  private func push(_ node: Node) {
    guard node.lazyShift != 0 else { return }
    let shift = node.lazyShift
    applyShift(node.left, delta: shift)
    applyShift(node.right, delta: shift)
    node.lazyShift = 0
  }

  private func updateCount(_ node: Node) {
    node.count = 1 + (node.left?.count ?? 0) + (node.right?.count ?? 0)
  }

  @discardableResult
  private func recomputeCounts(_ node: Node?) -> Int {
    guard let node else { return 0 }
    node.count = 1 + recomputeCounts(node.left) + recomputeCounts(node.right)
    return node.count
  }

  private static func clampedRange(_ range: NSRange, utf16Length: Int) -> NSRange {
    let location = min(max(0, range.location), utf16Length)
    return NSRange(
      location: location,
      length: min(max(0, range.length), utf16Length - location)
    )
  }

  private static func newlineOffsets(in text: NSString) -> [Int] {
    guard text.length > 0 else { return [] }
    let chunkSize = 16_384
    var buffer = [unichar](repeating: 0, count: chunkSize)
    var offsets: [Int] = []
    var location = 0

    while location < text.length {
      let length = min(chunkSize, text.length - location)
      buffer.withUnsafeMutableBufferPointer { pointer in
        guard let baseAddress = pointer.baseAddress else { return }
        text.getCharacters(baseAddress, range: NSRange(location: location, length: length))
      }
      for index in 0..<length where buffer[index] == 10 {
        offsets.append(location + index)
      }
      location += length
    }
    return offsets
  }
}
