import Foundation

extension StringProtocol {
  /// Byte-wise substring test for ASCII or exact UTF-8 needles.
  ///
  /// `String.contains(_:)` compares by `Character`, which walks grapheme
  /// clusters and costs far more than a byte scan on multi-megabyte HTML or
  /// document text. Hot main-actor checks such as "does this rendered page
  /// contain a live embed?" use this instead. It matches exact bytes, so use
  /// it only where canonical equivalence does not matter (markup markers).
  func containsUTF8Bytes(_ needle: String) -> Bool {
    var needle = needle
    if needle.isEmpty { return true }
    let found = needle.withUTF8 { needleBuffer -> Bool? in
      utf8.withContiguousStorageIfAvailable { haystack -> Bool in
        guard haystack.count >= needleBuffer.count,
              let haystackBase = haystack.baseAddress,
              let needleBase = needleBuffer.baseAddress
        else { return false }
        return memmem(haystackBase, haystack.count, needleBase, needleBuffer.count) != nil
      }
    }
    if let found { return found }
    // Bridged or non-contiguous strings: Foundation's literal search still
    // avoids grapheme-cluster comparison.
    return range(of: needle, options: .literal) != nil
  }
}
