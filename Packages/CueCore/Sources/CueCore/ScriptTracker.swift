import Foundation

/// Follows a speaker through a script from a live, still-changing transcription.
///
/// Each update aligns the most recent heard words against a window of the script (local
/// alignment, like the caption aligner but online). Misheard words cost a little instead of
/// stopping the match, so one wrong word doesn't stall the prompter. The alignment has to end
/// at what was *just* heard, a lone word can only nudge the cursor, long jumps need several
/// matches, and the cursor never moves backwards — so ad-libs hold the place.
public struct ScriptTracker: Sendable {
  public let words: [ScriptWord]
  /// Index of the next word the speaker is expected to say.
  public private(set) var cursor = 0
  /// When the cursor last moved, in the caller's clock (seconds).
  private var movedAt: TimeInterval?

  /// How many recent heard words to align.
  var tailLength = 16
  var lookBehind = 6
  var lookAhead = 40
  /// The alignment must end within this many words of the end of the transcript, so it
  /// reflects where the speaker is now; any more trailing words and it's an ad-lib.
  var endSlack = 2
  /// Nobody reads faster than this; recognizers sometimes guess ahead, and the cursor must not
  /// run ahead of the voice with them.
  var maxWordsPerSecond = 4.5

  public init(words: [ScriptWord]) {
    self.words = words
  }

  public var isFinished: Bool { cursor >= words.count }

  /// Puts the reader somewhere else: a retake, or the script scrolled between clips. The one
  /// way the cursor moves backwards.
  public mutating func reposition(to word: Int) {
    cursor = min(max(word, 0), words.count)
    movedAt = nil
  }

  /// Feeds the full current transcription. Returns true when the cursor moved. Pass `at`
  /// (seconds, any monotonic clock) to cap advances at a human reading rate.
  @discardableResult
  public mutating func update(transcript: String, at time: TimeInterval? = nil) -> Bool {
    update(recognized: transcript.split(whereSeparator: \.isWhitespace).map { ScriptWord.normalize(String($0)) }, at: time)
  }

  @discardableResult
  public mutating func update(recognized: [String], at time: TimeInterval? = nil) -> Bool {
    let heard = Array(recognized.filter { !$0.isEmpty }.suffix(tailLength))
    guard !heard.isEmpty, !words.isEmpty else { return false }
    let lower = max(0, cursor - lookBehind)
    let upper = min(words.count, cursor + lookAhead)
    guard lower < upper else { return false }
    let window = words[lower..<upper].map(\.key)

    let n = heard.count, m = window.count
    var score = Array(repeating: Array(repeating: 0.0, count: m + 1), count: n + 1)
    var matches = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
    var best: (end: Int, score: Double, matches: Int)?

    for i in 1...n {
      for j in 1...m {
        let pair = Self.pairScore(heard[i - 1], window[j - 1])
        var cell = (score: 0.0, matches: 0)
        for candidate in [
          (score[i - 1][j - 1] + pair, matches[i - 1][j - 1] + (pair > 0 ? 1 : 0)),
          (score[i - 1][j] - Self.gap, matches[i - 1][j]),  // heard word not in script
          (score[i][j - 1] - Self.gap, matches[i][j - 1]),  // script word not heard
        ] where candidate.0 > cell.score {
          cell = candidate
        }
        score[i][j] = cell.score
        matches[i][j] = cell.matches

        // Only alignments that end on a match at (nearly) the newest heard word count.
        guard i >= n - endSlack, pair > 0, cell.matches > 0 else { continue }
        let end = lower + j - 1
        let distance = end - cursor
        if cell.matches == 1 && distance > 2 { continue }  // common words repeat
        if distance > 12 && cell.matches < 4 { continue }  // long jumps need real evidence
        let closer = best.map { abs(distance) < abs($0.end - cursor) } ?? true
        if best == nil || cell.score > best!.score || (cell.score == best!.score && closer) {
          best = (end, cell.score, cell.matches)
        }
      }
    }

    guard let best, best.end + 1 > cursor else { return false }
    var target = best.end + 1
    if let time, let movedAt {
      // A little slack for the first words and for catching up after a quiet stretch.
      let allowed = Int(((time - movedAt) * maxWordsPerSecond).rounded(.up)) + 2
      target = min(target, cursor + allowed)
    }
    guard target > cursor else { return false }
    cursor = target
    if time != nil { movedAt = time }
    return true
  }

  static let gap = 0.7

  /// Exact match 2, near-miss 1.2 (one slip in a longer word), otherwise a small penalty.
  static func pairScore(_ heard: String, _ script: String) -> Double {
    if heard == script { return 2 }
    if heard.fuzzyMatches(script) { return 1.2 }
    return -1
  }
}
