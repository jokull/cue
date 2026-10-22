import AVFoundation
import QuartzCore

/// Writes a new video file from a take: cropped to a social aspect ratio, with or without
/// captions burned in. The take itself is never modified.
public enum CaptionExporter {
  public enum Aspect: String, CaseIterable, Codable, Sendable, Identifiable {
    case original, portrait, fourByFive, square, landscape

    public var id: String { rawValue }

    public var label: String {
      switch self {
      case .original: "Original"
      case .portrait: "9:16"
      case .fourByFive: "4:5"
      case .square: "1:1"
      case .landscape: "16:9"
      }
    }

    /// Width over height, or nil to keep the source's.
    var ratio: CGFloat? {
      switch self {
      case .original: nil
      case .portrait: 9.0 / 16.0
      case .fourByFive: 4.0 / 5.0
      case .square: 1
      case .landscape: 16.0 / 9.0
      }
    }
  }

  public enum Quality: String, CaseIterable, Codable, Sendable {
    case hd, uhd

    public var label: String { self == .hd ? "1080p" : "4K" }

    var shortSide: CGFloat { self == .hd ? 1080 : 2160 }
  }

  public enum Codec: String, CaseIterable, Codable, Sendable {
    case hevc, h264

    public var label: String { self == .hevc ? "HEVC" : "H.264" }

    var preset: String {
      self == .hevc ? AVAssetExportPresetHEVCHighestQuality : AVAssetExportPresetHighestQuality
    }
  }

  public struct Request: Sendable {
    public var source: URL
    public var destination: URL
    public var aspect: Aspect = .original
    public var quality: Quality = .hd
    public var codec: Codec = .hevc
    /// Captions to burn in, or nil for a clean export.
    public var captions: (timings: [WordTiming], settings: CaptionSettings)?
    /// Where to center a crop horizontally, 0…1 of the frame width. Usually the speaker's face.
    public var focusX: CGFloat = 0.5

    public init(source: URL, destination: URL) {
      self.source = source
      self.destination = destination
    }
  }

  public enum Failure: Error {
    case noVideoTrack
    case cannotCreateSession
  }

  public static func export(_ request: Request, progress: (@Sendable (Double) -> Void)? = nil) async throws {
    let asset = AVURLAsset(url: request.source)
    guard let sourceVideo = try await asset.loadTracks(withMediaType: .video).first else {
      throw Failure.noVideoTrack
    }
    let duration = try await asset.load(.duration)
    let (naturalSize, preferredTransform, frameRate) = try await sourceVideo.load(
      .naturalSize, .preferredTransform, .nominalFrameRate)
    let range = CMTimeRange(start: .zero, duration: duration)

    let composition = AVMutableComposition()
    guard
      let videoTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
    else { throw Failure.noVideoTrack }
    try videoTrack.insertTimeRange(range, of: sourceVideo, at: .zero)
    for sourceAudio in try await asset.loadTracks(withMediaType: .audio) {
      let audioTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
      try audioTrack?.insertTimeRange(range, of: sourceAudio, at: .zero)
    }

    let geometry = Geometry(
      naturalSize: naturalSize,
      preferredTransform: preferredTransform,
      aspect: request.aspect,
      quality: request.quality,
      focusX: request.focusX
    )

    var layerInstruction = AVVideoCompositionLayerInstruction.Configuration(assetTrack: videoTrack)
    layerInstruction.setTransform(geometry.transform, at: .zero)
    let instruction = AVVideoCompositionInstruction.Configuration(
      layerInstructions: [AVVideoCompositionLayerInstruction(configuration: layerInstruction)],
      timeRange: range
    )

    var configuration = AVVideoComposition.Configuration()
    configuration.renderSize = geometry.renderSize
    configuration.frameDuration = CMTime(value: 1, timescale: CMTimeScale(frameRate > 0 ? frameRate.rounded() : 30))
    configuration.instructions = [AVVideoCompositionInstruction(configuration: instruction)]

    if let captions = request.captions {
      let parent = CALayer()
      parent.frame = CGRect(origin: .zero, size: geometry.renderSize)
      let video = CALayer()
      video.frame = parent.frame
      parent.addSublayer(video)
      let pages = CaptionLayerBuilder.pages(for: captions.timings, settings: captions.settings)
      parent.addSublayer(
        CaptionLayerBuilder.makeLayer(
          pages: pages,
          settings: captions.settings,
          options: .init(renderSize: geometry.renderSize, duration: duration.seconds, flipped: true)
        ))
      configuration.animationTool = AVVideoCompositionCoreAnimationTool(
        postProcessingAsVideoLayer: video, in: parent)
    }
    let videoComposition = AVVideoComposition(configuration: configuration)

    guard let session = AVAssetExportSession(asset: composition, presetName: request.codec.preset) else {
      throw Failure.cannotCreateSession
    }
    session.videoComposition = videoComposition
    try? FileManager.default.removeItem(at: request.destination)

    let states = session.states(updateInterval: 0.1)
    let reporter = Task {
      guard let progress else { return }
      for await state in states {
        if case .exporting(let fraction) = state { progress(fraction.fractionCompleted) }
      }
    }
    defer { reporter.cancel() }
    try await session.export(to: request.destination, as: .mp4)
    progress?(1)
  }

  /// Orientation, crop and scale for a source frame into the export frame.
  struct Geometry {
    let renderSize: CGSize
    let transform: CGAffineTransform

    init(naturalSize: CGSize, preferredTransform: CGAffineTransform, aspect: Aspect, quality: Quality, focusX: CGFloat) {
      let oriented = CGRect(origin: .zero, size: naturalSize).applying(preferredTransform)
      let upright = CGSize(width: abs(oriented.width), height: abs(oriented.height))

      var crop = CGRect(origin: .zero, size: upright)
      if let ratio = aspect.ratio {
        if upright.width / upright.height > ratio {
          crop.size.width = upright.height * ratio
          let centered = upright.width * focusX - crop.width / 2
          crop.origin.x = min(max(centered, 0), upright.width - crop.width)
        } else {
          crop.size.height = upright.width / ratio
          crop.origin.y = (upright.height - crop.height) / 2
        }
      }

      // Downscale to the chosen quality; never upscale.
      let scale = min(1, quality.shortSide / min(crop.width, crop.height))
      func even(_ value: CGFloat) -> CGFloat { (value * scale / 2).rounded() * 2 }
      renderSize = CGSize(width: even(crop.width), height: even(crop.height))

      // preferredTransform can leave the frame at negative coordinates; move it back first.
      transform =
        preferredTransform
        .concatenating(CGAffineTransform(translationX: -oriented.minX - crop.minX, y: -oriented.minY - crop.minY))
        .concatenating(CGAffineTransform(scaleX: scale, y: scale))
    }
  }
}
