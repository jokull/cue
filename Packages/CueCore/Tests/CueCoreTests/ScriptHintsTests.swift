import Testing

@testable import CueCore

@Suite struct ScriptHintsTests {
  let script = ScriptText.words(
    "Jökull — Þú starfar á alþjóðlegum markaði. Hefur staða Íslands gagnvart ESB haft bein áhrif á rekstur ykkar, t.d. varðandi greiðslumiðlun?")

  @Test func `previous text is the opening, cut on a word boundary`() {
    let text = ScriptHints.previousText(script)
    #expect(text.count <= 50)
    #expect(text.hasPrefix("Jökull Þú starfar"))  // the lone "—" is dropped; Scribe echoed it otherwise
    #expect(!text.hasSuffix(" "))
  }

  @Test func `on reconnect it is the text just before the reader`() {
    let text = ScriptHints.previousText(script, before: 9)
    #expect(text.hasSuffix("staða Íslands"))
    #expect(text.count <= 50)
  }

  @Test func `keyterms favour rare names and long compounds`() {
    let terms = ScriptHints.keyterms(script, limit: 5)
    #expect(terms.count == 5)
    #expect(terms.contains("Íslands"))
    #expect(terms.contains("greiðslumiðlun"))
    #expect(terms.allSatisfy { $0.count <= 20 && !$0.contains(",") && !$0.contains("?") })
  }
}
