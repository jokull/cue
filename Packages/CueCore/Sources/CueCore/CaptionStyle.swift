import CoreGraphics
import Foundation

/// The three caption looks. Each one fixes typography, paging and how the spoken word is marked.
public enum CaptionStyleID: String, CaseIterable, Codable, Sendable, Identifiable {
  /// Big rounded caps, 1–3 words, the spoken word pops on a colored pill. TikTok/Reels.
  case fun
  /// Clean sans in the lower third; spoken words brighten. LinkedIn, launches.
  case pro
  /// New York serif; the spoken word turns italic. Interviews, essays, short films.
  case serif

  public var id: String { rawValue }

  public var displayName: String {
    switch self {
    case .fun: "Fun"
    case .pro: "Pro"
    case .serif: "Serif"
    }
  }
}

public enum CaptionPosition: String, CaseIterable, Codable, Sendable {
  case top, middle, bottom
}

public enum CaptionSize: String, CaseIterable, Codable, Sendable {
  case small, medium, large

  var scale: CGFloat {
    switch self {
    case .small: 0.82
    case .medium: 1
    case .large: 1.2
    }
  }
}

/// An sRGB color that survives Codable and crosses concurrency boundaries.
public struct CaptionColor: Hashable, Codable, Sendable {
  public var red, green, blue, alpha: Double

  public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
    self.red = red
    self.green = green
    self.blue = blue
    self.alpha = alpha
  }

  public init(hex: UInt32, alpha: Double = 1) {
    self.init(
      red: Double((hex >> 16) & 0xFF) / 255,
      green: Double((hex >> 8) & 0xFF) / 255,
      blue: Double(hex & 0xFF) / 255,
      alpha: alpha
    )
  }

  public var cgColor: CGColor {
    CGColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
  }

  public func withAlpha(_ alpha: Double) -> CaptionColor {
    CaptionColor(red: red, green: green, blue: blue, alpha: alpha)
  }

  public static let white = CaptionColor(hex: 0xFFFFFF)
  public static let black = CaptionColor(hex: 0x000000)

  /// The accent swatches offered in the style picker.
  public static let accents: [CaptionColor] = [
    CaptionColor(hex: 0xFF3B30),  // red, matches the record button
    CaptionColor(hex: 0xFFD60A),  // yellow
    CaptionColor(hex: 0x30D158),  // green
    CaptionColor(hex: 0x0A84FF),  // blue
    CaptionColor(hex: 0xBF5AF2),  // purple
  ]
}

/// The user's caption choices for a take. Saved with the take; never baked into the original.
public struct CaptionSettings: Hashable, Codable, Sendable {
  public var style: CaptionStyleID = .fun
  public var accent: CaptionColor = CaptionColor.accents[1]
  public var size: CaptionSize = .medium
  public var position: CaptionPosition?
  /// Off means plain captions with no per-word highlight.
  public var highlightsWords = true

  public init(style: CaptionStyleID = .fun) {
    self.style = style
  }

  public var resolvedPosition: CaptionPosition { position ?? style.defaultPosition }
}

extension CaptionStyleID {
  public var defaultPosition: CaptionPosition {
    switch self {
    case .fun: .middle
    case .pro, .serif: .bottom
    }
  }

  public var pagingRules: PagingRules {
    switch self {
    case .fun: PagingRules(maxWords: 3, maxCharacters: 18, maxDuration: 1.6)
    case .pro: PagingRules(maxWords: 12, maxCharacters: 64, maxDuration: 3.2)
    case .serif: PagingRules(maxWords: 9, maxCharacters: 48, maxDuration: 3.0)
    }
  }

  /// Font size as a fraction of the shorter side of the video.
  var fontScale: CGFloat {
    switch self {
    case .fun: 0.095
    case .pro: 0.05
    case .serif: 0.058
    }
  }

  /// Longest line as a fraction of the video width.
  var maxLineWidth: CGFloat {
    switch self {
    case .fun: 0.86
    case .pro: 0.82
    case .serif: 0.78
    }
  }

  var uppercased: Bool { self == .fun }
}
