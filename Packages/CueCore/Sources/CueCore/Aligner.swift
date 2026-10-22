import Foundation

/// Aligns what the recognizer heard against what the script says, so captions get the
/// script's spelling and the voice's timing.
///
/// This is global sequence alignment (Needleman–Wunsch): matches and near-matches pair a
/// script word with a recognized word; unpaired recognized words are ad-libs; unpaired
/// script words were skipped, or were said but missed by the recognizer.
public enum Aligner {
  /// The longest run of unheard script words that gets interpolated rather than dropped.
  static let maxInterpolatedRun = 3
  /// The least time an interpolated word may take; shorter gaps mean the words were skipped.
  static let minInterpolatedWordDuration: TimeInterval = 0.08

  enum Step: Equatable {
    case pair(script: Int, heard: Int)
    case skipped(script: Int)
    case adlib(heard: Int)
  }

  public static func align(script: [ScriptWord], heard: [RecognizedWord]) -> [WordTiming] {
    let steps = path(script: script.map(\.key), heard: heard.map { ScriptWord.normalize($0.text) })
    var timings: [WordTiming] = []
    var pendingSkipped: [Int] = []

    func flushSkipped(until next: TimeInterval?) {
      defer { pendingSkipped.removeAll() }
      guard !pendingSkipped.isEmpty,
        pendingSkipped.count <= maxInterpolatedRun,
        let previous = timings.last,
        let next
      else { return }
      let gap = next - previous.end
      let slot = gap / Double(pendingSkipped.count)
      guard slot >= minInterpolatedWordDuration else { return }
      for (offset, index) in pendingSkipped.enumerated() {
        let start = previous.end + slot * Double(offset)
        timings.append(WordTiming(text: script[index].text, start: start, end: start + slot, source: .interpolated))
      }
    }

    for step in steps {
      switch step {
      case .skipped(let s):
        pendingSkipped.append(s)
      case .pair(let s, let h):
        flushSkipped(until: heard[h].start)
        timings.append(WordTiming(text: script[s].text, start: heard[h].start, end: heard[h].end, source: .script))
      case .adlib(let h):
        flushSkipped(until: heard[h].start)
        timings.append(WordTiming(text: heard[h].text, start: heard[h].start, end: heard[h].end, source: .adlib))
      }
    }
    pendingSkipped.removeAll()
    return timings
  }

  /// Spreads the script evenly over a take when there is no recognition to align against,
  /// weighting each word by its length and pausing at punctuation.
  public static func estimate(script: [ScriptWord], duration: TimeInterval, leadIn: TimeInterval = 0.3) -> [WordTiming] {
    guard !script.isEmpty, duration > leadIn else { return [] }
    let weights = script.map { word in
      Double(max(word.key.count, 2)) + (word.endsSentence ? 4 : word.endsClause ? 2 : 0)
    }
    let unit = (duration - leadIn) / weights.reduce(0, +)
    var clock = leadIn
    return zip(script, weights).map { word, weight in
      let pause = word.endsSentence ? 4 * unit : word.endsClause ? 2 * unit : 0
      let speaking = weight * unit - pause
      defer { clock += weight * unit }
      return WordTiming(text: word.text, start: clock, end: clock + speaking, source: .estimated)
    }
  }

  static func path(script: [String], heard: [String]) -> [Step] {
    let n = script.count, m = heard.count
    let match = 3, fuzzy = 2, mismatch = -2, gap = -1
    var score = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
    for i in 0...n { score[i][0] = i * gap }
    for j in 0...m { score[0][j] = j * gap }
    if n > 0 && m > 0 {
      for i in 1...n {
        for j in 1...m {
          let pairScore =
            script[i - 1] == heard[j - 1] ? match
            : script[i - 1].fuzzyMatches(heard[j - 1]) ? fuzzy : mismatch
          score[i][j] = max(
            score[i - 1][j - 1] + pairScore,
            score[i - 1][j] + gap,
            score[i][j - 1] + gap
          )
        }
      }
    }

    var steps: [Step] = []
    var i = n, j = m
    while i > 0 || j > 0 {
      if i > 0, j > 0 {
        let pairScore =
          script[i - 1] == heard[j - 1] ? match
          : script[i - 1].fuzzyMatches(heard[j - 1]) ? fuzzy : mismatch
        if pairScore > 0, score[i][j] == score[i - 1][j - 1] + pairScore {
          steps.append(.pair(script: i - 1, heard: j - 1))
          i -= 1; j -= 1
          continue
        }
      }
      if i > 0, score[i][j] == score[i - 1][j] + gap {
        steps.append(.skipped(script: i - 1))
        i -= 1
      } else if j > 0, score[i][j] == score[i][j - 1] + gap {
        steps.append(.adlib(heard: j - 1))
        j -= 1
      } else {
        // A mismatched pair scored best: treat it as a skip plus an ad-lib.
        steps.append(.adlib(heard: j - 1))
        steps.append(.skipped(script: i - 1))
        i -= 1; j -= 1
      }
    }
    return steps.reversed()
  }
}
