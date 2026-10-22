import Foundation

/// One screenful of caption words, shown together.
public struct CaptionPage: Hashable, Sendable {
  public var words: [WordTiming]
  /// When the page appears and disappears. Pages hold a little past their last word,
  /// but never overlap the next page.
  public var start: TimeInterval
  public var end: TimeInterval

  public var text: String { words.map(\.text).joined(separator: " ") }
}

public struct PagingRules: Hashable, Sendable {
  public var maxWords: Int
  public var maxCharacters: Int
  public var maxDuration: TimeInterval
  /// A silence this long starts a new page.
  public var pauseBreak: TimeInterval = 0.4
  /// How long a page lingers after its last word when nothing follows straight away.
  public var hold: TimeInterval = 0.6
  /// Break after a comma or semicolon once the page has at least this many words.
  public var clauseBreakMinWords = 3

  public init(maxWords: Int, maxCharacters: Int, maxDuration: TimeInterval) {
    self.maxWords = maxWords
    self.maxCharacters = maxCharacters
    self.maxDuration = maxDuration
  }
}

public enum CaptionPager {
  public static func pages(_ words: [WordTiming], rules: PagingRules) -> [CaptionPage] {
    var groups: [[WordTiming]] = []
    var current: [WordTiming] = []

    for word in words where word.end > word.start {
      if let last = current.last, let first = current.first {
        let characters = current.reduce(0) { $0 + $1.text.count + 1 } + word.text.count
        let breaks =
          current.count >= rules.maxWords
          || characters > rules.maxCharacters
          || word.end - first.start > rules.maxDuration
          || word.start - last.end > rules.pauseBreak
          || last.endsSentence
          || (last.endsClause && current.count >= rules.clauseBreakMinWords)
        if breaks {
          groups.append(current)
          current = []
        }
      }
      current.append(word)
    }
    if !current.isEmpty { groups.append(current) }

    return groups.enumerated().map { index, group in
      let nextStart = index + 1 < groups.count ? groups[index + 1][0].start : .infinity
      let end = min(group[group.count - 1].end + rules.hold, nextStart)
      return CaptionPage(words: group, start: group[0].start, end: end)
    }
  }
}
