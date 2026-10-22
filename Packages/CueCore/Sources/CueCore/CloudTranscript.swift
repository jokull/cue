import Foundation

/// A cloud transcription with per-word timestamps: the `cue-api` Worker's slim response, or
/// ElevenLabs Scribe's raw response (whose spacing tokens are skipped).
public struct CloudTranscript: Decodable, Sendable {
  public struct Word: Decodable, Sendable {
    public var text: String
    public var start: TimeInterval
    public var end: TimeInterval
    /// Scribe tags tokens as "word", "spacing" or "audio_event"; the slim form omits it.
    public var type: String?
  }

  /// ISO 639 code the service heard, e.g. "is" or "isl".
  public var language: String?
  public var words: [Word]

  enum CodingKeys: String, CodingKey {
    case language, languageCode = "language_code", words
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    language = try container.decodeIfPresent(String.self, forKey: .language)
      ?? container.decodeIfPresent(String.self, forKey: .languageCode)
    words = try container.decode([Word].self, forKey: .words)
  }

  public static func decode(_ data: Data) throws -> CloudTranscript {
    try JSONDecoder().decode(CloudTranscript.self, from: data)
  }

  /// Spoken words only, ready for `Aligner.align`.
  public var recognizedWords: [RecognizedWord] {
    words
      .filter { ($0.type ?? "word") == "word" && !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }
      .map { RecognizedWord(text: $0.text.trimmingCharacters(in: .whitespaces), start: $0.start, duration: max($0.end - $0.start, 0.01)) }
  }
}
