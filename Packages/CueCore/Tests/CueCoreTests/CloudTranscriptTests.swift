import Foundation
import Testing

@testable import CueCore

@Suite struct CloudTranscriptTests {
  func fixture(_ name: String) throws -> Data {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures"))
    return try Data(contentsOf: url)
  }

  @Test(arguments: ["scribe-is-raw.json", "scribe-is-slim.json"])
  func `reads Scribe's raw and the Worker's slim response alike`(name: String) throws {
    let transcript = try CloudTranscript.decode(try fixture(name))
    let words = transcript.recognizedWords
    #expect(words.count == 33)
    #expect(words.first?.text == "Góðan")
    #expect(words.allSatisfy { !$0.text.contains(" ") && $0.duration > 0 })
    #expect(transcript.language?.hasPrefix("is") == true)
  }

  @Test func `an Icelandic take aligns to its script with the voice's timing`() throws {
    let script = ScriptText.words(String(decoding: try fixture("scribe-is-script.txt"), as: UTF8.self))
    let heard = try CloudTranscript.decode(try fixture("scribe-is-slim.json")).recognizedWords
    let timings = Aligner.align(script: script, heard: heard)
    #expect(timings.map(\.text) == script.map(\.text))
    #expect(timings.allSatisfy { $0.source == .script })
    #expect(abs(timings[0].start - 0.06) < 0.001)
    // Icelandic letters survive normalization on both sides.
    #expect(timings.contains { $0.text == "skjátextarnir" })
  }
}
