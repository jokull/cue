import CoreText
import Foundation

#if canImport(UIKit)
  import UIKit
  typealias PlatformFont = UIFont
#else
  import AppKit
  typealias PlatformFont = NSFont
#endif

enum CaptionFonts {
  /// `variant` is the look of the word being spoken right now, where the style has one.
  static func font(for style: CaptionStyleID, size: CGFloat, variant: Bool = false) -> CTFont {
    switch style {
    case .fun:
      return system(size: size, weight: .black, design: .rounded, italic: false)
    case .pro:
      return system(size: size, weight: .semibold, design: .default, italic: false)
    case .serif:
      return system(size: size, weight: .regular, design: .serif, italic: variant)
    }
  }

  private static func system(
    size: CGFloat,
    weight: PlatformFont.Weight,
    design: PlatformFontDescriptor.SystemDesign,
    italic: Bool
  ) -> CTFont {
    let base = PlatformFont.systemFont(ofSize: size, weight: weight)
    var descriptor = base.fontDescriptor.withDesign(design) ?? base.fontDescriptor
    if italic {
      #if canImport(UIKit)
        descriptor = descriptor.withSymbolicTraits(.traitItalic) ?? descriptor
      #else
        descriptor = descriptor.withSymbolicTraits(.italic)
      #endif
    }
    #if canImport(UIKit)
      return UIFont(descriptor: descriptor, size: size) as CTFont
    #else
      return (NSFont(descriptor: descriptor, size: size) ?? base) as CTFont
    #endif
  }
}

#if canImport(UIKit)
  typealias PlatformFontDescriptor = UIFontDescriptor
#else
  typealias PlatformFontDescriptor = NSFontDescriptor
#endif
