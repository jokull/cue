import CueCore
import Foundation
import NaturalLanguage
import SwiftData

@Model final class Script {
  var id = UUID()
  var title: String
  var text: String
  var createdAt = Date.now
  @Relationship(deleteRule: .cascade, inverse: \Take.script) var takes: [Take] = []

  init(text: String) {
    self.text = text
    self.title = Script.title(for: text)
  }

  var words: [ScriptWord] { ScriptText.words(text) }

  var detectedLanguage: NLLanguage? { LanguageDetection.language(of: text) }

  /// ISO 639-1 hint for the speech service, e.g. "is"; nil lets Scribe detect it.
  var languageCode: String? { detectedLanguage?.rawValue }

  /// "340 words · ≈2:40 read"
  var summary: String {
    let count = words.count
    let read = Duration.seconds(ScriptText.estimatedReadTime(wordCount: count))
    return "\(count) words · ≈\(read.formatted(.time(pattern: .minuteSecond))) read"
  }

  /// The first few words of the first sentence, without trailing punctuation.
  static func title(for text: String) -> String {
    let firstSentence = text.split(whereSeparator: { ".!?\n".contains($0) }).first.map(String.init) ?? text
    let words = firstSentence.split(whereSeparator: \.isWhitespace).prefix(5)
    let title = words.joined(separator: " ").trimmingCharacters(in: .punctuationCharacters)
    return title.isEmpty ? "Untitled script" : title
  }
}

@Model final class Take {
  var id = UUID()
  var createdAt = Date.now
  var number: Int
  var fileName: String
  var duration: TimeInterval
  var isFavorite = false
  var script: Script?
  private var timingsData: Data?
  private var timingQualityRaw = TimingQuality.pending.rawValue
  private var settingsData: Data?

  init(script: Script, fileName: String, duration: TimeInterval) {
    self.script = script
    self.number = script.takes.count + 1
    self.fileName = fileName
    self.duration = duration
  }

  var url: URL { TakeFiles.directory.appending(path: fileName) }
  var title: String { script?.title ?? "Untitled" }

  var timings: [WordTiming] {
    get { timingsData.flatMap { try? JSONDecoder().decode([WordTiming].self, from: $0) } ?? [] }
    set { timingsData = try? JSONEncoder().encode(newValue) }
  }

  var timingQuality: TimingQuality {
    get { TimingQuality(rawValue: timingQualityRaw) ?? .pending }
    set { timingQualityRaw = newValue.rawValue }
  }

  var captionSettings: CaptionSettings {
    get { settingsData.flatMap { try? JSONDecoder().decode(CaptionSettings.self, from: $0) } ?? CaptionSettings() }
    set { settingsData = try? JSONEncoder().encode(newValue) }
  }
}

/// How the caption timings for a take were obtained, best first.
enum TimingQuality: String {
  case pending
  /// Aligned against a full recognition pass over the recorded audio.
  case voice
  /// From the teleprompter's live tracking while recording.
  case live
  /// Spread evenly over the take; no usable recognition.
  case estimated

  var label: String {
    switch self {
    case .pending: "Aligning to your voice…"
    case .voice: "Anchored to your voice"
    case .live: "Timed from live tracking"
    case .estimated: "Estimated timing"
    }
  }
}

nonisolated enum TakeFiles {
  static let directory: URL = {
    let url = URL.documentsDirectory.appending(path: "Takes", directoryHint: .isDirectory)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }()

  static let exports: URL = {
    let url = URL.temporaryDirectory.appending(path: "Exports", directoryHint: .isDirectory)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }()

  static func newTakeURL() -> URL {
    directory.appending(path: "\(UUID().uuidString).mp4")
  }

  /// Clips live in a scratch folder until Done stitches them into a take.
  static let clips: URL = {
    let url = URL.temporaryDirectory.appending(path: "Clips", directoryHint: .isDirectory)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }()

  static func newClipURL() -> URL {
    clips.appending(path: "\(UUID().uuidString).mp4")
  }
}
