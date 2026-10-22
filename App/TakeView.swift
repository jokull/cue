import AVFoundation
import CueCore
import SwiftUI

struct TakeView: View {
  @Bindable var take: Take

  @State private var player = AVPlayer()
  @State private var renderSize = CGSize(width: 1080, height: 1920)
  @State private var showsCaptions = true
  @State private var editing = false
  @State private var exporting = false

  private var settings: Binding<CaptionSettings> {
    Binding { take.captionSettings } set: { take.captionSettings = $0 }
  }

  var body: some View {
    ScrollView {
      VStack(spacing: 16) {
        CaptionPlayer(
          player: player,
          renderSize: renderSize,
          duration: take.duration,
          timings: showsCaptions ? take.timings : [],
          settings: take.captionSettings
        )
        .aspectRatio(renderSize, contentMode: .fit)
        .frame(maxHeight: 460)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .onTapGesture { player.timeControlStatus == .playing ? player.pause() : player.play() }

        status

        CaptionControls(settings: settings, showsCaptions: $showsCaptions)
      }
      .padding(16)
    }
    .background(Color(.systemGroupedBackground))
    .navigationTitle(take.title)
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      ToolbarItem(placement: .topBarTrailing) {
        Button("Export", systemImage: "square.and.arrow.up") { exporting = true }
          .disabled(take.timingQuality == .pending)
      }
    }
    .sheet(isPresented: $editing) {
      CaptionEditor(take: take)
    }
    .sheet(isPresented: $exporting) {
      ExportSheet(take: take)
        .presentationDetents([.medium, .large])
    }
    .task {
      #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if let flag = arguments.firstIndex(of: "-cueStyle"), flag + 1 < arguments.count,
          let style = CaptionStyleID(rawValue: arguments[flag + 1])
        {
          take.captionSettings.style = style
        }
        if arguments.contains("-cueExport") { exporting = true }
      #endif
      await load()
      if take.timingQuality == .pending {
        await CaptionAlignment.run(for: take)
      }
    }
    .onReceive(NotificationCenter.default.publisher(for: AVPlayerItem.didPlayToEndTimeNotification).receive(on: DispatchQueue.main)) { note in
      guard (note.object as? AVPlayerItem) === player.currentItem else { return }
      player.seek(to: .zero)
      player.play()
    }
    .onDisappear { player.pause() }
  }

  private var status: some View {
    HStack(spacing: 8) {
      if take.timingQuality == .pending {
        ProgressView().controlSize(.small)
      } else {
        Image(systemName: take.timingQuality == .voice ? "waveform" : "clock")
          .foregroundStyle(take.timingQuality == .voice ? .green : .orange)
      }
      Text(take.timingQuality.label)
      Spacer()
      Button("Edit words") { editing = true }
        .disabled(take.timingQuality == .pending)
    }
    .font(.footnote.weight(.medium))
    .padding(12)
    .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
  }

  private func load() async {
    let asset = AVURLAsset(url: take.url)
    if let track = try? await asset.loadTracks(withMediaType: .video).first,
      let (size, transform) = try? await track.load(.naturalSize, .preferredTransform)
    {
      let upright = CGRect(origin: .zero, size: size).applying(transform)
      renderSize = CGSize(width: abs(upright.width), height: abs(upright.height))
    }
    if let duration = try? await asset.load(.duration).seconds, duration > 0 {
      take.duration = duration
    }
    player.replaceCurrentItem(with: AVPlayerItem(asset: asset))
    player.play()
  }
}

struct CaptionControls: View {
  @Binding var settings: CaptionSettings
  @Binding var showsCaptions: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Toggle("Captions", isOn: $showsCaptions.animation())
        .font(.headline)

      HStack(spacing: 10) {
        ForEach(CaptionStyleID.allCases) { style in
          StyleCard(style: style, accent: settings.accent, isSelected: settings.style == style) {
            withAnimation(.snappy) {
              settings.style = style
              settings.position = nil
            }
          }
        }
      }

      LabeledContent("Accent") {
        HStack(spacing: 10) {
          ForEach(CaptionColor.accents, id: \.self) { color in
            Button {
              settings.accent = color
            } label: {
              Circle()
                .fill(Color(color))
                .frame(width: 26, height: 26)
                .overlay {
                  if settings.accent == color {
                    Circle().stroke(.primary, lineWidth: 2).padding(-4)
                  }
                }
            }
            .accessibilityLabel("Accent color")
          }
        }
      }

      LabeledContent("Size") {
        Picker("Size", selection: $settings.size) {
          Text("S").tag(CaptionSize.small)
          Text("M").tag(CaptionSize.medium)
          Text("L").tag(CaptionSize.large)
        }
        .pickerStyle(.segmented)
        .frame(width: 160)
      }

      LabeledContent("Position") {
        Picker("Position", selection: Binding { settings.resolvedPosition } set: { settings.position = $0 }) {
          Image(systemName: "rectangle.tophalf.inset.filled").tag(CaptionPosition.top)
          Image(systemName: "rectangle.center.inset.filled").tag(CaptionPosition.middle)
          Image(systemName: "rectangle.bottomhalf.inset.filled").tag(CaptionPosition.bottom)
        }
        .pickerStyle(.segmented)
        .frame(width: 160)
      }

      Toggle("Highlight each word", isOn: $settings.highlightsWords)
    }
    .font(.subheadline)
    .padding(16)
    .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18))
    .disabled(!showsCaptions)
    .opacity(showsCaptions ? 1 : 0.5)
  }
}

struct StyleCard: View {
  let style: CaptionStyleID
  let accent: CaptionColor
  let isSelected: Bool
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      VStack(spacing: 8) {
        sample
          .frame(maxWidth: .infinity, minHeight: 56)
          .background(.black, in: RoundedRectangle(cornerRadius: 12))
        Text(style.displayName)
          .font(.footnote.weight(.semibold))
      }
      .padding(6)
      .background {
        RoundedRectangle(cornerRadius: 16)
          .stroke(isSelected ? Color.accentColor : .clear, lineWidth: 2)
      }
    }
    .buttonStyle(.plain)
  }

  @ViewBuilder private var sample: some View {
    switch style {
    case .fun:
      HStack(spacing: 4) {
        Text("HEY").foregroundStyle(.white)
        Text("YOU")
          .padding(.horizontal, 3)
          .background(Color(accent), in: RoundedRectangle(cornerRadius: 4))
          .foregroundStyle(accent.prefersDarkText ? .black : .white)
      }
      .font(.system(size: 15, weight: .black, design: .rounded))
    case .pro:
      Text("Hey \(Text("you").foregroundStyle(.white.opacity(0.5)))")
        .foregroundStyle(.white)
        .font(.system(size: 15, weight: .semibold))
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(.white.opacity(0.15), in: RoundedRectangle(cornerRadius: 4))
    case .serif:
      Text("Hey \(Text("you").italic().foregroundStyle(Color(accent).mix(with: .white, by: 0.55)))")
        .foregroundStyle(.white)
        .font(.system(size: 17, design: .serif))
    }
  }
}

extension Color {
  init(_ color: CaptionColor) {
    self.init(.sRGB, red: color.red, green: color.green, blue: color.blue, opacity: color.alpha)
  }
}

/// The take with its captions playing on top, from the same layer tree that export renders.
struct CaptionPlayer: UIViewRepresentable {
  let player: AVPlayer
  let renderSize: CGSize
  let duration: TimeInterval
  let timings: [WordTiming]
  let settings: CaptionSettings

  func makeUIView(context: Context) -> PlayerView {
    let view = PlayerView()
    view.playerLayer.player = player
    view.playerLayer.videoGravity = .resizeAspect
    view.backgroundColor = .black
    return view
  }

  func updateUIView(_ view: PlayerView, context: Context) {
    view.update(
      item: player.currentItem,
      captions: CaptionKey(timings: timings, settings: settings, renderSize: renderSize, duration: duration))
  }

  struct CaptionKey: Equatable {
    var timings: [WordTiming]
    var settings: CaptionSettings
    var renderSize: CGSize
    var duration: TimeInterval
  }

  final class PlayerView: UIView {
    override static var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }

    private var synchronized: AVSynchronizedLayer?
    private var captions: CALayer?
    private var key: CaptionKey?

    func update(item: AVPlayerItem?, captions newKey: CaptionKey) {
      guard let item else { return }
      if synchronized?.playerItem !== item {
        synchronized?.removeFromSuperlayer()
        let layer = AVSynchronizedLayer(playerItem: item)
        playerLayer.addSublayer(layer)
        synchronized = layer
        key = nil
      }
      guard newKey != key else { return }
      key = newKey

      // A layer tree can only live in one place, so preview builds its own.
      captions?.removeFromSuperlayer()
      let pages = CaptionLayerBuilder.pages(for: newKey.timings, settings: newKey.settings)
      let layer = CaptionLayerBuilder.makeLayer(
        pages: pages,
        settings: newKey.settings,
        options: .init(renderSize: newKey.renderSize, duration: newKey.duration)
      )
      layer.anchorPoint = .zero
      synchronized?.addSublayer(layer)
      captions = layer
      setNeedsLayout()
    }

    override func layoutSubviews() {
      super.layoutSubviews()
      guard let key else { return }
      CATransaction.begin()
      CATransaction.setDisableActions(true)
      let videoRect = AVMakeRect(aspectRatio: key.renderSize, insideRect: bounds)
      synchronized?.frame = videoRect
      captions?.position = .zero
      let scale = videoRect.width / max(key.renderSize.width, 1)
      captions?.setAffineTransform(CGAffineTransform(scaleX: scale, y: scale))
      CATransaction.commit()
    }
  }
}

