import AVFoundation
import AVKit
import CueCore
import SwiftData
import SwiftUI

/// How the prompter moves through the script.
enum PromptMode: Hashable {
  /// Follows the speaker's voice.
  case voice
  /// Scrolls at a fixed pace while recording; the multiplier is on a 150 wpm base.
  case auto(Double)

  var label: String {
    switch self {
    case .voice: "VOICE"
    case .auto(let speed): "\(speed.formatted(.number.precision(.fractionLength(1))))×"
    }
  }
}

/// A take built from clips: hold to record a clip, release to stop. Between clips the prompter
/// waits where the reader stopped (or wherever they drag it), and the tray edits the clips.
@Observable final class RecordModel {
  enum Phase: Equatable {
    case preparing, idle, recording, stitching
    case unavailable(String)
  }

  private(set) var phase = Phase.preparing
  var mode = PromptMode.voice
  private(set) var clips = ClipSequence()
  /// The clip a hold will replace (a retake). Selecting one also cues the prompter to it.
  private(set) var selected: Clip.ID?
  /// Locked hands-free: recording continues after the finger lifts.
  private(set) var isLocked = false
  /// How long the clip being recorded has run.
  private(set) var clipElapsed: TimeInterval = 0
  /// Backspace is two-step: the first tap arms a clip (it turns red), the second deletes it.
  private(set) var armedForDelete: Clip.ID?
  var showsFullAlert = false
  /// Auto-scroll's position, in words.
  private(set) var autoPosition = 0.0

  let script: Script
  let speech: LiveSpeechTracker
  let recorder = CameraRecorder()
  @ObservationIgnored private var clipURL: URL?
  @ObservationIgnored private var clipStartWord = 0
  @ObservationIgnored private var clipStartedAt: Date?
  @ObservationIgnored private var clock: Task<Void, Never>?
  @ObservationIgnored private var commitDeleteTask: Task<Void, Never>?

  init(script: Script) {
    self.script = script
    self.speech = LiveSpeechTracker(script: script.words, language: script.languageCode)
  }

  var lines: [Range<Int>] { PrompterLines.lines(speech.words) }

  /// Where the prompter is, in words (fractional).
  var position: Double {
    #if DEBUG
      if let stagedPosition { return stagedPosition }
    #endif
    return switch mode {
    case .voice: speech.position
    case .auto: autoPosition
    }
  }

  /// Everything recorded so far, including the clip in progress.
  var totalDuration: TimeInterval { clips.duration + (phase == .recording ? clipElapsed : 0) }

  // MARK: Setup

  func prepare() async {
    do {
      let feed = speech.feed
      try await recorder.configure { feed.append($0) }
      recorder.startRunning()
      phase = .idle
    } catch {
      phase = .unavailable(error.localizedDescription)
      return
    }
    speech.prepare()
    if case .unavailable = speech.readiness, mode == .voice {
      mode = .auto(1.0)
    }
  }

  // MARK: Recording a clip

  func beginClip() async {
    guard phase == .idle else { return }
    guard !clips.isFull else {
      showsFullAlert = true
      return
    }
    disarmDelete()
    let url = TakeFiles.newClipURL()
    do {
      try await recorder.startRecording(to: url)
    } catch {
      return
    }
    clipURL = url
    clipStartWord = Int(position)
    clipStartedAt = .now
    clipElapsed = 0
    phase = .recording
    if mode == .voice { await speech.start() }
    clock = Task { [weak self] in
      while !Task.isCancelled, let self {
        self.tick()
        try? await Task.sleep(for: .milliseconds(50))
      }
    }
  }

  func lock() {
    guard phase == .recording else { return }
    isLocked = true
  }

  func endClip() async {
    guard phase == .recording, let url = clipURL else { return }
    clock?.cancel()
    speech.stop()
    isLocked = false
    let duration = await recorder.finishRecording()
    phase = .idle
    clipURL = nil
    // A tap rather than a hold records next to nothing; don't keep it.
    guard duration >= 0.4 else {
      try? FileManager.default.removeItem(at: url)
      return
    }
    let endWord = max(clipStartWord, Int(position))
    let clip = Clip(url: url, duration: duration, scriptRange: clipStartWord..<endWord)
    if let selected, let old = clips.replace(selected, with: clip) {
      try? FileManager.default.removeItem(at: old.url)
    } else {
      clips.add(clip)
    }
    selected = nil
  }

  private func tick() {
    guard let clipStartedAt else { return }
    clipElapsed = Date.now.timeIntervalSince(clipStartedAt)
    if case .auto(let speed) = mode {
      autoPosition = min(autoPosition + 0.05 * 150 * speed / 60, Double(speech.words.count))
    }
    if clips.duration + clipElapsed >= ClipSequence.maxDuration {
      showsFullAlert = true
      Task { await endClip() }
    }
  }

  // MARK: Moving through the script

  /// Puts the prompter at the start of `word` — dragged by hand, or cued for a retake.
  func reposition(to word: Int) {
    guard phase == .idle else { return }
    speech.reposition(to: word)
    autoPosition = Double(word)
  }

  /// One line per step; negative steps go back.
  func step(lines delta: Int) {
    let lines = lines
    guard !lines.isEmpty else { return }
    let current = PrompterLines.line(containing: min(Int(position), max(speech.words.count - 1, 0)), in: lines)
    let target = min(max(current + delta, 0), lines.count - 1)
    reposition(to: lines[target].lowerBound)
  }

  // MARK: Editing clips

  /// Tapping a clip selects it for a retake and cues the prompter to its lines; tapping it
  /// again deselects.
  func toggleSelection(_ clip: Clip) {
    disarmDelete()
    if selected == clip.id {
      selected = nil
    } else {
      selected = clip.id
      reposition(to: clip.scriptRange.lowerBound)
    }
  }

  func move(_ id: Clip.ID, before: Clip.ID?) {
    clips.move(id, before: before)
  }

  /// Backspace: arms the selected clip (or the last one), and deletes it on the second tap.
  func backspace() {
    guard let target = selected ?? clips.clips.last?.id else { return }
    if armedForDelete == target {
      armedForDelete = nil
      if selected == target { selected = nil }
      commitPendingDelete()
      clips.delete(target)
      // Keep the file for a few seconds so Undo can bring the clip back.
      commitDeleteTask = Task { [weak self] in
        try? await Task.sleep(for: .seconds(5))
        guard !Task.isCancelled else { return }
        self?.commitPendingDelete()
      }
    } else {
      armedForDelete = target
    }
  }

  func undoDelete() {
    commitDeleteTask?.cancel()
    clips.undoDelete()
  }

  private func commitPendingDelete() {
    if let clip = clips.commitDelete() { try? FileManager.default.removeItem(at: clip.url) }
  }

  private func disarmDelete() { armedForDelete = nil }

  // MARK: Finishing

  /// Stitches the clips into one take. Final: the clips are gone afterwards.
  func finish(in context: ModelContext) async -> Take? {
    guard phase == .idle, !clips.isEmpty else { return nil }
    commitPendingDelete()
    phase = .stitching
    let destination = TakeFiles.newTakeURL()
    guard let duration = try? await ClipStitcher.stitch(clips.clips.map(\.url), to: destination) else {
      phase = .idle
      return nil
    }
    discardClips()
    recorder.stopRunning()
    let take = Take(script: script, fileName: destination.lastPathComponent, duration: duration)
    context.insert(take)
    script.takes.append(take)
    return take
  }

  func discardClips() {
    commitPendingDelete()
    for clip in clips.clips { try? FileManager.default.removeItem(at: clip.url) }
    clips = ClipSequence()
  }

  func close() {
    clock?.cancel()
    speech.stop()
    recorder.stopRunning()
  }

  #if DEBUG
    /// Screenshot staging: a frozen state, with no camera or microphone.
    private(set) var stagedPosition: Double?

    func stage(position: Double) {
      stagedPosition = position
      phase = .idle
    }

    /// Simulator: clips made from a video file, covering the script in order.
    func stageClips(from video: URL, count: Int) {
      let words = speech.words.count
      for index in 0..<count {
        let url = TakeFiles.newClipURL()
        try? FileManager.default.copyItem(at: video, to: url)
        let range = (words * index / count)..<(words * (index + 1) / count)
        clips.add(Clip(url: url, duration: 3 + Double(index), scriptRange: range))
      }
      phase = .idle
    }

    /// Simulator test: a recorded take's audio (16 kHz mono Int16) plays through the real
    /// voice-tracking pipeline at speaking pace, as one clip with no camera.
    func playThrough(pcm: Data) async {
      speech.prepare()
      clipStartedAt = .now
      phase = .recording
      await speech.start()
      clock = Task { [weak self] in
        while !Task.isCancelled, let self {
          self.tick()
          try? await Task.sleep(for: .milliseconds(50))
        }
      }
      let feed = speech.feed
      for offset in stride(from: 0, to: pcm.count, by: MicrophoneFeed.chunkBytes) {
        feed.appendPCM(pcm.subdata(in: offset..<min(offset + MicrophoneFeed.chunkBytes, pcm.count)))
        try? await Task.sleep(for: .milliseconds(100))
      }
    }
  #endif
}

struct RecordView: View {
  @State var model: RecordModel
  var onFinished: (Take, [WordTiming]) -> Void
  var onDemo: () -> Void

  @Environment(\.dismiss) private var dismiss
  @Environment(\.modelContext) private var context
  @State private var stagedCamera: UIImage?
  @State private var previewing: Clip?
  @State private var confirmsDiscard = false
  @State private var scrubDrag: CGFloat = 0
  @State private var peeking = false
  @State private var closingPeek: Task<Void, Never>?

  private var scrub: ScriptScrub {
    ScriptScrub(model: model, drag: $scrubDrag, expanded: $peeking, closing: $closingPeek)
  }

  @ViewBuilder private var camera: some View {
    if let stagedCamera {
      // Fill without widening the layout: scaledToFill alone would push the prompter off-screen.
      Color.clear
        .overlay { Image(uiImage: stagedCamera).resizable().scaledToFill() }
        .clipped()
        .ignoresSafeArea()
    } else {
      CameraPreview(session: model.recorder.session).ignoresSafeArea()
    }
  }

  var body: some View {
    ZStack {
      Color.black.ignoresSafeArea()
      camera

      // Between clips the camera image scrubs the script (see ScriptScrub).
      Color.clear
        .contentShape(Rectangle())
        .gesture(scrub.gesture)
        .allowsHitTesting(model.phase == .idle)
        .ignoresSafeArea()

      if case .unavailable(let message) = model.phase {
        unavailable(message)
      } else {
        VStack(spacing: 0) {
          PrompterView(words: model.speech.words, position: model.position, drag: scrubDrag, expanded: peeking)
            .header { header }
            .contentShape(Rectangle())
            .gesture(scrub.gesture)
            // A light tick as each line passes the reading position.
            .sensoryFeedback(.selection, trigger: Int((scrubDrag / PrompterView<EmptyView>.lineHeight).rounded()))
          Spacer()
          ClipTray(model: model, previewing: $previewing, onClose: close, onDone: done)
        }
        .opacity(model.phase == .preparing ? 0 : 1)
      }

      RecordingFrame(active: model.phase == .recording)

      if let previewing {
        ClipPreview(clip: previewing) { self.previewing = nil }
          .transition(.opacity)
      }
      if model.phase == .stitching {
        ProgressView("Putting your take together…")
          .tint(.white)
          .foregroundStyle(.white)
          .padding(20)
          .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 16))
      }
    }
    .animation(.spring(duration: 0.35, bounce: 0.15), value: model.phase)
    .animation(.easeOut(duration: 0.2), value: previewing)
    .sensoryFeedback(trigger: model.phase) { old, new in
      switch (old, new) {
      case (.recording, .idle): .impact(weight: .light)
      default: nil
      }
    }
    .alert("That's three minutes", isPresented: $model.showsFullAlert) {
      Button("OK", role: .cancel) {}
    } message: {
      Text("Cue takes are up to 3 minutes. Tap ✓ to finish, or delete a clip to make room.")
    }
    .confirmationDialog("Discard \(model.clips.clips.count) clips?", isPresented: $confirmsDiscard, titleVisibility: .visible) {
      Button("Discard", role: .destructive) {
        model.discardClips()
        dismiss()
      }
    }
    .task {
      #if DEBUG
        if let staged = DebugStaging.cameraImage {
          stagedCamera = staged
          if let pcm = DebugStaging.microphoneAudio {
            await model.playThrough(pcm: pcm)
          } else if let video = DebugStaging.clipVideo {
            model.stageClips(from: video, count: 4)
            model.stage(position: Double(model.clips.clips.last?.scriptRange.upperBound ?? 0))
          } else {
            model.stage(position: 9)
          }
          return
        }
      #endif
      await model.prepare()
    }
    .onDisappear { model.close() }
    .statusBarHidden()
    // The record button sits over the home-indicator zone, where iOS holds back touches to see
    // if they're a swipe home — the lag between pressing and the ring starting. Defer that
    // gesture here (home takes a second swipe), as camera apps do.
    .defersSystemGestures(on: .bottom)
    .persistentSystemOverlays(model.phase == .recording ? .hidden : .automatic)
  }

  private var header: some View {
    HStack {
      if model.phase == .recording {
        Circle().fill(.red).frame(width: 7, height: 7)
          .phaseAnimator([1.0, 0.25]) { dot, opacity in dot.opacity(opacity) } animation: { _ in .easeInOut(duration: 0.6) }
        Text("REC \(timecode(model.totalDuration))")
          .monospacedDigit()
      } else {
        Text(model.clips.isEmpty ? "HOLD TO RECORD" : timecode(model.totalDuration))
          .monospacedDigit()
      }
      Spacer()
      Menu {
        Picker("Prompter", selection: $model.mode) {
          Text("Follow my voice").tag(PromptMode.voice)
          ForEach([0.8, 1.0, 1.2, 1.5], id: \.self) { speed in
            Text("Auto-scroll \(PromptMode.auto(speed).label)").tag(PromptMode.auto(speed))
          }
        }
      } label: {
        Text(model.mode.label)
      }
      .disabled(model.phase == .recording)
    }
    .font(.caption2.weight(.semibold))
    .foregroundStyle(.white.opacity(0.8))
  }

  private func close() {
    if model.clips.isEmpty {
      dismiss()
    } else {
      confirmsDiscard = true
    }
  }

  private func done() {
    Task {
      if let take = await model.finish(in: context) {
        dismiss()
        onFinished(take, [])
      }
    }
  }

  private func unavailable(_ message: String) -> some View {
    VStack(spacing: 16) {
      Image(systemName: "video.slash")
        .font(.largeTitle)
      Text(message)
        .multilineTextAlignment(.center)
      Button("Try the demo take") {
        dismiss()
        onDemo()
      }
      .buttonStyle(.borderedProminent)
      Button("Close") { dismiss() }
    }
    .foregroundStyle(.white)
    .padding(32)
  }
}

/// Scrubbing the script between clips. The same gesture works on the script itself and on the
/// camera image: the script lives at the top of the screen, where an upward drag has no room,
/// so the whole picture above the tray is a scrub surface — the thumb gets the full height and
/// stops covering the lines it's moving. While the finger is down the script peeks open; on
/// release it glides (with the flick's momentum) and snaps onto a line while still open, waits a
/// beat, then closes. Touching again during the glide or the beat re-catches it, so long jumps
/// are a few flicks in a row. Off while recording.
struct ScriptScrub {
  let model: RecordModel
  @Binding var drag: CGFloat
  @Binding var expanded: Bool
  /// The pending close after a release; cancelled when the finger comes back.
  @Binding var closing: Task<Void, Never>?

  private var lineHeight: CGFloat { PrompterView<EmptyView>.lineHeight }

  var gesture: some Gesture {
    DragGesture(minimumDistance: 4)
      .onChanged { value in
        guard model.phase == .idle else { return }
        closing?.cancel()
        closing = nil
        if !expanded {
          withAnimation(.spring(duration: 0.35, bounce: 0.12)) { expanded = true }
        }
        // At 92% zoom a point of finger travel is a little more than a point of text.
        drag = value.translation.height / 0.92
      }
      .onEnded { value in
        guard model.phase == .idle else { return }
        // Pulling the text up reveals what comes next, so an upward drag moves ahead.
        let steps = Int((-value.predictedEndTranslation.height / 0.92 / lineHeight).rounded())
        let placed = Int((-value.translation.height / 0.92 / lineHeight).rounded())
        // Glide and snap with the window still open.
        withAnimation(.spring(duration: 0.5, bounce: 0.1)) {
          model.step(lines: steps)
          drag = 0
        }
        // A flick earns a beat to re-catch before closing; a slow, placed drag closes promptly.
        let flicked = abs(steps - placed) >= 2
        let hold: Duration = flicked ? .milliseconds(500 + 700) : .milliseconds(500 + 250)
        closing = Task { @MainActor in
          try? await Task.sleep(for: hold)
          guard !Task.isCancelled else { return }
          withAnimation(.spring(duration: 0.45, bounce: 0.1)) { expanded = false }
        }
      }
  }
}

/// The editor at the bottom, over the camera: clip strip, segmented progress, and the controls.
struct ClipTray: View {
  let model: RecordModel
  @Binding var previewing: Clip?
  var onClose: () -> Void
  var onDone: () -> Void

  var body: some View {
    VStack(spacing: 12) {
      if let gap = model.clips.gaps().first, model.phase == .idle {
        Button {
          model.reposition(to: gap.lowerBound)
        } label: {
          Label("Skipped \(gap.count) words · tap to cue", systemImage: "arrow.uturn.backward")
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(.yellow, in: Capsule())
            .foregroundStyle(.black)
        }
      }

      if !model.clips.isEmpty {
        ClipStrip(model: model, previewing: $previewing)
      }
      SegmentBar(model: model)

      HStack {
        Button("Close", systemImage: "xmark", action: onClose)
          .labelStyle(.iconOnly)
          .font(.title3.weight(.semibold))
          .frame(width: 44, height: 44)
        Spacer()
        Button(action: model.backspace) {
          Image(systemName: "delete.left.fill")
            .font(.title2)
            .foregroundStyle(model.armedForDelete == nil ? .white : .red)
            .frame(width: 52, height: 52)
        }
        .disabled(model.clips.isEmpty || model.phase != .idle)
        .opacity(model.clips.isEmpty ? 0 : 1)
        .accessibilityLabel(model.armedForDelete == nil ? "Delete clip" : "Tap again to delete")

        RecordButton(model: model)
          .padding(.horizontal, 18)

        Button(action: onDone) {
          Image(systemName: "checkmark")
            .font(.title2.weight(.bold))
            .foregroundStyle(.black)
            .frame(width: 52, height: 52)
            .background(.white, in: Circle())
        }
        .disabled(model.clips.isEmpty || model.phase != .idle)
        .opacity(model.clips.isEmpty ? 0 : 1)
        .accessibilityLabel("Done")
        Spacer()
        Color.clear.frame(width: 44, height: 44)
      }
      .foregroundStyle(.white)

      if model.clips.deleted != nil {
        Button("Undo delete", systemImage: "arrow.uturn.backward", action: model.undoDelete)
          .font(.footnote.weight(.semibold))
          .foregroundStyle(.white)
          .transition(.opacity)
      }
    }
    .padding(.horizontal, 16)
    .padding(.top, 16)
    .padding(.bottom, 8)
    .background {
      LinearGradient(colors: [.clear, .black.opacity(0.75)], startPoint: .top, endPoint: .bottom)
        .ignoresSafeArea()
    }
    .animation(.snappy, value: model.clips.clips)
    .animation(.snappy, value: model.armedForDelete)
  }
}

/// Hold to record; slide up while holding to lock; tap to stop when locked.
///
/// Recording doesn't start on touch: the button's ring fills like a loading indicator (0.4 s) and
/// recording begins when it closes. Letting go earlier cancels — stray taps record nothing, and
/// the start is a deliberate, felt moment.
struct RecordButton: View {
  let model: RecordModel
  @State private var pressing = false
  /// 0…1 around the ring while arming.
  @State private var fill = 0.0
  @State private var arming: Task<Void, Never>?
  @State private var armedPulse = 0

  static let armDuration = 0.4
  private var recording: Bool { model.phase == .recording }

  var body: some View {
    ZStack {
      Circle()
        .stroke(.white.opacity(0.35), lineWidth: 5)
      // Arming: the ring fills clockwise on its own track while held.
      Circle()
        .trim(from: 0, to: fill)
        .stroke(.white, style: StrokeStyle(lineWidth: 5, lineCap: .round))
        .rotationEffect(.degrees(-90))
        .opacity(fill > 0 && !recording ? 1 : 0)
      Group {
        if model.isLocked {
          RoundedRectangle(cornerRadius: 6).fill(.red).frame(width: 26, height: 26)
        } else {
          Circle().fill(.red).frame(width: recording ? 52 : 60, height: recording ? 52 : 60)
        }
      }
      if recording && !model.isLocked {
        Image(systemName: "lock.fill")
          .font(.caption.weight(.bold))
          .foregroundStyle(.white.opacity(0.8))
          .offset(y: -70)
          .transition(.opacity)
      }
    }
    .frame(width: 78, height: 78)
    .scaleEffect(recording ? 1.12 : pressing ? 0.94 : 1)
    .animation(.spring(duration: 0.3, bounce: 0.3), value: recording)
    .animation(.spring(duration: 0.2), value: pressing)
    .animation(.spring(duration: 0.3), value: model.isLocked)
    .sensoryFeedback(.impact(weight: .heavy), trigger: armedPulse)
    .contentShape(Circle())
    .gesture(
      DragGesture(minimumDistance: 0)
        .onChanged { value in
          if !pressing {
            pressing = true
            if model.isLocked {
              Task { await model.endClip() }
            } else {
              arm()
            }
          } else if recording, value.translation.height < -70 {
            model.lock()
          }
        }
        .onEnded { _ in
          pressing = false
          if recording && !model.isLocked {
            Task { await model.endClip() }
          } else if !recording {
            cancelArming()
          }
        }
    )
    .accessibilityLabel(recording ? "Release to stop" : "Hold to record")
    .accessibilityAddTraits(.isButton)
  }

  private func arm() {
    guard model.phase == .idle else { return }
    fill = 0
    withAnimation(.linear(duration: Self.armDuration)) { fill = 1 }
    arming = Task {
      try? await Task.sleep(for: .seconds(Self.armDuration))
      guard !Task.isCancelled, pressing else { return }
      armedPulse += 1
      await model.beginClip()
      fill = 0
    }
  }

  private func cancelArming() {
    arming?.cancel()
    arming = nil
    withAnimation(.easeOut(duration: 0.15)) { fill = 0 }
  }
}

/// The unmistakable "now recording" change: a red frame around the whole screen, following
/// the display's corners, arriving with one brief red flash.
struct RecordingFrame: View {
  let active: Bool
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var flash = false

  var body: some View {
    ZStack {
      Color.red
        .opacity(flash ? 0.22 : 0)
        .allowsHitTesting(false)
      // Doubled width: the outer half falls off-screen, leaving a 5 pt band inside the corners.
      ConcentricRectangle()
        .stroke(.red, lineWidth: 10)
        .shadow(color: .red.opacity(0.7), radius: 10)
        .opacity(active ? 1 : 0)
        .animation(.easeOut(duration: reduceMotion ? 0 : 0.2), value: active)
    }
    .ignoresSafeArea()
    .allowsHitTesting(false)
    .onChange(of: active) { _, isActive in
      guard isActive, !reduceMotion else { return }
      flash = true
      withAnimation(.easeOut(duration: 0.35)) { flash = false }
    }
  }
}

/// The take's makeup: one segment per clip, sharing the full width by length, plus the clip in
/// progress. Deliberately not a countdown — the 3-minute limit only shows if you reach it.
struct SegmentBar: View {
  let model: RecordModel

  var body: some View {
    GeometryReader { proxy in
      let scale = proxy.size.width / max(model.totalDuration, 1)
      HStack(spacing: 2) {
        ForEach(model.clips.clips) { clip in
          Capsule()
            .fill(color(for: clip))
            .frame(width: max(clip.duration * scale - 2, 3))
        }
        if model.phase == .recording {
          Capsule().fill(.red).frame(width: max(model.clipElapsed * scale, 3))
        }
        Spacer(minLength: 0)
      }
      .frame(height: 5)
      .background(.white.opacity(0.18), in: Capsule())
    }
    .frame(height: 5)
  }

  private func color(for clip: Clip) -> Color {
    if model.armedForDelete == clip.id { return .red }
    if model.selected == clip.id { return .yellow }
    return .white
  }
}

/// Thumbnails of the clips. Tap selects (for a retake), long-press previews, drag reorders.
struct ClipStrip: View {
  let model: RecordModel
  @Binding var previewing: Clip?

  var body: some View {
    ScrollView(.horizontal, showsIndicators: false) {
      HStack(spacing: 8) {
        ForEach(Array(model.clips.clips.enumerated()), id: \.element.id) { index, clip in
          ClipThumb(clip: clip, number: index + 1, words: model.speech.words,
                    selected: model.selected == clip.id, armed: model.armedForDelete == clip.id)
            .onTapGesture { model.toggleSelection(clip) }
            .onLongPressGesture { previewing = clip }
            .draggable(clip.id.uuidString)
            .dropDestination(for: String.self) { items, _ in
              guard let id = items.first.flatMap(UUID.init(uuidString:)) else { return false }
              model.move(id, before: clip.id)
              return true
            }
        }
        // Drop here to move a clip to the end.
        Color.clear
          .frame(width: 44, height: 64)
          .dropDestination(for: String.self) { items, _ in
            guard let id = items.first.flatMap(UUID.init(uuidString:)) else { return false }
            model.move(id, before: nil)
            return true
          }
      }
      .padding(.horizontal, 2)
    }
    .scrollClipDisabled()
  }
}

struct ClipThumb: View {
  let clip: Clip
  let number: Int
  let words: [ScriptWord]
  let selected: Bool
  let armed: Bool

  /// The first words the clip covers, so clips are recognizable without playing them.
  private var opening: String {
    guard !clip.scriptRange.isEmpty, clip.scriptRange.lowerBound < words.count else { return "" }
    let end = min(clip.scriptRange.lowerBound + 3, words.count)
    return words[clip.scriptRange.lowerBound..<end].map(\.text).joined(separator: " ")
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      Thumbnail(url: clip.url)
        .frame(width: 52, height: 64)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(alignment: .bottomLeading) {
          Text(clip.duration.formatted(.number.precision(.fractionLength(1))) + "s")
            .font(.system(size: 9, weight: .bold))
            .monospacedDigit()
            .padding(.horizontal, 4)
            .background(.black.opacity(0.6), in: Capsule())
            .padding(3)
        }
        .overlay {
          RoundedRectangle(cornerRadius: 8)
            .stroke(armed ? .red : selected ? .yellow : .clear, lineWidth: 2.5)
        }
      Text(opening.isEmpty ? "Clip \(number)" : opening)
        .font(.system(size: 9, weight: .medium))
        .lineLimit(1)
        .frame(width: 52, alignment: .leading)
    }
    .foregroundStyle(.white)
    .accessibilityElement(children: .combine)
    .accessibilityLabel("Clip \(number), \(Int(clip.duration)) seconds")
    .accessibilityHint("Tap to retake, hold to preview, drag to reorder")
  }
}

/// A clip playing over the camera; tap anywhere to go back.
struct ClipPreview: View {
  let clip: Clip
  var onDismiss: () -> Void
  @State private var player = AVPlayer()

  var body: some View {
    VideoPlayer(player: player)
      .ignoresSafeArea()
      .onAppear {
        player.replaceCurrentItem(with: AVPlayerItem(url: clip.url))
        player.play()
      }
      .onDisappear { player.pause() }
      .overlay(alignment: .topTrailing) {
        Button("Close preview", systemImage: "xmark.circle.fill", action: onDismiss)
          .labelStyle(.iconOnly)
          .font(.title)
          .foregroundStyle(.white)
          .padding()
      }
  }
}

func timecode(_ seconds: TimeInterval) -> String {
  Duration.seconds(seconds).formatted(.time(pattern: .minuteSecond(padMinuteToLength: 2)))
}

struct CameraPreview: UIViewRepresentable {
  let session: AVCaptureSession

  func makeUIView(context: Context) -> PreviewView {
    let view = PreviewView()
    view.previewLayer.session = session
    view.previewLayer.videoGravity = .resizeAspectFill
    return view
  }

  func updateUIView(_ view: PreviewView, context: Context) {}

  final class PreviewView: UIView {
    override static var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
  }
}

#if DEBUG
  /// Launch arguments for simulator screenshots and tests, where there is no camera.
  enum DebugStaging {
    private static func argument(_ flag: String) -> String? {
      let arguments = ProcessInfo.processInfo.arguments
      guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
      return arguments[index + 1]
    }

    /// `-cueFakeCamera <png>` stands a still image in for the camera feed.
    static var cameraImage: UIImage? { argument("-cueFakeCamera").flatMap(UIImage.init(contentsOfFile:)) }

    /// `-cueFakeMic <pcm>`: raw 16 kHz mono Int16 audio to play through voice tracking.
    static var microphoneAudio: Data? { argument("-cueFakeMic").flatMap { FileManager.default.contents(atPath: $0) } }

    /// `-cueFakeClips <mp4>`: fills the tray with clips copied from a video.
    static var clipVideo: URL? { argument("-cueFakeClips").map { URL(filePath: $0) } }
  }
#endif
