import Foundation

/// A word the speech recognizer heard, with where it heard it.
public struct RecognizedWord: Hashable, Sendable, Codable {
  public var text: String
  public var start: TimeInterval
  public var duration: TimeInterval

  public init(text: String, start: TimeInterval, duration: TimeInterval) {
    self.text = text
    self.start = start
    self.duration = duration
  }

  public var end: TimeInterval { start + duration }
}

/// A caption word anchored to the moment it was spoken.
public struct WordTiming: Hashable, Sendable, Codable, Identifiable {
  public enum Source: String, Sendable, Codable {
    /// Matched to the script, so it uses the script's spelling.
    case script
    /// Not in the script; the recognizer's text.
    case adlib
    /// In the script but not heard clearly; timing interpolated between its neighbours.
    case interpolated
    /// No usable recognition; timing estimated from the script and the take's length.
    case estimated
  }

  public var id = UUID()
  public var text: String
  public var start: TimeInterval
  public var end: TimeInterval
  public var source: Source

  public init(text: String, start: TimeInterval, end: TimeInterval, source: Source) {
    self.text = text
    self.start = start
    self.end = end
    self.source = source
  }

  public var duration: TimeInterval { end - start }

  var endsClause: Bool { ScriptWord(text: text).endsClause }
  var endsSentence: Bool { ScriptWord(text: text).endsSentence }
}
