import CueCore
import SwiftUI

/// The script sheet. It grows out of the Dynamic Island, so the words start life right
/// next to the camera — where they'll be while you record.
struct ScriptComposer: View {
  @Binding var isOpen: Bool
  @Binding var text: String
  var onStart: () -> Void

  @State private var showsPasted = false
  @FocusState private var editing: Bool

  private var words: [ScriptWord] { ScriptText.words(text) }

  private var summary: String {
    let read = Duration.seconds(ScriptText.estimatedReadTime(wordCount: words.count))
    return "\(words.count) words · ≈\(read.formatted(.time(pattern: .minuteSecond))) read"
  }

  var body: some View {
    GeometryReader { proxy in
      let island = CGSize(width: 126, height: 37)
      let topInset = proxy.safeAreaInsets.top
      ZStack(alignment: .top) {
        if isOpen {
          Color.black.opacity(0.25)
            .ignoresSafeArea()
            .onTapGesture { close() }
            .transition(.opacity)
        }

        VStack(spacing: 12) {
          if isOpen { content.transition(.opacity.animation(.easeOut(duration: 0.2).delay(0.12))) }
        }
        .padding(16)
        .padding(.top, isOpen ? topInset - 22 : 0)
        .frame(width: isOpen ? proxy.size.width - 16 : island.width, height: isOpen ? nil : island.height, alignment: .top)
        .background(.black, in: RoundedRectangle(cornerRadius: isOpen ? 44 : island.height / 2, style: .continuous))
        .opacity(isOpen ? 1 : 0)
        .padding(.top, isOpen ? 8 : 11)
        .ignoresSafeArea(edges: .top)

        if showsPasted {
          Label("Script pasted", systemImage: "checkmark.circle.fill")
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(.black, in: Capsule())
            .offset(y: 300)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
      }
      .frame(maxWidth: .infinity)
    }
    .allowsHitTesting(isOpen)
  }

  private var content: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Text("Script").font(.subheadline.weight(.semibold))
        if !text.isEmpty {
          Text(editing ? "Editing" : "Ready")
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(.white.opacity(0.15), in: Capsule())
        }
        Spacer()
        if text.isEmpty {
          PasteButton(payloadType: String.self) { strings in
            guard let pasted = strings.first else { return }
            text = pasted
            flashPasted()
          }
          .buttonBorderShape(.capsule)
          .labelStyle(.titleAndIcon)
          .tint(.white)
          .controlSize(.small)
        } else {
          Button(editing ? "Done" : "Edit", systemImage: editing ? "checkmark" : "pencil") {
            editing.toggle()
          }
          .font(.footnote.weight(.semibold))
          .foregroundStyle(.red)
        }
      }

      ZStack(alignment: .topLeading) {
        if text.isEmpty {
          Text("Paste your script here…")
            .foregroundStyle(.white.opacity(0.35))
            .padding(.top, 8)
            .padding(.leading, 5)
        }
        TextEditor(text: $text)
          .focused($editing)
          .scrollContentBackground(.hidden)
          .foregroundStyle(.white)
      }
      .font(.subheadline)
      .frame(height: 120)
      .padding(8)
      .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))

      if !words.isEmpty {
        Text(summary)
          .font(.caption)
          .foregroundStyle(.white.opacity(0.5))
      }

      Button {
        editing = false
        onStart()
      } label: {
        Text("Start recording")
          .font(.subheadline.weight(.semibold))
          .frame(maxWidth: .infinity)
          .padding(.vertical, 12)
          .background(.white, in: Capsule())
          .foregroundStyle(.black)
      }
      .disabled(words.isEmpty)
      .opacity(words.isEmpty ? 0.5 : 1)
    }
    .foregroundStyle(.white)
  }

  private func close() {
    editing = false
    withAnimation(.spring(duration: 0.4, bounce: 0.1)) { isOpen = false }
  }

  private func flashPasted() {
    withAnimation(.spring(duration: 0.35, bounce: 0.3)) { showsPasted = true }
    Task {
      try? await Task.sleep(for: .seconds(1.6))
      withAnimation(.easeOut(duration: 0.25)) { showsPasted = false }
    }
  }
}
