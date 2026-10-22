import AVFoundation
import CoreText
import QuartzCore

/// Builds the caption overlay for a take as a Core Animation layer tree.
///
/// Every animation is keyed to the media timeline (`AVCoreAnimationBeginTimeAtZero`), so the
/// same tree plays inside an `AVSynchronizedLayer` for preview and renders through
/// `AVVideoCompositionCoreAnimationTool` for export. A layer can only live in one tree:
/// build a fresh one for each.
public enum CaptionLayerBuilder {
  public struct Options: Sendable {
    public var renderSize: CGSize
    public var duration: TimeInterval
    /// 1 for export (render size is already in pixels); the screen scale for preview.
    public var contentsScale: CGFloat
    /// Export composites in a bottom-left coordinate space; preview in UIKit is top-left.
    public var flipped: Bool

    public init(renderSize: CGSize, duration: TimeInterval, contentsScale: CGFloat = 1, flipped: Bool = false) {
      self.renderSize = renderSize
      self.duration = duration
      self.contentsScale = contentsScale
      self.flipped = flipped
    }
  }

  public static func makeLayer(pages: [CaptionPage], settings: CaptionSettings, options: Options) -> CALayer {
    let root = CALayer()
    root.frame = CGRect(origin: .zero, size: options.renderSize)
    root.isGeometryFlipped = options.flipped
    root.masksToBounds = true
    let duration = max(options.duration, pages.last?.end ?? 0, 0.1)
    let layout = Layout(settings: settings, renderSize: options.renderSize)
    for page in pages {
      root.addSublayer(pageLayer(page, layout: layout, settings: settings, duration: duration, scale: options.contentsScale))
    }
    return root
  }

  /// The pages for a set of timings under the chosen style.
  public static func pages(for timings: [WordTiming], settings: CaptionSettings) -> [CaptionPage] {
    CaptionPager.pages(timings, rules: settings.style.pagingRules)
  }

  // MARK: - Layout

  struct Layout {
    let style: CaptionStyleID
    let font: CTFont
    let variantFont: CTFont
    let fontSize: CGFloat
    let renderSize: CGSize
    let lineHeight: CGFloat
    let spaceWidth: CGFloat
    let maxLineWidth: CGFloat
    let centerY: CGFloat

    init(settings: CaptionSettings, renderSize: CGSize) {
      style = settings.style
      let shortSide = min(renderSize.width, renderSize.height)
      fontSize = (shortSide * settings.style.fontScale * settings.size.scale).rounded()
      font = CaptionFonts.font(for: style, size: fontSize)
      variantFont = CaptionFonts.font(for: style, size: fontSize, variant: true)
      self.renderSize = renderSize
      lineHeight = (CTFontGetAscent(font) + CTFontGetDescent(font)) * (style == .fun ? 1.02 : 1.18)
      // Fun needs room for the pill and the pop on either side of each word.
      spaceWidth = CTFontGetSize(font) * (style == .fun ? 0.48 : 0.28)
      maxLineWidth = renderSize.width * style.maxLineWidth
      centerY =
        switch settings.resolvedPosition {
        case .top: renderSize.height * 0.2
        case .middle: renderSize.height * 0.5
        case .bottom: renderSize.height * (style == .fun ? 0.74 : 0.82)
        }
    }

    func displayText(_ word: WordTiming) -> String {
      style.uppercased ? word.text.uppercased() : word.text
    }

    func width(of text: String, font: CTFont) -> CGFloat {
      let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [
        NSAttributedString.Key(kCTFontAttributeName as String): font
      ]))
      return CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
    }

    /// Word frames in render coordinates, wrapped greedily and centered line by line.
    func frames(for words: [WordTiming]) -> [CGRect] {
      let widths = words.map { word in
        // Reserve room for the wider of the two looks so the line doesn't jump.
        max(width(of: displayText(word), font: font), width(of: displayText(word), font: variantFont))
      }
      var lines: [[Int]] = [[]]
      var lineWidth: CGFloat = 0
      for (index, width) in widths.enumerated() {
        let added = lines[lines.count - 1].isEmpty ? width : lineWidth + spaceWidth + width
        if added > maxLineWidth, !lines[lines.count - 1].isEmpty {
          lines.append([index])
          lineWidth = width
        } else {
          lines[lines.count - 1].append(index)
          lineWidth = added
        }
      }

      let blockTop = centerY - lineHeight * CGFloat(lines.count) / 2
      var frames = Array(repeating: CGRect.zero, count: words.count)
      for (row, line) in lines.enumerated() {
        let total = line.map { widths[$0] }.reduce(0, +) + spaceWidth * CGFloat(max(line.count - 1, 0))
        var x = (renderSize.width - total) / 2
        let y = blockTop + lineHeight * CGFloat(row)
        for index in line {
          frames[index] = CGRect(x: x, y: y, width: widths[index], height: lineHeight)
          x += widths[index] + spaceWidth
        }
      }
      return frames
    }
  }

  // MARK: - Pages

  static func pageLayer(
    _ page: CaptionPage,
    layout: Layout,
    settings: CaptionSettings,
    duration: TimeInterval,
    scale: CGFloat
  ) -> CALayer {
    let frames = layout.frames(for: page.words)
    let pad = layout.fontSize * (layout.style == .pro ? 0.45 : 0.3)
    let block = frames.reduce(CGRect.null) { $0.union($1) }.insetBy(dx: -pad, dy: -pad * 0.6)

    let layer = CALayer()
    layer.frame = block
    let fadeIn: TimeInterval = layout.style == .serif ? 0.22 : layout.style == .pro ? 0.12 : 0.04
    let fadeOut: TimeInterval = layout.style == .serif ? 0.22 : 0.08
    var visibility = Track(initial: 0)
    visibility.ramp(to: 1, at: page.start, over: fadeIn)
    visibility.ramp(to: 0, at: page.end - fadeOut, over: fadeOut)
    layer.add(visibility.animation("opacity", duration: duration), forKey: "visibility")
    layer.opacity = 0

    switch layout.style {
    case .fun:
      // Each page pops in from slightly small, with a touch of overshoot.
      var pop = Track(initial: 0.82)
      pop.ramp(to: 1.06, at: page.start, over: 0.09)
      pop.ramp(to: 1, at: page.start + 0.09, over: 0.07)
      layer.add(pop.animation("transform.scale", duration: duration), forKey: "pop")
    case .pro:
      let backdrop = CALayer()
      backdrop.frame = CGRect(origin: .zero, size: block.size)
      backdrop.backgroundColor = CaptionColor.black.withAlpha(0.5).cgColor
      backdrop.cornerRadius = layout.fontSize * 0.35
      backdrop.cornerCurve = .continuous
      layer.addSublayer(backdrop)
    case .serif:
      break
    }

    for (index, word) in page.words.enumerated() {
      let next = index + 1 < page.words.count ? page.words[index + 1].start : page.end
      let active = (start: word.start, end: max(word.end, next))
      let frame = frames[index].offsetBy(dx: -block.minX, dy: -block.minY)
      layer.addSublayer(
        wordLayer(word, frame: frame, active: active, layout: layout, settings: settings, duration: duration, scale: scale)
      )
    }
    return layer
  }

  // MARK: - Words

  static func wordLayer(
    _ word: WordTiming,
    frame: CGRect,
    active: (start: TimeInterval, end: TimeInterval),
    layout: Layout,
    settings: CaptionSettings,
    duration: TimeInterval,
    scale: CGFloat
  ) -> CALayer {
    let container = CALayer()
    container.frame = frame
    let bounds = CGRect(origin: .zero, size: frame.size)
    let text = layout.displayText(word)
    let highlights = settings.highlightsWords

    switch layout.style {
    case .fun:
      let base = textLayer(text, font: layout.font, color: .white, stroke: true, frame: bounds, scale: scale)
      container.addSublayer(base)
      guard highlights else { break }

      let pill = CALayer()
      let inset = layout.fontSize * 0.14
      pill.frame = bounds.insetBy(dx: -layout.fontSize * 0.12, dy: inset)
      pill.backgroundColor = settings.accent.cgColor
      pill.cornerRadius = layout.fontSize * 0.18
      pill.cornerCurve = .continuous
      container.insertSublayer(pill, below: base)

      let ink: CaptionColor = settings.accent.prefersDarkText ? .black : .white
      let lit = textLayer(text, font: layout.font, color: ink, stroke: false, frame: bounds, scale: scale)
      container.addSublayer(lit)

      for layer in [pill, lit] {
        var on = Track(initial: 0)
        on.step(to: 1, at: active.start)
        on.step(to: 0, at: active.end)
        layer.add(on.animation("opacity", duration: duration), forKey: "active")
        layer.opacity = 0
      }
      var pop = Track(initial: 1)
      pop.ramp(to: 1.12, at: active.start, over: 0.06)
      pop.ramp(to: 1.07, at: active.start + 0.06, over: 0.06)
      pop.ramp(to: 1, at: active.end, over: 0.06)
      container.add(pop.animation("transform.scale", duration: duration), forKey: "pop")
      container.zPosition = 1

    case .pro:
      let base = textLayer(text, font: layout.font, color: .white, stroke: false, frame: bounds, scale: scale)
      container.addSublayer(base)
      guard highlights else { break }
      var spoken = Track(initial: 0.5)
      spoken.ramp(to: 1, at: word.start, over: 0.05)
      base.add(spoken.animation("opacity", duration: duration), forKey: "spoken")
      base.opacity = 0.5

    case .serif:
      let base = textLayer(text, font: layout.font, color: .white, stroke: false, frame: bounds, scale: scale)
      addShadow(base, layout: layout)
      container.addSublayer(base)
      guard highlights else { break }

      let italic = textLayer(text, font: layout.variantFont, color: settings.accent.softened, stroke: false, frame: bounds, scale: scale)
      addShadow(italic, layout: layout)
      container.addSublayer(italic)

      // Swap instantly: the two cuts differ in width, so a crossfade ghosts.
      var upright = Track(initial: 0.5)
      upright.step(to: 0, at: active.start)
      upright.step(to: 1, at: active.end)
      base.add(upright.animation("opacity", duration: duration), forKey: "upright")
      base.opacity = 0.5

      var slanted = Track(initial: 0)
      slanted.step(to: 1, at: active.start)
      slanted.step(to: 0, at: active.end)
      italic.add(slanted.animation("opacity", duration: duration), forKey: "italic")
      italic.opacity = 0
    }
    return container
  }

  /// A word drawn once with CoreText into a bitmap. `CATextLayer` does not draw reliably in
  /// offline export renders, but plain layer contents always do, and they're cheaper per frame.
  static func textLayer(
    _ text: String,
    font: CTFont,
    color: CaptionColor,
    stroke: Bool,
    frame: CGRect,
    scale: CGFloat
  ) -> CALayer {
    var attributes: [NSAttributedString.Key: Any] = [
      NSAttributedString.Key(kCTFontAttributeName as String): font,
      NSAttributedString.Key(kCTForegroundColorAttributeName as String): color.cgColor,
    ]
    let strokeWidth: CGFloat = stroke ? 7 : 0
    if stroke {
      // Negative stroke width fills and strokes, which keeps white caps legible on any shot.
      attributes[NSAttributedString.Key(kCTStrokeWidthAttributeName as String)] = -strokeWidth
      attributes[NSAttributedString.Key(kCTStrokeColorAttributeName as String)] = CaptionColor.black.cgColor
    }
    let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
    let ascent = CTFontGetAscent(font), descent = CTFontGetDescent(font)
    // Stroke width is a percentage of the font size, centered on the glyph outline.
    let bleed = ceil(CTFontGetSize(font) * strokeWidth / 200) + 2
    let size = CGSize(width: frame.width + bleed * 2, height: ascent + descent + bleed * 2)

    let layer = CALayer()
    layer.frame = CGRect(
      x: frame.minX - bleed,
      y: frame.minY + (frame.height - ascent - descent) / 2 - bleed,
      width: size.width,
      height: size.height
    )
    layer.contentsScale = scale
    layer.contentsGravity = .resize

    let pixelWidth = Int(ceil(size.width * scale)), pixelHeight = Int(ceil(size.height * scale))
    guard pixelWidth > 0, pixelHeight > 0,
      let context = CGContext(
        data: nil,
        width: pixelWidth,
        height: pixelHeight,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
      )
    else { return layer }
    context.scaleBy(x: scale, y: scale)
    context.textPosition = CGPoint(x: bleed, y: bleed + descent)
    CTLineDraw(line, context)
    layer.contents = context.makeImage()
    return layer
  }

  static func addShadow(_ layer: CALayer, layout: Layout) {
    layer.shadowColor = CaptionColor.black.cgColor
    layer.shadowOpacity = 0.55
    layer.shadowRadius = layout.fontSize * 0.12
    layer.shadowOffset = .zero
  }
}

// MARK: - Timeline tracks

/// A value over media time, compiled into one keyframe animation spanning the whole take.
///
/// One animation per property avoids stacking dozens of short animations per layer, and
/// keyframes on the media timeline scrub correctly in an `AVSynchronizedLayer`.
struct Track {
  private(set) var points: [(time: TimeInterval, value: Double)]

  init(initial: Double) {
    points = [(0, initial)]
  }

  private var current: Double { points[points.count - 1].value }

  /// Holds the current value until `time`, then moves linearly to `value` over `over` seconds.
  mutating func ramp(to value: Double, at time: TimeInterval, over: TimeInterval) {
    let start = max(time, points[points.count - 1].time)
    points.append((start, current))
    points.append((start + max(over, 0.001), value))
  }

  mutating func step(to value: Double, at time: TimeInterval) {
    ramp(to: value, at: time, over: 0.001)
  }

  func animation(_ keyPath: String, duration: TimeInterval) -> CAKeyframeAnimation {
    let animation = CAKeyframeAnimation(keyPath: keyPath)
    var times: [NSNumber] = []
    var values: [NSNumber] = []
    var last = -1.0
    for point in points {
      let t = min(max(point.time / duration, 0), 1)
      // Key times must strictly increase; drop points squeezed onto the same instant.
      guard t > last else {
        values[values.count - 1] = NSNumber(value: point.value)
        continue
      }
      times.append(NSNumber(value: t))
      values.append(NSNumber(value: point.value))
      last = t
    }
    if last < 1 {
      times.append(1)
      values.append(NSNumber(value: current))
    }
    animation.keyTimes = times
    animation.values = values
    animation.calculationMode = .linear
    animation.beginTime = AVCoreAnimationBeginTimeAtZero
    animation.duration = duration
    animation.isRemovedOnCompletion = false
    animation.fillMode = .both
    return animation
  }
}

extension CaptionColor {
  /// Light accents (yellow, green) need dark text on top of them.
  var prefersDarkText: Bool {
    0.2126 * red + 0.7152 * green + 0.0722 * blue > 0.6
  }

  /// The accent mixed toward white, for tinting serif italics without shouting.
  var softened: CaptionColor {
    CaptionColor(red: red * 0.45 + 0.55, green: green * 0.45 + 0.55, blue: blue * 0.45 + 0.55, alpha: alpha)
  }
}
