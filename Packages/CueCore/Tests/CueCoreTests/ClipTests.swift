import AVFoundation
import Foundation
import Testing

@testable import CueCore

@Suite struct ClipSequenceTests {
  func clip(_ seconds: Double, _ range: Range<Int>) -> Clip {
    Clip(url: URL(filePath: "/tmp/\(UUID()).mp4"), duration: seconds, scriptRange: range)
  }

  @Test func `adds at the end, or right after the selected clip`() {
    var sequence = ClipSequence()
    let a = clip(5, 0..<10), b = clip(5, 10..<20), c = clip(5, 20..<30)
    sequence.add(a)
    sequence.add(c)
    sequence.add(b, after: a.id)
    #expect(sequence.clips.map(\.id) == [a.id, b.id, c.id])
    #expect(sequence.duration == 15)
  }

  @Test func `a retake takes the old clip's place`() {
    var sequence = ClipSequence(clips: [clip(5, 0..<10), clip(5, 10..<20)])
    let old = sequence.clips[1]
    let retake = clip(4, 10..<20)
    #expect(sequence.replace(old.id, with: retake) == old)
    #expect(sequence.clips[1] == retake)
  }

  @Test func `moves before another clip or to the end`() {
    let a = clip(1, 0..<1), b = clip(1, 1..<2), c = clip(1, 2..<3)
    var sequence = ClipSequence(clips: [a, b, c])
    sequence.move(c.id, before: a.id)
    #expect(sequence.clips.map(\.id) == [c.id, a.id, b.id])
    sequence.move(c.id, before: nil)
    #expect(sequence.clips.map(\.id) == [a.id, b.id, c.id])
  }

  @Test func `delete can be undone in place`() {
    let a = clip(1, 0..<1), b = clip(1, 1..<2), c = clip(1, 2..<3)
    var sequence = ClipSequence(clips: [a, b, c])
    sequence.delete(b.id)
    #expect(sequence.clips.map(\.id) == [a.id, c.id])
    sequence.undoDelete()
    #expect(sequence.clips.map(\.id) == [a.id, b.id, c.id])
    #expect(sequence.deleted == nil)
  }

  @Test func `three minutes is the limit`() {
    var sequence = ClipSequence(clips: [clip(120, 0..<10), clip(59.8, 10..<20)])
    #expect(sequence.isFull)
    sequence.delete(sequence.clips[1].id)
    #expect(sequence.remaining == 60)
  }

  @Test func `skipped lines show up as gaps, in reading order`() {
    // Recorded out of order, with words 20–29 never read.
    let sequence = ClipSequence(clips: [clip(5, 30..<40), clip(5, 0..<20), clip(1, 19..<21)])
    #expect(sequence.gaps() == [21..<30])
  }

  @Test func `recording over covered lines is a likely retake`() {
    let sequence = ClipSequence(clips: [clip(5, 0..<20), clip(5, 20..<40)])
    #expect(sequence.overlapping(18..<30).map(\.scriptRange) == [20..<40])
  }
}

@Suite struct RepositionTests {
  @Test func `the tracker can be moved back for a retake`() {
    var tracker = ScriptTracker(words: ScriptText.words(sample))
    tracker.update(transcript: "hey friends we shipped the new camera")
    tracker.reposition(to: 2)
    #expect(tracker.cursor == 2)
    tracker.update(transcript: "we shipped the")
    #expect(tracker.cursor == 5)
  }

  @Test func `pace restarts from the new place and keeps the reader's rate`() {
    var pace = ReadingPace()
    pace.reset(to: 12)
    #expect(pace.position == 12)
    pace.tick(at: 0, speaking: true)
    pace.tick(at: 1, speaking: true)
    #expect(pace.position > 12 && pace.position <= 18)
  }
}

@Suite(.serialized) struct StitchTests {
  @Test func `clips join end to end without re-encoding`() async throws {
    let fixture = try #require(Bundle.module.url(forResource: "portrait", withExtension: "mp4", subdirectory: "Fixtures"))
    let out = FileManager.default.temporaryDirectory.appending(path: "cue-stitched.mp4")
    let duration = try await ClipStitcher.stitch([fixture, fixture, fixture], to: out)
    #expect(abs(duration - 18) < 0.2)
    let asset = AVURLAsset(url: out)
    #expect(abs(try await asset.load(.duration).seconds - 18) < 0.3)
    #expect(try await asset.loadTracks(withMediaType: .audio).count == 1)
  }
}
