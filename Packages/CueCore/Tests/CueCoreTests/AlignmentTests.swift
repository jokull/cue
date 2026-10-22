import Foundation
import Testing

@testable import CueCore

let sample = "Hey friends. We shipped the new camera today, and honestly it changes everything."

/// Recognized words spoken back to back, 0.3s each, starting at `from`.
func heard(_ text: String, from: TimeInterval = 0, step: TimeInterval = 0.3) -> [RecognizedWord] {
  text.split(separator: " ").enumerated().map { index, word in
    RecognizedWord(text: String(word), start: from + Double(index) * step, duration: step * 0.9)
  }
}

@Suite struct ScriptTextTests {
  @Test func `normalizes case, punctuation and diacritics`() {
    #expect(ScriptWord(text: "Everyone.").key == "everyone")
    #expect(ScriptWord(text: "Café,").key == "cafe")
    #expect(ScriptWord(text: "“Hey!”").key == "hey")
  }

  @Test func `drops words that are only punctuation`() {
    #expect(ScriptText.words("One — two").map(\.text) == ["One", "two"])
  }

  @Test(arguments: [("today,", false, true), ("everything.", true, true), ("camera", false, false), ("done?”", true, true)])
  func `recognizes clause and sentence endings`(text: String, sentence: Bool, clause: Bool) {
    let word = ScriptWord(text: text)
    #expect(word.endsSentence == sentence)
    #expect(word.endsClause == clause)
  }

  @Test(arguments: [("launching", "lunching", true), ("the", "they", false), ("camera", "camera", true), ("shipped", "shipping", false)])
  func `fuzzy matching tolerates one slip in longer words`(a: String, b: String, matches: Bool) {
    #expect(a.fuzzyMatches(b) == matches)
  }
}

@Suite struct ScriptTrackerTests {
  var tracker = ScriptTracker(words: ScriptText.words(sample))

  @Test mutating func `follows a growing transcription`() {
    tracker.update(transcript: "hey friends")
    #expect(tracker.cursor == 2)
    tracker.update(transcript: "hey friends we shipped the new")
    #expect(tracker.cursor == 6)
    tracker.update(transcript: "hey friends we shipped the new camera today and honestly it changes everything")
    #expect(tracker.isFinished)
  }

  @Test mutating func `holds position during an ad-lib`() {
    tracker.update(transcript: "hey friends we shipped")
    let before = tracker.cursor
    tracker.update(transcript: "hey friends we shipped um so yeah like super excited")
    #expect(tracker.cursor == before)
    tracker.update(transcript: "hey friends we shipped um so yeah like super excited the new camera")
    #expect(tracker.cursor == 7)
  }

  @Test mutating func `never moves backwards on a rewritten hypothesis`() {
    tracker.update(transcript: "hey friends we shipped the new camera")
    tracker.update(transcript: "hey friends")
    #expect(tracker.cursor == 7)
  }

  @Test mutating func `a lone common word cannot jump far ahead`() {
    tracker.update(transcript: "hey")
    tracker.update(transcript: "hey it")
    #expect(tracker.cursor == 1)
  }
}

@Suite struct AlignerTests {
  let script = ScriptText.words(sample)

  @Test func `perfect read takes the script spelling and the voice timing`() {
    let timings = Aligner.align(script: script, heard: heard("hey friends we shipped the new camera today and honestly it changes everything"))
    #expect(timings.map(\.text) == script.map(\.text))
    #expect(timings.allSatisfy { $0.source == .script })
    #expect(abs(timings[3].start - 0.9) < 0.0001)
  }

  @Test func `ad-libs keep the recognizer's words in place`() {
    let timings = Aligner.align(script: script, heard: heard("hey friends so we shipped the new camera today and honestly it changes everything"))
    #expect(timings.count == script.count + 1)
    #expect(timings[2].text == "so")
    #expect(timings[2].source == .adlib)
    #expect(timings[3].text == "We")
  }

  @Test func `a word the recognizer missed is interpolated`() {
    var words = heard("hey friends we shipped the new camera today and honestly it changes everything")
    words.remove(at: 4)  // "the"
    let timings = Aligner.align(script: script, heard: words)
    let the = try! #require(timings.first { $0.text == "the" })
    #expect(the.source == .interpolated)
    #expect(the.start >= timings[3].end && the.end <= timings[5].start)
  }

  @Test func `a skipped sentence is dropped, not invented`() {
    let script = ScriptText.words("Hey friends. This part I will skip because it is long and boring. We shipped it.")
    var words = heard("hey friends")
    words += heard("we shipped it", from: 1.0)
    let timings = Aligner.align(script: script, heard: words)
    #expect(timings.map(\.text) == ["Hey", "friends.", "We", "shipped", "it."])
  }

  @Test func `misheard words still anchor to the script`() {
    let timings = Aligner.align(script: script, heard: heard("hey friends we shipped the new camara today and honestly it changes everything"))
    #expect(timings[6].text == "camera")
    #expect(timings[6].source == .script)
  }

  @Test func `estimates spread the script across the take`() {
    let timings = Aligner.estimate(script: script, duration: 6)
    #expect(timings.count == script.count)
    #expect(timings.first!.start == 0.3)
    #expect(timings.last!.end <= 6)
    #expect(zip(timings, timings.dropFirst()).allSatisfy { $0.end <= $1.start })
  }
}

@Suite struct PagerTests {
  let timings = Aligner.align(script: ScriptText.words(sample), heard: heard("hey friends we shipped the new camera today and honestly it changes everything"))

  @Test(arguments: CaptionStyleID.allCases)
  func `pages respect the style's limits and never overlap`(style: CaptionStyleID) {
    let rules = style.pagingRules
    let pages = CaptionPager.pages(timings, rules: rules)
    #expect(pages.flatMap(\.words) == timings)
    for page in pages {
      #expect(page.words.count <= rules.maxWords)
      #expect(page.end > page.start)
    }
    for (a, b) in zip(pages, pages.dropFirst()) {
      #expect(a.end <= b.start)
    }
  }

  @Test func `sentences end a page`() {
    let pages = CaptionPager.pages(timings, rules: CaptionStyleID.pro.pagingRules)
    #expect(pages[0].text == "Hey friends.")
  }

  @Test func `a pause starts a new page`() {
    var words = heard("one two three four")
    words[2].start += 1
    words[3].start += 1
    let timings = Aligner.align(script: ScriptText.words("one two three four"), heard: words)
    let pages = CaptionPager.pages(timings, rules: CaptionStyleID.pro.pagingRules)
    #expect(pages.map(\.text) == ["one two", "three four"])
  }
}

@Suite struct SubtitleTests {
  @Test func `srt numbers cues and uses comma milliseconds`() {
    let pages = [
      CaptionPage(words: [WordTiming(text: "Hey", start: 0.25, end: 0.5, source: .script)], start: 0.25, end: 1.5),
      CaptionPage(words: [WordTiming(text: "there.", start: 61.2, end: 61.5, source: .script)], start: 61.2, end: 62),
    ]
    #expect(
      Subtitles.render(pages, as: .srt)
        == "1\n00:00:00,250 --> 00:00:01,500\nHey\n\n2\n00:01:01,200 --> 00:01:02,000\nthere.\n")
    #expect(Subtitles.render(pages, as: .vtt).hasPrefix("WEBVTT\n\n00:00:00.250 --> 00:00:01.500\nHey\n"))
  }
}
