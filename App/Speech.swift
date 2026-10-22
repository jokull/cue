import AVFoundation
import CueCore
import NaturalLanguage

/// The script's language, detected silently. It's only a hint for the speech service — Scribe
/// recognizes the language itself — but a correct hint helps the first seconds of a take.
nonisolated enum LanguageDetection {
  /// The script's language, or nil when the text is too short or ambiguous to tell.
  static func language(of text: String) -> NLLanguage? {
    guard text.split(whereSeparator: \.isWhitespace).count >= 3 else { return nil }
    if let (language, confidence) = hypothesis(text, hints: [:]), confidence >= 0.8 { return language }
    // Unsure: lean toward the languages set up on this phone to break the tie. Only as a
    // tie-breaker — as a prior it drowns out clearly Spanish or Portuguese scripts.
    var hints: [NLLanguage: Double] = [:]
    for identifier in Locale.preferredLanguages.prefix(4) {
      if let code = Locale(identifier: identifier).language.languageCode?.identifier {
        hints[NLLanguage(code), default: 0] += 0.25
      }
    }
    guard let (language, confidence) = hypothesis(text, hints: hints), confidence > 0.5 else { return nil }
    return language
  }

  private static func hypothesis(_ text: String, hints: [NLLanguage: Double]) -> (NLLanguage, Double)? {
    let recognizer = NLLanguageRecognizer()
    recognizer.languageHints = hints
    recognizer.processString(text)
    guard let (language, confidence) = recognizer.languageHypotheses(withMaximum: 1).first,
      language != .undetermined
    else { return nil }
    return (language, confidence)
  }
}

/// Follows the reader through the script by voice: microphone → Scribe v2 Realtime → script
/// tracker → reading-pace model. Recognition runs about a second behind the voice, so the
/// prompter is driven by `position`, the pace model's estimate, which keeps moving while the
/// reader speaks and freezes when they stop (research/eval: line switches within ~0.3 s).
@Observable final class LiveSpeechTracker {
  enum Readiness: Equatable {
    case ready
    /// No consent, no network or no service: the prompter auto-scrolls instead.
    case unavailable(String)
  }

  /// Estimated current word, fractional; never moves backwards.
  private(set) var position = 0.0
  private(set) var isListening = false
  private(set) var readiness = Readiness.ready

  @ObservationIgnored private var tracker: ScriptTracker
  @ObservationIgnored private var pace = ReadingPace()
  @ObservationIgnored let language: String?
  @ObservationIgnored private var client: ScribeRealtime?
  @ObservationIgnored private var listenTask: Task<Void, Never>?
  @ObservationIgnored private var clockTask: Task<Void, Never>?
  @ObservationIgnored private var committed = ""
  @ObservationIgnored private var startedAt = ContinuousClock.now
  @ObservationIgnored private var advances: [(cursor: Int, time: TimeInterval)] = []
  @ObservationIgnored private var reconnects = 0
  /// The capture queue hands microphone audio to this.
  @ObservationIgnored nonisolated let feed = MicrophoneFeed()

  /// Trailing words of each partial to ignore: Scribe guesses its newest words and revises them.
  static let unreliableTail = 1

  init(script: [ScriptWord], language: String?) {
    tracker = ScriptTracker(words: script)
    self.language = language
  }

  var words: [ScriptWord] { tracker.words }
  var cursor: Int { tracker.cursor }

  func prepare() {
    if !CloudConsent.granted {
      readiness = .unavailable("Voice tracking is off.")
    } else if !CloudTranscription.isAvailable {
      readiness = .unavailable("Voice tracking isn't configured in this build.")
    } else {
      readiness = .ready
    }
  }

  /// Moves the reader: a retake, or the script dragged between clips.
  func reposition(to word: Int) {
    tracker.reposition(to: word)
    pace.reset(to: word)
    position = Double(min(max(word, 0), words.count))
  }

  /// Starts listening for one clip, from wherever the reader is now.
  func start() async {
    guard !isListening, readiness == .ready else { return }
    isListening = true
    startedAt = .now
    committed = ""
    reconnects = 0
    // Each clip has its own clock; carry the place and the reader's pace into it.
    tracker.reposition(to: tracker.cursor)
    pace.reset(to: tracker.cursor)
    await connect()
    // Dead reckoning between transcripts, at display rate.
    clockTask = Task { [weak self] in
      while !Task.isCancelled, let self {
        self.pace.tick(at: self.now, speaking: self.feed.isSpeaking)
        self.position = max(self.position, min(self.pace.position, Double(self.words.count)))
        try? await Task.sleep(for: .milliseconds(50))
      }
    }
  }

  func stop() {
    isListening = false
    clockTask?.cancel()
    listenTask?.cancel()
    feed.output = nil
    client?.close()  // silence is billed: close the moment recording ends
    client = nil
  }

  /// Rough per-word timings from when the cursor moved, for when the caption pass fails.
  func liveTimings(until duration: TimeInterval) -> [WordTiming] {
    var timings: [WordTiming] = []
    var previous = (cursor: 0, time: 0.0)
    for advance in advances where advance.cursor > previous.cursor {
      let count = advance.cursor - previous.cursor
      let slot = max(advance.time - previous.time, 0.1) / Double(count)
      for (offset, index) in (previous.cursor..<advance.cursor).enumerated() {
        let start = previous.time + slot * Double(offset)
        timings.append(WordTiming(text: tracker.words[index].text, start: start, end: start + slot * 0.9, source: .script))
      }
      previous = advance
    }
    return timings.filter { $0.end <= duration }
  }

  private var now: TimeInterval {
    let elapsed = ContinuousClock.now - startedAt
    return Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
  }

  private func connect() async {
    guard isListening else { return }
    do {
      let token = try await CloudTranscription.realtimeToken()
      let client = ScribeRealtime(
        token: token,
        language: language,
        keyterms: ScriptHints.keyterms(words),
        previousText: ScriptHints.previousText(words, before: tracker.cursor))
      self.client = client
      feed.output = { client.send($0) }
      client.connect()
      listenTask = Task { [weak self] in
        for await event in client.events {
          guard let self else { return }
          self.handle(event)
        }
        await self?.sessionEnded()
      }
    } catch {
      readiness = .unavailable("Couldn't reach voice tracking.")
    }
  }

  private func handle(_ event: ScribeRealtime.Event) {
    let transcript: String
    switch event {
    case .partial(let text):
      let reliable = text.split(whereSeparator: \.isWhitespace).dropLast(Self.unreliableTail)
      transcript = committed + " " + reliable.joined(separator: " ")
    case .committed(let text):
      committed += " " + text
      transcript = committed
    case .failed:
      return
    }
    let time = now
    if tracker.update(transcript: transcript, at: time) {
      pace.confirm(word: tracker.cursor, at: time)
      advances.append((tracker.cursor, time))
    }
  }

  /// Sessions end on their own (time limits, network). Pick up where the reader is.
  private func sessionEnded() async {
    guard isListening, reconnects < 5 else { return }
    reconnects += 1
    committed = ""
    try? await Task.sleep(for: .milliseconds(300))
    await connect()
  }
}

/// Microphone audio → 16 kHz mono 16-bit PCM in 100 ms chunks, plus a voice-activity flag from
/// the signal level (cheap, on-device, instant — it drives the pace model between transcripts).
/// Called on the capture queue; state is behind a lock.
nonisolated final class MicrophoneFeed: @unchecked Sendable {
  static let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true)!
  static let chunkBytes = 3200  // 100 ms

  private let lock = NSLock()
  private var converter: AVAudioConverter?
  private var pending = Data()
  private var _output: (@Sendable (Data) -> Void)?
  private var noiseFloor = 400.0
  private var hangover = 0
  private var _isSpeaking = false

  var output: (@Sendable (Data) -> Void)? {
    get { lock.withLock { _output } }
    set { lock.withLock { _output = newValue } }
  }

  var isSpeaking: Bool { lock.withLock { _isSpeaking } }

  func append(_ sampleBuffer: CMSampleBuffer) {
    guard let buffer = Self.pcmBuffer(from: sampleBuffer) else { return }
    lock.withLock {
      guard let pcm = convert(buffer) else { return }
      ingest(pcm)
    }
  }

  /// Raw 16 kHz Int16 audio, for the Simulator's file-driven test mode.
  func appendPCM(_ data: Data) {
    lock.withLock { ingest(data) }
  }

  private func ingest(_ pcm: Data) {
    detectVoice(pcm)
    pending.append(pcm)
    while pending.count >= Self.chunkBytes {
      let chunk = pending.prefix(Self.chunkBytes)
      pending.removeFirst(Self.chunkBytes)
      _output?(Data(chunk))
    }
  }

  /// Speaking when the level clears an adaptive noise floor, with ~300 ms of hangover so the
  /// gaps between words don't count as silence.
  private func detectVoice(_ pcm: Data) {
    let level = pcm.withUnsafeBytes { raw -> Double in
      let samples = raw.bindMemory(to: Int16.self)
      guard !samples.isEmpty else { return 0 }
      return (samples.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(samples.count)).squareRoot()
    }
    // The floor follows quiet stretches quickly and loud ones slowly.
    noiseFloor = level < noiseFloor ? 0.8 * noiseFloor + 0.2 * level : 0.999 * noiseFloor + 0.001 * level
    if level > max(noiseFloor * 3, 300) {
      _isSpeaking = true
      hangover = 3  // buffers are ~100 ms
    } else if hangover > 0 {
      hangover -= 1
    } else {
      _isSpeaking = false
    }
  }

  private func convert(_ buffer: AVAudioPCMBuffer) -> Data? {
    if converter == nil || converter?.inputFormat != buffer.format {
      converter = AVAudioConverter(from: buffer.format, to: Self.format)
    }
    guard let converter else { return nil }
    let capacity = AVAudioFrameCount((Double(buffer.frameLength) * 16000 / buffer.format.sampleRate).rounded(.up)) + 16
    guard let output = AVAudioPCMBuffer(pcmFormat: Self.format, frameCapacity: capacity) else { return nil }
    var consumed = false
    var error: NSError?
    converter.convert(to: output, error: &error) { _, status in
      if consumed {
        status.pointee = .noDataNow
        return nil
      }
      consumed = true
      status.pointee = .haveData
      return buffer
    }
    guard error == nil, output.frameLength > 0, let samples = output.int16ChannelData else { return nil }
    return Data(bytes: samples[0], count: Int(output.frameLength) * 2)
  }

  static func pcmBuffer(from sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
    guard let description = CMSampleBufferGetFormatDescription(sampleBuffer) else { return nil }
    let format = AVAudioFormat(cmAudioFormatDescription: description)
    let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
    guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
    buffer.frameLength = frames
    let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
      sampleBuffer, at: 0, frameCount: Int32(frames), into: buffer.mutableAudioBufferList)
    return status == noErr ? buffer : nil
  }
}

/// ElevenLabs Scribe v2 Realtime over a WebSocket, with a single-use token so the app holds no
/// key. Partials replace each other; commits arrive at pauses (VAD). Settings and their reasons:
/// research/elevenlabs-api.md §1.
nonisolated final class ScribeRealtime: @unchecked Sendable {
  enum Event: Sendable {
    case partial(String)
    case committed(String)
    case failed(String)
  }

  let events: AsyncStream<Event>
  private let continuation: AsyncStream<Event>.Continuation
  private let task: URLSessionWebSocketTask
  private let previousText: String
  private let lock = NSLock()
  private var sentFirstChunk = false

  init(token: String, language: String?, keyterms: [String], previousText: String) {
    var components = URLComponents(string: "wss://api.elevenlabs.io/v1/speech-to-text/realtime")!
    var query = [
      URLQueryItem(name: "model_id", value: "scribe_v2_realtime"),
      URLQueryItem(name: "token", value: token),
      URLQueryItem(name: "audio_format", value: "pcm_16000"),
      // Commit at real pauses only: committing on a timer garbled Icelandic in testing.
      URLQueryItem(name: "commit_strategy", value: "vad"),
      URLQueryItem(name: "vad_silence_threshold_secs", value: "0.5"),
    ]
    if let language { query.append(URLQueryItem(name: "language_code", value: language)) }
    query += keyterms.prefix(50).map { URLQueryItem(name: "keyterms", value: $0) }
    components.queryItems = query
    task = URLSession.shared.webSocketTask(with: components.url!)
    self.previousText = previousText
    (events, continuation) = AsyncStream.makeStream(of: Event.self)
  }

  func connect() {
    task.resume()
    receive()
  }

  /// 100 ms of 16 kHz mono Int16. The first chunk carries the script context.
  func send(_ pcm: Data) {
    var message: [String: Any] = [
      "message_type": "input_audio_chunk",
      "audio_base_64": pcm.base64EncodedString(),
      "commit": false,
      "sample_rate": 16000,
    ]
    let first = lock.withLock {
      defer { sentFirstChunk = true }
      return !sentFirstChunk
    }
    if first, !previousText.isEmpty { message["previous_text"] = previousText }
    guard let data = try? JSONSerialization.data(withJSONObject: message),
      let text = String(data: data, encoding: .utf8)
    else { return }
    task.send(.string(text)) { _ in }
  }

  func close() {
    task.cancel(with: .normalClosure, reason: nil)
    continuation.finish()
  }

  private func receive() {
    task.receive { [weak self] result in
      guard let self else { return }
      switch result {
      case .success(.string(let text)):
        self.handle(text)
        self.receive()
      case .success:
        self.receive()
      case .failure(let error):
        self.continuation.yield(.failed(error.localizedDescription))
        self.continuation.finish()
      }
    }
  }

  private func handle(_ text: String) {
    guard let data = text.data(using: .utf8),
      let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let type = message["message_type"] as? String
    else { return }
    let body = message["text"] as? String ?? ""
    switch type {
    case "partial_transcript": continuation.yield(.partial(body))
    case "committed_transcript": continuation.yield(.committed(body))
    case "session_started", "committed_transcript_with_timestamps": break
    default:
      // Every error type arrives as a message just before the socket closes.
      continuation.yield(.failed(message["error"] as? String ?? type))
    }
  }
}

/// Fills in a take's caption timings: Scribe v2 on the recorded audio, aligned to the script;
/// live tracking or an even estimate when that isn't possible (no consent, no network).
enum CaptionAlignment {
  static func run(for take: Take, live: [WordTiming] = []) async {
    guard let script = take.script else { return }
    let words = script.words
    #if DEBUG
      let skipsCloud = ProcessInfo.processInfo.arguments.contains("-cueNoSpeech")
    #else
      let skipsCloud = false
    #endif
    if !skipsCloud, CloudConsent.granted, CloudTranscription.isAvailable,
      let heard = try? await CloudTranscription.recognize(
        take.url, language: script.languageCode, keyterms: ScriptHints.keyterms(words)),
      !heard.isEmpty
    {
      take.timings = Aligner.align(script: words, heard: heard)
      take.timingQuality = .voice
    } else if live.count > words.count / 2 {
      take.timings = live
      take.timingQuality = .live
    } else {
      take.timings = Aligner.estimate(script: words, duration: take.duration)
      take.timingQuality = .estimated
    }
  }
}
