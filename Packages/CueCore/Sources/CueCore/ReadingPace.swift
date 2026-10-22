import Foundation

/// The prompter's lines: the script wrapped at a character budget, as ranges of word indices.
/// Shared by the app's prompter and the lag replay so both see the same lines.
public enum PrompterLines {
  public static func lines(_ words: [ScriptWord], maxCharacters: Int = 34) -> [Range<Int>] {
    var lines: [Range<Int>] = []
    var start = 0, characters = 0
    for (index, word) in words.enumerated() {
      if characters > 0, characters + word.text.count > maxCharacters {
        lines.append(start..<index)
        start = index
        characters = 0
      }
      characters += word.text.count + 1
    }
    if start < words.count { lines.append(start..<words.count) }
    return lines
  }

  public static func line(containing word: Int, in lines: [Range<Int>]) -> Int {
    lines.firstIndex { $0.contains(word) } ?? max(lines.count - 1, 0)
  }
}

/// Dead reckoning for the prompter. Recognition confirms where the reader *was* about a second
/// ago; between confirmations the reader keeps going at their own pace. So the estimate is the
/// last confirmed word plus the reader's measured rate times the time they've spent *speaking*
/// since then (silence freezes it), plus the recognition latency — capped so it never runs more
/// than about a line ahead of the evidence.
public struct ReadingPace: Sendable {
  /// How far behind the voice a confirmation is, in seconds.
  public var latency: TimeInterval = 1.2
  /// The furthest the estimate may run ahead of the last confirmed word.
  public var maxLead = 6.0
  /// Words per second; starts at a typical read-aloud pace and learns the reader's.
  public private(set) var rate = 2.6

  private var confirmed: Double = 0
  private var confirmedAt: TimeInterval?
  private var voicedSinceConfirm: TimeInterval = 0
  private var lastTick: TimeInterval?

  public init() {}

  /// Starts over at `word`: a new clip, a retake, or the script scrolled by hand. The learned
  /// reading rate carries over — it's the same reader.
  public mutating func reset(to word: Int) {
    confirmed = Double(word)
    confirmedAt = nil
    voicedSinceConfirm = 0
    lastTick = nil
  }

  /// Called when the tracker's cursor moves.
  public mutating func confirm(word: Int, at time: TimeInterval) {
    let position = Double(word)
    if let confirmedAt, position > confirmed, voicedSinceConfirm > 0.3 {
      // Learn the rate from speaking time only, smoothed so one jumpy partial can't swing it.
      let observed = (position - confirmed) / max(voicedSinceConfirm, time - confirmedAt)
      rate = min(max(0.7 * rate + 0.3 * observed, 1.2), 4.5)
    }
    confirmed = max(confirmed, position)
    confirmedAt = time
    voicedSinceConfirm = 0
  }

  /// Advance the clock. `speaking` comes from the microphone's level, on-device.
  public mutating func tick(at time: TimeInterval, speaking: Bool) {
    // Readers start at the first word: begin projecting the moment they start talking, rather
    // than waiting ~2.5 s for the recognizer's first transcript.
    if confirmedAt == nil, speaking { confirm(word: Int(confirmed), at: time) }
    if let lastTick, speaking { voicedSinceConfirm += time - lastTick }
    lastTick = time
  }

  /// The estimated current word (fractional), never behind the evidence.
  public var position: Double {
    guard confirmedAt != nil else { return confirmed }
    let lead = rate * (voicedSinceConfirm + (voicedSinceConfirm > 0 ? latency : 0))
    return confirmed + min(lead, maxLead)
  }
}
