import CueCore
import SwiftUI

/// The script band under the camera: the whole script as one continuous column, seen through a
/// four-line window — the line just read, the reading line (the focus), and two lines ahead.
///
/// It moves by line, not by word: voice recognition runs about a second behind the reader, which
/// a word highlight would show as stutter; a line holds ~2–3 s of speech, so line changes driven
/// by the reading-pace estimate land on time (research/eval: within ~0.3 s). A line change, or a
/// drag between clips, pans the column — nothing is re-rendered.
struct PrompterView<Header: View>: View {
  let words: [ScriptWord]
  /// Estimated current word, fractional.
  let position: Double
  /// Live finger offset while the script is being dragged, in points.
  var drag: CGFloat = 0
  /// While dragging, the window opens downward and the text zooms out a touch, so the reader
  /// sees what's coming; it closes back to three lines on release.
  var expanded = false
  var header: Header

  static var lineHeight: CGFloat { 36 }
  /// The reading line's row in the window: always the second, so expanding only reveals more
  /// of what comes next.
  private let readingRow = 1
  private var rows: Int { expanded ? 9 : 4 }
  private var zoom: CGFloat { expanded ? 0.92 : 1 }

  private var lines: [Range<Int>] { PrompterLines.lines(words) }

  var body: some View {
    let lines = lines
    let reading = PrompterLines.line(containing: min(Int(position), max(words.count - 1, 0)), in: lines)
    // Where the eye is, continuously, including a drag in progress.
    let focus = Double(reading) - Double(drag / Self.lineHeight)

    VStack(alignment: .leading, spacing: 10) {
      header
      VStack(alignment: .leading, spacing: 0) {
        ForEach(lines.indices, id: \.self) { index in
          Text(words[lines[index]].map(\.text).joined(separator: " "))
            .font(.title2.weight(.semibold))
            .lineLimit(1)
            .minimumScaleFactor(0.75)
            .frame(height: Self.lineHeight, alignment: .leading)
            .opacity(emphasis(of: index, focus: focus))
        }
      }
      .offset(y: CGFloat(readingRow - reading) * Self.lineHeight + drag)
      .scaleEffect(zoom, anchor: .topLeading)
      .frame(maxWidth: .infinity, maxHeight: Self.lineHeight * zoom * CGFloat(rows), alignment: .topLeading)
      .clipped()
      .mask {
        // A soft edge of under half a line, so the outer lines keep their own opacity.
        let edge = 0.4 / Double(rows)
        LinearGradient(
          stops: [
            .init(color: .clear, location: 0), .init(color: .black, location: edge),
            .init(color: .black, location: 1 - edge), .init(color: .clear, location: 1),
          ],
          startPoint: .top, endPoint: .bottom)
      }
      .animation(.spring(duration: 0.5, bounce: 0.08), value: reading)
      // While scrolling, a pill marks the reading row and stays put as the text pans through it
      // — whichever line lands in it is where the next clip starts. Drawn outside the mask and
      // clip so it can overhang the text a little.
      .background(alignment: .topLeading) {
        Capsule()
          .fill(.white.opacity(0.14))
          .overlay(Capsule().stroke(.white.opacity(0.18), lineWidth: 0.5))
          .frame(height: Self.lineHeight * zoom)
          .padding(.horizontal, -12)
          .offset(y: CGFloat(readingRow) * Self.lineHeight * zoom)
          .opacity(expanded ? 1 : 0)
          .animation(.easeOut(duration: 0.2), value: expanded)
      }
    }
    .padding(.horizontal, 20)
    .padding(.top, 62)
    .padding(.bottom, 28)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background {
      LinearGradient(
        stops: [.init(color: .black, location: 0), .init(color: .black.opacity(expanded ? 0.9 : 0.85), location: 0.65), .init(color: .clear, location: 1)],
        startPoint: .top, endPoint: .bottom)
        .ignoresSafeArea()
    }
    .foregroundStyle(.white)
  }

  /// Opacity by position relative to the reading line: the line just read 80%, the reading line
  /// 100%, then 80% and 50% for the two ahead. Interpolated, so a drag blends smoothly as lines
  /// pass the focus. Peeking fades gently, since the point is to read ahead.
  private func emphasis(of line: Int, focus: Double) -> Double {
    let offset = Double(line) - focus
    if expanded { return max(0.45, 1 - 0.15 * abs(offset)) }
    let stops: [(offset: Double, opacity: Double)] = [(-2, 0.3), (-1, 0.8), (0, 1), (1, 0.8), (2, 0.5), (3, 0.3)]
    guard offset > stops.first!.offset else { return stops.first!.opacity }
    guard offset < stops.last!.offset else { return stops.last!.opacity }
    let upper = stops.firstIndex { $0.offset >= offset }!
    let a = stops[upper - 1], b = stops[upper]
    return a.opacity + (b.opacity - a.opacity) * (offset - a.offset) / (b.offset - a.offset)
  }
}

extension PrompterView where Header == EmptyView {
  init(words: [ScriptWord], position: Double, drag: CGFloat = 0, expanded: Bool = false) {
    self.init(words: words, position: position, drag: drag, expanded: expanded, header: EmptyView())
  }

  func header<H: View>(@ViewBuilder _ header: () -> H) -> PrompterView<H> {
    PrompterView<H>(words: words, position: position, drag: drag, expanded: expanded, header: header())
  }
}

extension Collection {
  subscript(safe index: Index) -> Element? {
    indices.contains(index) ? self[index] : nil
  }
}
