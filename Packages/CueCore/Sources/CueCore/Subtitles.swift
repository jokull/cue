import Foundation

/// Sidecar subtitle files, for platforms that want captions as a track instead of burned in.
public enum Subtitles {
  public enum Format: String, CaseIterable, Sendable {
    case srt, vtt

    public var fileExtension: String { rawValue }
  }

  public static func render(_ pages: [CaptionPage], as format: Format) -> String {
    switch format {
    case .srt:
      pages.enumerated().map { index, page in
        "\(index + 1)\n\(timestamp(page.start, separator: ",")) --> \(timestamp(page.end, separator: ","))\n\(page.text)\n"
      }.joined(separator: "\n")
    case .vtt:
      "WEBVTT\n\n"
        + pages.map { page in
          "\(timestamp(page.start, separator: ".")) --> \(timestamp(page.end, separator: "."))\n\(page.text)\n"
        }.joined(separator: "\n")
    }
  }

  static func timestamp(_ seconds: TimeInterval, separator: String) -> String {
    let milliseconds = Int((max(0, seconds) * 1000).rounded())
    let h = milliseconds / 3_600_000
    let m = milliseconds / 60_000 % 60
    let s = milliseconds / 1000 % 60
    let ms = milliseconds % 1000
    return String(format: "%02d:%02d:%02d%@%03d", h, m, s, separator, ms)
  }
}
