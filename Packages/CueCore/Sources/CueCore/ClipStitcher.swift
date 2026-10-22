import AVFoundation

/// Joins a take's clips into one movie, in order, without re-encoding: every clip comes from
/// the same camera session, so the samples can be passed straight through.
public enum ClipStitcher {
  public enum Failure: Error {
    case empty, cannotExport
  }

  public static func stitch(_ urls: [URL], to destination: URL) async throws -> TimeInterval {
    guard !urls.isEmpty else { throw Failure.empty }
    let composition = AVMutableComposition()
    let video = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
    let audio = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
    var cursor = CMTime.zero
    for url in urls {
      let asset = AVURLAsset(url: url)
      let duration = try await asset.load(.duration)
      let range = CMTimeRange(start: .zero, duration: duration)
      if let track = try await asset.loadTracks(withMediaType: .video).first {
        try video?.insertTimeRange(range, of: track, at: cursor)
        if cursor == .zero { video?.preferredTransform = try await track.load(.preferredTransform) }
      }
      if let track = try await asset.loadTracks(withMediaType: .audio).first {
        try audio?.insertTimeRange(range, of: track, at: cursor)
      }
      cursor = cursor + duration
    }
    guard let session = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough) else {
      throw Failure.cannotExport
    }
    try? FileManager.default.removeItem(at: destination)
    try await session.export(to: destination, as: .mp4)
    return cursor.seconds
  }
}
