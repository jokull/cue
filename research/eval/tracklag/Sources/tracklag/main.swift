// Prompter lag, measured by replaying recorded realtime partials through CueCore.
//
// Ground truth comes from batch Scribe word timestamps aligned to the script. Two prompter
// strategies are compared per line: switch when the tracker's confirmed cursor reaches a line,
// or when ReadingPace's momentum estimate does (voice activity from the take's own audio).
//
//   swift run -c release tracklag <script.txt> <batch.scribe.json> <realtime.json> <audio.pcm>
import CueCore
import Foundation

struct Recording: Decodable {
  struct Message: Decodable {
    let at: Double
    let message_type: String
    let text: String?
  }
  let messages: [Message]
}

let arguments = CommandLine.arguments

// `tracklag hints <script.txt>` prints the hints the app sends, as JSON, for the recorder.
if arguments[1] == "hints" {
  let words = ScriptText.words(try String(contentsOfFile: arguments[2], encoding: .utf8))
  let hints = ["previous_text": ScriptHints.previousText(words) as Any, "keyterms": ScriptHints.keyterms(words)]
  print(String(decoding: try JSONSerialization.data(withJSONObject: hints), as: UTF8.self))
  exit(0)
}

// Ignore this many trailing words of every partial: recognizers guess their newest words.
let trim = arguments.firstIndex(of: "--trim").map { Int(arguments[$0 + 1]) ?? 0 } ?? 0

let script = ScriptText.words(try String(contentsOfFile: arguments[1], encoding: .utf8))
let heard = try CloudTranscript.decode(Data(contentsOf: URL(filePath: arguments[2]))).recognizedWords
let recording = try JSONDecoder().decode(Recording.self, from: Data(contentsOf: URL(filePath: arguments[3])))
let pcm = try Data(contentsOf: URL(filePath: arguments[4]))

// Ground truth: when each script word was spoken.
var spokenStart = [Double?](repeating: nil, count: script.count)
var spokenEnd = [Double?](repeating: nil, count: script.count)
var pointer = 0
for timing in Aligner.align(script: script, heard: heard) where timing.source != .adlib {
  while pointer < script.count && script[pointer].text != timing.text { pointer += 1 }
  guard pointer < script.count else { break }
  spokenStart[pointer] = timing.start
  spokenEnd[pointer] = timing.end
  pointer += 1
}

// Voice activity from the audio's level, per 50 ms frame, with a 300 ms hangover — the same
// cheap on-device signal the app can compute from the microphone.
let frame = 0.05
let samples = pcm.withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
let perFrame = Int(16000 * frame)
var levels: [Double] = stride(from: 0, to: samples.count, by: perFrame).map { start in
  let slice = samples[start..<min(start + perFrame, samples.count)]
  return (slice.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(slice.count)).squareRoot()
}
let floor = levels.sorted()[levels.count / 5]
var speaking = levels.map { $0 > max(floor * 3, 300) }
var hang = 0
for index in speaking.indices {
  if speaking[index] { hang = 6 } else if hang > 0 { speaking[index] = true; hang -= 1 }
}

// Replay on a 50 ms clock.
let lines = PrompterLines.lines(script)
var tracker = ScriptTracker(words: script)
var pace = ReadingPace()
var committed = ""
var messageIndex = 0
var display = 0.0
var trackerLineAt = [Double?](repeating: nil, count: lines.count)
var pacedLineAt = [Double?](repeating: nil, count: lines.count)
trackerLineAt[0] = 0
pacedLineAt[0] = 0
let end = Double(levels.count) * frame + 3
for step in 0...Int(end / frame) {
  let now = Double(step) * frame
  while messageIndex < recording.messages.count, recording.messages[messageIndex].at <= now {
    let message = recording.messages[messageIndex]
    messageIndex += 1
    guard let text = message.text, !text.isEmpty else { continue }
    let transcript: String
    switch message.message_type {
    case "partial_transcript":
      transcript = committed + " " + text.split(separator: " ").dropLast(trim).joined(separator: " ")
    case "committed_transcript":
      committed += " " + text
      transcript = committed
    default: continue
    }
    if tracker.update(transcript: transcript, at: message.at) { pace.confirm(word: tracker.cursor, at: message.at) }
  }
  pace.tick(at: now, speaking: step < speaking.count ? speaking[step] : false)
  display = max(display, pace.position)  // the prompter never scrolls back

  let trackerLine = PrompterLines.line(containing: max(tracker.cursor - 1, 0), in: lines)
  let pacedLine = PrompterLines.line(containing: Int(display), in: lines)
  for line in 0...trackerLine where trackerLineAt[line] == nil { trackerLineAt[line] = now }
  for line in 0...pacedLine where pacedLineAt[line] == nil { pacedLineAt[line] = now }
}

func fmt(_ value: Double?) -> String { value.map { String(format: "%+.2fs", $0) } ?? "   —  " }
print("line  starts   tracker-only  paced")
var trackerErrors: [Double] = [], pacedErrors: [Double] = []
for (index, line) in lines.enumerated() {
  guard let start = line.compactMap({ spokenStart[$0] }).first else { continue }
  let trackerError = trackerLineAt[index].map { $0 - start }
  let pacedError = pacedLineAt[index].map { $0 - start }
  if index > 0 {
    trackerError.map { trackerErrors.append($0) }
    pacedError.map { pacedErrors.append($0) }
  }
  print(String(format: "%3d   %5.2fs   ", index, start) + fmt(trackerError) + "       " + fmt(pacedError))
}
func summary(_ errors: [Double]) -> String {
  guard !errors.isEmpty else { return "-" }
  let mean = errors.map(abs).reduce(0, +) / Double(errors.count)
  return String(format: "mean |error| %.2fs, worst late %+.2fs, worst early %+.2fs", mean, errors.max()!, errors.min()!)
}
print("tracker-only: " + summary(trackerErrors))
print("paced:        " + summary(pacedErrors))
