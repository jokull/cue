import AVFoundation
import CueCore
import Foundation

/// Cue's speech-to-text: ElevenLabs Scribe through the cue-api Worker, which holds the key.
/// Audio is never stored there.
nonisolated enum CloudTranscription {
  enum Failure: LocalizedError {
    case notConfigured, server(Int), noAudio

    var errorDescription: String? {
      switch self {
      case .notConfigured: "Cloud transcription isn't configured in this build."
      case .server(let status): "The transcription service answered \(status)."
      case .noAudio: "Couldn't read the take's audio."
      }
    }
  }

  struct Config {
    let url: URL
    let token: String
  }

  static var config: Config? {
    guard let info = Bundle.main.infoDictionary,
      let base = info["CueAPIURL"] as? String, !base.isEmpty, let url = URL(string: base),
      let token = info["CueAPIToken"] as? String, !token.isEmpty
    else { return nil }
    return Config(url: url, token: token)
  }

  static var isAvailable: Bool { config != nil }

  /// A single-use token for one Scribe v2 Realtime session (valid 15 minutes).
  static func realtimeToken() async throws -> String {
    guard let config else { throw Failure.notConfigured }
    var request = URLRequest(url: config.url.appending(path: "v1/realtime-token"))
    request.httpMethod = "POST"
    request.setValue("Bearer \(config.token)", forHTTPHeaderField: "Authorization")
    let (data, response) = try await URLSession.shared.data(for: request)
    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
    guard status == 200,
      let token = (try? JSONSerialization.jsonObject(with: data) as? [String: String])?["token"]
    else { throw Failure.server(status) }
    return token
  }

  /// Word timestamps for a recorded take. `language` (ISO 639-1, e.g. "is") is a hint; the
  /// keyterms are the script's rare words.
  static func recognize(_ take: URL, language: String?, keyterms: [String]) async throws -> [RecognizedWord] {
    guard let config else { throw Failure.notConfigured }
    let audio = try await extractAudio(take)
    defer { try? FileManager.default.removeItem(at: audio) }

    var query = keyterms.map { URLQueryItem(name: "keyterm", value: $0) }
    if let language { query.append(URLQueryItem(name: "language", value: language)) }
    var request = URLRequest(url: config.url.appending(path: "v1/transcribe").appending(queryItems: query))
    request.httpMethod = "POST"
    request.setValue("Bearer \(config.token)", forHTTPHeaderField: "Authorization")
    request.setValue("audio/mp4", forHTTPHeaderField: "Content-Type")
    request.timeoutInterval = 180
    let (data, response) = try await URLSession.shared.upload(for: request, fromFile: audio)
    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
    guard status == 200 else { throw Failure.server(status) }
    return try CloudTranscript.decode(data).recognizedWords
  }

  /// Just the audio track as m4a: a fraction of the video's size, and all the service needs.
  private static func extractAudio(_ take: URL) async throws -> URL {
    let out = URL.temporaryDirectory.appending(path: "\(UUID().uuidString).m4a")
    guard let session = AVAssetExportSession(asset: AVURLAsset(url: take), presetName: AVAssetExportPresetAppleM4A) else {
      throw Failure.noAudio
    }
    try await session.export(to: out, as: .m4a)
    return out
  }
}

/// The one-time permission App Review requires before audio goes to a third-party AI service
/// (Guideline 5.1.2(i)). Asked before the first recording; declining keeps everything on the
/// phone (auto-scroll, estimated captions).
enum CloudConsent {
  private static let key = "cloudSpeechConsent"
  private static let askedKey = "cloudSpeechConsentAsked"

  static var granted: Bool {
    get { UserDefaults.standard.bool(forKey: key) }
    set {
      UserDefaults.standard.set(newValue, forKey: key)
      UserDefaults.standard.set(true, forKey: askedKey)
    }
  }

  static var asked: Bool { UserDefaults.standard.bool(forKey: askedKey) }
}
