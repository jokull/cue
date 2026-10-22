import Foundation

/// One hold of the record button.
public struct Clip: Identifiable, Hashable, Sendable {
  public let id: UUID
  public var url: URL
  public var duration: TimeInterval
  /// The script words this clip covers, as far as voice tracking could tell.
  public var scriptRange: Range<Int>

  public init(id: UUID = UUID(), url: URL, duration: TimeInterval, scriptRange: Range<Int>) {
    self.id = id
    self.url = url
    self.duration = duration
    self.scriptRange = scriptRange
  }
}

/// The clips of a take being built: the rules of the editor tray, independent of any UI.
public struct ClipSequence: Sendable {
  public static let maxDuration: TimeInterval = 180

  public private(set) var clips: [Clip] = []
  /// The last deletion, for undo: the clip and where it was.
  public private(set) var deleted: (clip: Clip, index: Int)?

  public init(clips: [Clip] = []) {
    self.clips = clips
  }

  public var duration: TimeInterval { clips.reduce(0) { $0 + $1.duration } }
  public var remaining: TimeInterval { max(0, Self.maxDuration - duration) }
  public var isFull: Bool { remaining < 0.5 }
  public var isEmpty: Bool { clips.isEmpty }

  /// Adds a clip at the end, or right after `after`.
  public mutating func add(_ clip: Clip, after: Clip.ID? = nil) {
    if let after, let index = clips.firstIndex(where: { $0.id == after }) {
      clips.insert(clip, at: index + 1)
    } else {
      clips.append(clip)
    }
  }

  /// A retake: the new clip takes the old one's place. Returns the replaced clip.
  @discardableResult
  public mutating func replace(_ id: Clip.ID, with clip: Clip) -> Clip? {
    guard let index = clips.firstIndex(where: { $0.id == id }) else { return nil }
    let old = clips[index]
    clips[index] = clip
    return old
  }

  /// Moves a clip to sit where `before` is now (or to the end).
  public mutating func move(_ id: Clip.ID, before: Clip.ID?) {
    guard let from = clips.firstIndex(where: { $0.id == id }), id != before else { return }
    let clip = clips.remove(at: from)
    if let before, let to = clips.firstIndex(where: { $0.id == before }) {
      clips.insert(clip, at: to)
    } else {
      clips.append(clip)
    }
  }

  @discardableResult
  public mutating func delete(_ id: Clip.ID) -> Clip? {
    guard let index = clips.firstIndex(where: { $0.id == id }) else { return nil }
    let clip = clips.remove(at: index)
    deleted = (clip, index)
    return clip
  }

  public mutating func undoDelete() {
    guard let deleted else { return }
    clips.insert(deleted.clip, at: min(deleted.index, clips.count))
    self.deleted = nil
  }

  /// Forgets the undo slot (the deleted file may now be removed).
  public mutating func commitDelete() -> Clip? {
    defer { deleted = nil }
    return deleted?.clip
  }

  /// Script stretches that fall between clips in reading order: lines the reader skipped.
  /// Gaps shorter than `minimum` words are ignored (tracking is fuzzy at clip edges).
  public func gaps(minimum: Int = 4) -> [Range<Int>] {
    let covered = clips.map(\.scriptRange).filter { !$0.isEmpty }.sorted { $0.lowerBound < $1.lowerBound }
    var gaps: [Range<Int>] = []
    var reached: Int?
    for range in covered {
      if let reached, range.lowerBound - reached >= minimum {
        gaps.append(reached..<range.lowerBound)
      }
      reached = max(reached ?? range.upperBound, range.upperBound)
    }
    return gaps
  }

  /// Clips whose script ranges overlap `range` — a new recording over them is a likely retake.
  public func overlapping(_ range: Range<Int>, minimum: Int = 4) -> [Clip] {
    clips.filter { $0.scriptRange.clamped(to: range).count >= minimum }
  }
}
