import AVFoundation
import Foundation
import QuartzCore
import Testing

@testable import CueCore

@Suite struct TrackTests {
  @Test func `key times strictly increase and span the take`() {
    var track = Track(initial: 0)
    track.ramp(to: 1, at: 1, over: 0.1)
    track.step(to: 0, at: 1.05)  // lands inside the previous ramp
    track.step(to: 1, at: 3)
    let animation = track.animation("opacity", duration: 4)
    let times = animation.keyTimes!.map(\.doubleValue)
    #expect(times.first == 0)
    #expect(times.last == 1)
    #expect(zip(times, times.dropFirst()).allSatisfy { $0 < $1 })
    #expect(animation.values!.count == times.count)
    #expect(animation.beginTime == AVCoreAnimationBeginTimeAtZero)
  }
}

@Suite struct LayerBuilderTests {
  let timings = Aligner.align(
    script: ScriptText.words(sample),
    heard: heard("hey friends we shipped the new camera today and honestly it changes everything", from: 0.4))

  @Test(arguments: CaptionStyleID.allCases)
  func `builds one layer per page with words inside the frame`(style: CaptionStyleID) {
    let settings = CaptionSettings(style: style)
    let size = CGSize(width: 1080, height: 1920)
    let pages = CaptionLayerBuilder.pages(for: timings, settings: settings)
    let root = CaptionLayerBuilder.makeLayer(pages: pages, settings: settings, options: .init(renderSize: size, duration: 5))
    #expect(root.sublayers?.count == pages.count)
    for page in root.sublayers ?? [] {
      #expect(CGRect(origin: .zero, size: size).insetBy(dx: -20, dy: -20).contains(page.frame))
      #expect(page.animation(forKey: "visibility") != nil)
    }
  }

  @Test func `turning highlights off leaves only plain words`() {
    var settings = CaptionSettings(style: .fun)
    settings.highlightsWords = false
    let pages = CaptionLayerBuilder.pages(for: timings, settings: settings)
    let root = CaptionLayerBuilder.makeLayer(pages: pages, settings: settings, options: .init(renderSize: CGSize(width: 1080, height: 1920), duration: 5))
    let words = root.sublayers!.flatMap { $0.sublayers ?? [] }
    #expect(words.allSatisfy { $0.sublayers?.count == 1 })
  }

  @Test func `long lines wrap inside the style's width`() {
    let layout = CaptionLayerBuilder.Layout(settings: CaptionSettings(style: .pro), renderSize: CGSize(width: 720, height: 1280))
    let frames = layout.frames(for: timings)
    #expect(Set(frames.map(\.minY)).count > 1)
    #expect(frames.allSatisfy { $0.maxX <= 720 * 0.92 && $0.minX >= 720 * 0.08 })
  }
}

@Suite struct GeometryTests {
  typealias Geometry = CaptionExporter.Geometry

  @Test func `square crop of a portrait take keeps the full width`() {
    let geometry = Geometry(naturalSize: CGSize(width: 1080, height: 1920), preferredTransform: .identity, aspect: .square, quality: .hd, focusX: 0.5)
    #expect(geometry.renderSize == CGSize(width: 1080, height: 1080))
    #expect(geometry.transform.ty == -420)
  }

  @Test func `landscape crop follows the face but stays in frame`() {
    let geometry = Geometry(naturalSize: CGSize(width: 1920, height: 1080), preferredTransform: .identity, aspect: .portrait, quality: .hd, focusX: 0.95)
    #expect(geometry.renderSize == CGSize(width: 608, height: 1080))
    #expect(abs(geometry.transform.tx + (1920 - 607.5)) < 0.001)
  }

  @Test func `rotated camera buffers come out upright`() {
    // Back-camera style: landscape buffers with a 90° preferred transform.
    let rotate = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 1080, ty: 0)
    let geometry = Geometry(naturalSize: CGSize(width: 1920, height: 1080), preferredTransform: rotate, aspect: .original, quality: .hd, focusX: 0.5)
    #expect(geometry.renderSize == CGSize(width: 1080, height: 1920))
    let corner = CGPoint(x: 1920, y: 1080).applying(geometry.transform)
    #expect(corner == CGPoint(x: 0, y: 1920))
  }

  @Test func `never upscales a small source`() {
    let geometry = Geometry(naturalSize: CGSize(width: 720, height: 1280), preferredTransform: .identity, aspect: .original, quality: .uhd, focusX: 0.5)
    #expect(geometry.renderSize == CGSize(width: 720, height: 1280))
  }
}

@Suite(.serialized) struct ExportTests {
  let fixture = Bundle.module.url(forResource: "portrait", withExtension: "mp4", subdirectory: "Fixtures")!

  /// Set CUE_EXPORT_DIR to keep the exports and look at them.
  var outputDirectory: URL {
    if let path = ProcessInfo.processInfo.environment["CUE_EXPORT_DIR"] {
      return URL(filePath: path, directoryHint: .isDirectory)
    }
    return FileManager.default.temporaryDirectory
  }

  @Test(arguments: CaptionStyleID.allCases)
  func `burns captions into a cropped export`(style: CaptionStyleID) async throws {
    let script = ScriptText.words(sample)
    let timings = Aligner.estimate(script: script, duration: 6)
    var request = CaptionExporter.Request(source: fixture, destination: outputDirectory.appending(path: "cue-\(style.rawValue).mp4"))
    request.aspect = style == .serif ? .square : .original
    request.captions = (timings, CaptionSettings(style: style))
    try await CaptionExporter.export(request)

    let output = AVURLAsset(url: request.destination)
    let duration = try await output.load(.duration).seconds
    #expect(abs(duration - 6) < 0.2)
    let track = try #require(try await output.loadTracks(withMediaType: .video).first)
    let size = try await track.load(.naturalSize)
    #expect(size == (style == .serif ? CGSize(width: 720, height: 720) : CGSize(width: 720, height: 1280)))
    #expect(try await output.loadTracks(withMediaType: .audio).count == 1)

    let generator = AVAssetImageGenerator(asset: output)
    _ = try await generator.image(at: CMTime(seconds: 3, preferredTimescale: 600))
  }

  @Test func `exports clean without captions`() async throws {
    let request = CaptionExporter.Request(source: fixture, destination: outputDirectory.appending(path: "cue-clean.mp4"))
    try await CaptionExporter.export(request)
    #expect(FileManager.default.fileExists(atPath: request.destination.path()))
  }
}

@Suite struct CaptionPlacementTests {
  let timings = Aligner.estimate(script: ScriptText.words(sample), duration: 6)
  let size = CGSize(width: 1080, height: 1920)

  func blockCenter(_ settings: CaptionSettings) -> CGFloat {
    let frames = CaptionLayerBuilder.Layout(settings: settings, renderSize: size).frames(for: Array(timings.prefix(3)))
    let block = frames.reduce(CGRect.null) { $0.union($1) }
    return block.midY / size.height
  }

  @Test(arguments: CaptionStyleID.allCases)
  func `captions sit 70% down by default`(style: CaptionStyleID) {
    #expect(abs(blockCenter(CaptionSettings(style: style)) - 0.70) < 0.01)
  }

  @Test func `a dragged position is honoured`() {
    var settings = CaptionSettings(style: .pro)
    settings.verticalPosition = 0.35
    #expect(abs(blockCenter(settings) - 0.35) < 0.01)
  }

  @Test(arguments: [0.0, 1.0])
  func `the block never leaves the frame`(fraction: Double) {
    var settings = CaptionSettings(style: .fun)
    settings.size = .large
    settings.verticalPosition = fraction
    let frames = CaptionLayerBuilder.Layout(settings: settings, renderSize: size).frames(for: timings)
    let block = frames.reduce(CGRect.null) { $0.union($1) }
    #expect(block.minY >= size.height * 0.04 - 0.5)
    #expect(block.maxY <= size.height * 0.96 + 0.5)
  }

  @Test func `older takes keep their preset position`() throws {
    let saved = #"{"style":"serif","accent":{"red":1,"green":0.84,"blue":0.04,"alpha":1},"size":"medium","position":"top","highlightsWords":true}"#
    let settings = try JSONDecoder().decode(CaptionSettings.self, from: Data(saved.utf8))
    #expect(settings.resolvedVerticalPosition == 0.2)
  }
}
