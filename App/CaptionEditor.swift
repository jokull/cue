import CueCore
import SwiftUI

/// Every caption word as a chip, grouped by page. Tap one to fix its text or nudge its timing.
struct CaptionEditor: View {
  @Bindable var take: Take
  @Environment(\.dismiss) private var dismiss
  @State private var timings: [WordTiming] = []
  @State private var selected: WordTiming.ID?

  private var pages: [CaptionPage] {
    CaptionLayerBuilder.pages(for: timings, settings: take.captionSettings)
  }

  var body: some View {
    NavigationStack {
      List {
        Section {
          Label("From your script", systemImage: "circle.fill").foregroundStyle(.primary)
          Label("Ad-lib — not in the script", systemImage: "circle.dashed").foregroundStyle(.orange)
          Label("Not heard clearly — timing guessed", systemImage: "circle.lefthalf.filled").foregroundStyle(.secondary)
        }
        .font(.caption)

        ForEach(Array(pages.enumerated()), id: \.offset) { _, page in
          Section(timecode(page.start)) {
            FlowLayout(spacing: 6) {
              ForEach(page.words) { word in
                Button { selected = word.id } label: { WordChip(word: word) }
                  .buttonStyle(.plain)
              }
            }
            .padding(.vertical, 4)
          }
        }
      }
      .navigationTitle("Caption words")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("Done") {
            take.timings = timings
            dismiss()
          }
        }
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") { dismiss() }
        }
      }
      .sheet(item: $selected) { id in
        if let index = timings.firstIndex(where: { $0.id == id }) {
          WordEditor(word: $timings[index]) {
            timings.remove(at: index)
            selected = nil
          }
          .presentationDetents([.height(320)])
        }
      }
    }
    .onAppear { timings = take.timings }
  }
}

extension UUID: @retroactive Identifiable {
  public var id: UUID { self }
}

struct WordChip: View {
  let word: WordTiming

  var body: some View {
    Text(word.text)
      .font(.subheadline)
      .italic(word.source == .interpolated || word.source == .estimated)
      .padding(.horizontal, 10)
      .padding(.vertical, 6)
      .foregroundStyle(word.source == .adlib ? .orange : word.source == .script ? .primary : .secondary)
      .background(Color(.tertiarySystemFill), in: Capsule())
      .overlay {
        if word.source == .adlib {
          Capsule().strokeBorder(.orange, style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
        }
      }
  }
}

struct WordEditor: View {
  @Binding var word: WordTiming
  var onDelete: () -> Void
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    NavigationStack {
      Form {
        TextField("Word", text: $word.text)
          .font(.title3)
        nudge("Starts", value: $word.start)
        nudge("Ends", value: $word.end)
        Button("Remove word", role: .destructive) { onDelete() }
      }
      .navigationTitle("Edit word")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
      }
    }
  }

  private func nudge(_ label: String, value: Binding<TimeInterval>) -> some View {
    LabeledContent(label) {
      HStack(spacing: 12) {
        Button("Earlier", systemImage: "minus") { value.wrappedValue = max(0, value.wrappedValue - 0.05) }
        Text(value.wrappedValue.formatted(.number.precision(.fractionLength(2))) + "s")
          .monospacedDigit()
          .frame(minWidth: 56)
        Button("Later", systemImage: "plus") { value.wrappedValue += 0.05 }
      }
      .labelStyle(.iconOnly)
      .buttonStyle(.bordered)
    }
  }
}

/// Lays children out left to right, wrapping onto new rows.
struct FlowLayout: Layout {
  var spacing: CGFloat = 8

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    let rows = arrange(subviews, width: proposal.width ?? .infinity)
    return CGSize(width: proposal.width ?? rows.width, height: rows.height)
  }

  func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
    let rows = arrange(subviews, width: bounds.width)
    for (index, point) in rows.points.enumerated() {
      subviews[index].place(at: CGPoint(x: bounds.minX + point.x, y: bounds.minY + point.y), proposal: .unspecified)
    }
  }

  private func arrange(_ subviews: Subviews, width: CGFloat) -> (points: [CGPoint], width: CGFloat, height: CGFloat) {
    var points: [CGPoint] = []
    var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, widest: CGFloat = 0
    for subview in subviews {
      let size = subview.sizeThatFits(.unspecified)
      if x > 0, x + size.width > width {
        x = 0
        y += rowHeight + spacing
        rowHeight = 0
      }
      points.append(CGPoint(x: x, y: y))
      x += size.width + spacing
      widest = max(widest, x - spacing)
      rowHeight = max(rowHeight, size.height)
    }
    return (points, widest, y + rowHeight)
  }
}
