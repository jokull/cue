import AVFoundation
import Vision

/// Finds where the speaker sits in the frame, so aspect crops keep their face in shot.
public enum FaceFocus {
  /// The horizontal center of the largest face in a few sampled frames, 0…1 of the upright
  /// frame width. Nil when no face is found.
  public static func horizontalCenter(of url: URL) async -> CGFloat? {
    let asset = AVURLAsset(url: url)
    guard let duration = try? await asset.load(.duration), duration.seconds > 0 else { return nil }
    let generator = AVAssetImageGenerator(asset: asset)
    generator.appliesPreferredTrackTransform = true
    generator.maximumSize = CGSize(width: 640, height: 640)

    var centers: [CGFloat] = []
    for fraction in [0.2, 0.5, 0.8] {
      let time = CMTime(seconds: duration.seconds * fraction, preferredTimescale: 600)
      guard let image = try? await generator.image(at: time).image else { continue }
      let request = DetectFaceRectanglesRequest()
      guard let faces = try? await request.perform(on: image),
        let largest = faces.max(by: { $0.boundingBox.width < $1.boundingBox.width })
      else { continue }
      centers.append(largest.boundingBox.cgRect.midX)
    }
    guard !centers.isEmpty else { return nil }
    return centers.sorted()[centers.count / 2]
  }
}
