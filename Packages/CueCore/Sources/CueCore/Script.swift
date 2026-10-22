import Foundation

/// One word of a script as the author wrote it.
public struct ScriptWord: Hashable, Sendable, Codable {
  /// The word as displayed, punctuation included ("everyone.").
  public var text: String
  /// Lowercased, punctuation- and diacritic-free form used for matching ("everyone").
  public var key: String

  public init(text: String) {
    self.text = text
    self.key = ScriptWord.normalize(text)
  }

  /// True when the word ends a sentence or clause, which is a natural caption break.
  public var endsClause: Bool {
    guard let last = trailingMark else { return false }
    return ".!?;:,—…".contains(last)
  }

  public var endsSentence: Bool {
    guard let last = trailingMark else { return false }
    return ".!?…".contains(last)
  }

  /// The last character once closing quotes and brackets are set aside.
  private var trailingMark: Character? {
    text.trimmingCharacters(in: CharacterSet(charactersIn: "\"'”’)]")).last
  }

  public static func normalize(_ text: String) -> String {
    let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    return String(folded.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
  }
}

public enum ScriptText {
  /// Splits a script into words. Words that normalize to nothing (a lone "—") are dropped.
  public static func words(_ script: String) -> [ScriptWord] {
    script
      .split(whereSeparator: \.isWhitespace)
      .map { ScriptWord(text: String($0)) }
      .filter { !$0.key.isEmpty }
  }

  /// Seconds to read a script aloud at a conversational pace.
  public static func estimatedReadTime(wordCount: Int, wordsPerMinute: Double = 130) -> TimeInterval {
    Double(wordCount) / wordsPerMinute * 60
  }
}

extension String {
  /// Fuzzy word equality tolerant of one recognizer slip ("launching" ≈ "lunching").
  func fuzzyMatches(_ other: String) -> Bool {
    if self == other { return true }
    if min(count, other.count) < 4 { return false }
    if abs(count - other.count) > 1 { return false }
    return levenshtein(other) <= 1
  }

  func levenshtein(_ other: String) -> Int {
    let a = Array(self), b = Array(other)
    if a.isEmpty { return b.count }
    if b.isEmpty { return a.count }
    var previous = Array(0...b.count)
    var current = Array(repeating: 0, count: b.count + 1)
    for i in 1...a.count {
      current[0] = i
      for j in 1...b.count {
        current[j] = Swift.min(
          previous[j] + 1,
          current[j - 1] + 1,
          previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1)
        )
      }
      swap(&previous, &current)
    }
    return previous[b.count]
  }
}
