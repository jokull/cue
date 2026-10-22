import AVFoundation
import CueCore
import SwiftData
import SwiftUI

struct RecordingsView: View {
  enum Filter: String, CaseIterable {
    case all = "All", drafts = "Drafts", favorites = "Favorites"
  }

  @Environment(\.modelContext) private var context
  @Query(sort: \Take.createdAt, order: .reverse) private var takes: [Take]
  @Query(sort: \Script.createdAt, order: .reverse) private var scripts: [Script]

  @State private var filter = Filter.all
  @State private var search = ""
  @State private var composerOpen = false
  @State private var draft = ""
  @State private var editingScript: Script?
  @State private var recording: Script?
  @State private var path: [Take] = []
  @State private var askingConsent = false

  private var visibleTakes: [Take] {
    takes.filter { take in
      (filter != .favorites || take.isFavorite)
        && (search.isEmpty || take.title.localizedStandardContains(search) || (take.script?.text.localizedStandardContains(search) ?? false))
    }
  }

  private var drafts: [Script] {
    scripts.filter { $0.takes.isEmpty && (search.isEmpty || $0.text.localizedStandardContains(search)) }
  }

  var body: some View {
    NavigationStack(path: $path) {
      // A List, not a scroll stack, so rows get the system swipe actions.
      List {
        Group {
          VStack(alignment: .leading, spacing: 14) {
            header
            chips
            searchField
          }
          .padding(.top, 8)
          if filter == .drafts {
            ForEach(drafts) { script in
              Button { open(script) } label: { DraftRow(script: script) }
                .buttonStyle(.plain)
                .swipeActions(edge: .trailing) {
                  Button("Delete", systemImage: "trash", role: .destructive) { context.delete(script) }
                }
            }
          } else {
            ForEach(visibleTakes) { take in
              // An invisible link under the row: List would otherwise add a second chevron.
              TakeRow(take: take)
                .background { NavigationLink(value: take) { EmptyView() }.opacity(0) }
                .contextMenu { menu(for: take) }
                .swipeActions(edge: .trailing) {
                  Button("Delete", systemImage: "trash", role: .destructive) { delete(take) }
                }
                .swipeActions(edge: .leading) {
                  Button(take.isFavorite ? "Unfavorite" : "Favorite", systemImage: take.isFavorite ? "star.slash" : "star") {
                    take.isFavorite.toggle()
                  }
                  .tint(.yellow)
                }
            }
          }
          if takes.isEmpty && filter == .all {
            emptyState
          }
        }
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
        .listRowInsets(EdgeInsets(top: 5, leading: 16, bottom: 5, trailing: 16))
      }
      .listStyle(.plain)
      .scrollContentBackground(.hidden)
      .background(Color(.systemGroupedBackground))
      .toolbar {
        ToolbarItem(placement: .topBarLeading) {
          Menu("More", systemImage: "line.3.horizontal") {
            Button("Add demo take", systemImage: "sparkles") { addDemo() }
            Divider()
            Link(destination: URL(string: "https://cue.solberg.is/support")!) {
              Label("Help & support", systemImage: "questionmark.circle")
            }
            Link(destination: URL(string: "https://cue.solberg.is/privacy")!) {
              Label("Privacy policy", systemImage: "hand.raised")
            }
          }
        }
        ToolbarItem(placement: .topBarTrailing) {
          Button("New script", systemImage: "plus") { open(nil) }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.circle)
        }
      }
      .navigationDestination(for: Take.self) { take in
        TakeView(take: take)
      }
    }
    .overlay(alignment: .top) {
      ScriptComposer(isOpen: $composerOpen, text: $draft) {
        startRecording()
      }
    }
    #if DEBUG
      // Screens to land on for simulator screenshots: -cueDemo, -cueCompose.
      .task {
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("-cueDemo") { addDemo() }
        if arguments.contains("-cueSeed") { DemoTake.seed(in: context) }
        if !arguments.contains("-cueFakeCamera"), let video = DemoTake.argument("-cueTakeVideo"),
          let script = DemoTake.argument("-cueTakeScript"),
          let take = DemoTake.fromFiles(video: video, script: script, in: context)
        {
          path.append(take)
        }
        if arguments.contains("-cueFakeCamera") {
          let text = DemoTake.argument("-cueTakeScript").flatMap { try? String(contentsOfFile: $0, encoding: .utf8) }
          let script = Script(text: text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? DemoTake.script)
          context.insert(script)
          recording = script
        }
        if arguments.contains("-cueCompose") {
          open(nil)
          draft = DemoTake.script
        }
      }
    #endif
    .alert("Let Cue listen as you read?", isPresented: $askingConsent) {
      Button("Not now", role: .cancel) {
        CloudConsent.granted = false
        startRecording()
      }
      Button("Allow") {
        CloudConsent.granted = true
        startRecording()
      }
    } message: {
      Text("Your voice is sent to ElevenLabs as you record, so the script follows you and your captions are timed to your words. Cue doesn't keep it. Without this, the script scrolls at a steady pace.")
    }
    .fullScreenCover(item: $recording) { script in
      RecordView(model: RecordModel(script: script)) { take in
        path.append(take)
      } onDemo: {
        addDemo()
      }
    }
  }

  private var header: some View {
    VStack(alignment: .leading, spacing: 2) {
      Text("Recordings.")
        .font(.largeTitle.weight(.bold))
      let minutes = Int((takes.reduce(0) { $0 + $1.duration } / 60).rounded())
      Text("\(takes.count) takes · \(minutes) min recorded")
        .font(.footnote)
        .foregroundStyle(.secondary)
    }
  }

  private var chips: some View {
    HStack(spacing: 6) {
      ForEach(Filter.allCases, id: \.self) { option in
        Button(option.rawValue) {
          withAnimation(.snappy) { filter = option }
        }
        .font(.footnote.weight(.semibold))
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .foregroundStyle(filter == option ? Color(.systemBackground) : .primary)
        .background(filter == option ? Color.primary : Color(.secondarySystemGroupedBackground), in: Capsule())
      }
    }
  }

  private var searchField: some View {
    HStack {
      Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
      TextField("Search recordings", text: $search)
    }
    .font(.subheadline)
    .padding(10)
    .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
  }

  private var emptyState: some View {
    VStack(spacing: 12) {
      Text("Paste a script, hit record, just talk.")
        .font(.headline)
      Text("The script follows your voice, and your captions are done when you stop.")
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
      Button("Add a demo take", systemImage: "sparkles") { addDemo() }
        .buttonStyle(.bordered)
    }
    .frame(maxWidth: .infinity)
    .padding(.vertical, 48)
  }

  @ViewBuilder private func menu(for take: Take) -> some View {
    Button(take.isFavorite ? "Unfavorite" : "Favorite", systemImage: take.isFavorite ? "star.slash" : "star") {
      take.isFavorite.toggle()
    }
    if let script = take.script {
      Button("Record another take", systemImage: "record.circle") { recording = script }
    }
    Button("Delete", systemImage: "trash", role: .destructive) { delete(take) }
  }

  private func delete(_ take: Take) {
    withAnimation {
      try? FileManager.default.removeItem(at: take.url)
      context.delete(take)
    }
  }

  private func open(_ script: Script?) {
    editingScript = script
    draft = script?.text ?? ""
    withAnimation(.spring(duration: 0.5, bounce: 0.25)) { composerOpen = true }
  }

  private func startRecording() {
    let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !ScriptText.words(text).isEmpty else { return }
    guard CloudConsent.asked else {
      askingConsent = true
      return
    }
    let script: Script
    if let editingScript {
      editingScript.text = text
      editingScript.title = Script.title(for: text)
      script = editingScript
    } else {
      script = Script(text: text)
      context.insert(script)
    }
    withAnimation(.spring(duration: 0.4, bounce: 0.1)) { composerOpen = false }
    recording = script
  }

  private func addDemo() {
    guard let take = DemoTake.make(in: context) else { return }
    path.append(take)
  }
}

struct TakeRow: View {
  let take: Take

  var body: some View {
    HStack(spacing: 12) {
      Thumbnail(url: take.url)
        .frame(width: 44, height: 44)
        .clipShape(RoundedRectangle(cornerRadius: 9))
        .overlay(alignment: .bottomLeading) {
          Text(timecode(take.duration).replacing(/^0/, with: ""))
            .font(.system(size: 8, weight: .bold))
            .monospacedDigit()
            .padding(.horizontal, 3)
            .background(.black.opacity(0.6), in: Capsule())
            .foregroundStyle(.white)
            .padding(3)
        }
      VStack(alignment: .leading, spacing: 2) {
        HStack(spacing: 4) {
          Text(take.title).font(.subheadline.weight(.semibold)).lineLimit(1)
          if take.isFavorite { Image(systemName: "star.fill").font(.caption2).foregroundStyle(.yellow) }
        }
        Text("\(take.createdAt.recordingStamp) · Take \(take.number)")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      Spacer()
      Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
    }
    .padding(10)
    .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
  }
}

struct DraftRow: View {
  let script: Script

  var body: some View {
    HStack(spacing: 12) {
      Image(systemName: "text.alignleft")
        .frame(width: 44, height: 44)
        .background(Color(.tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 9))
      VStack(alignment: .leading, spacing: 2) {
        Text(script.title).font(.subheadline.weight(.semibold)).lineLimit(1)
        Text(script.summary).font(.caption).foregroundStyle(.secondary)
      }
      Spacer()
    }
    .padding(10)
    .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
  }
}

struct Thumbnail: View {
  let url: URL
  @State private var image: CGImage?

  var body: some View {
    ZStack {
      Color(.tertiarySystemFill)
      if let image {
        Image(decorative: image, scale: 1).resizable().scaledToFill()
      }
    }
    .task(id: url) {
      let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
      generator.appliesPreferredTrackTransform = true
      generator.maximumSize = CGSize(width: 160, height: 160)
      image = try? await generator.image(at: CMTime(seconds: 0.5, preferredTimescale: 600)).image
    }
  }
}

extension Date {
  /// "Today, 9:12 AM", "Yesterday, 6:40 PM", "Mon, Oct 19"
  var recordingStamp: String {
    let calendar = Calendar.current
    let time = formatted(date: .omitted, time: .shortened)
    if calendar.isDateInToday(self) { return "Today, \(time)" }
    if calendar.isDateInYesterday(self) { return "Yesterday, \(time)" }
    return formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
  }
}

enum DemoTake {
  static let script = """
    Hey friends. We just shipped something I'm really proud of. You write your script, hit record, \
    and simply talk. The words follow your voice, and when you stop, your captions are already done.
    """

  #if DEBUG
    static func argument(_ flag: String) -> String? {
      let arguments = ProcessInfo.processInfo.arguments
      guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
      return arguments[index + 1]
    }

    /// A take built from a video and a script on the Mac (the Simulator can read host paths),
    /// with no precomputed timings — it goes through the same alignment as a recorded take.
    static func fromFiles(video: String, script: String, in context: ModelContext) -> Take? {
      guard let text = try? String(contentsOfFile: script, encoding: .utf8) else { return nil }
      let destination = TakeFiles.newTakeURL()
      guard (try? FileManager.default.copyItem(at: URL(filePath: video), to: destination)) != nil else { return nil }
      let script = Script(text: text.trimmingCharacters(in: .whitespacesAndNewlines))
      context.insert(script)
      let take = Take(script: script, fileName: destination.lastPathComponent, duration: 10)
      context.insert(take)
      script.takes.append(take)
      return take
    }

    /// A believable library for screenshots: several scripts, some with retakes.
    static func seed(in context: ModelContext) {
      let library: [(String, Int, Bool)] = [
        ("Q3 launch keynote. Today we're launching the thing we've been building for two years.", 3, true),
        ("Weekly update for the team. Three wins, one miss, and what's next.", 1, false),
        ("Podcast intro, episode 14. This week: why your first draft should be spoken.", 2, false),
        ("Course trailer. In ten short lessons you'll learn to speak to camera like a pro.", 1, true),
      ]
      for (index, (text, takes, favorite)) in library.enumerated().reversed() {
        guard let take = make(in: context) else { return }
        let script = take.script!
        script.text = text
        script.title = Script.title(for: text)
        take.isFavorite = favorite
        take.createdAt = .now.addingTimeInterval(Double(-index) * 30_000 - 600)
        take.number = takes
        take.timings = Aligner.estimate(script: script.words, duration: take.duration)
        take.timingQuality = .estimated
      }
    }
  #endif

  /// A narrated clip bundled with the app, for trying captions without a camera.
  static func make(in context: ModelContext) -> Take? {
    guard let source = Bundle.main.url(forResource: "demo", withExtension: "mp4") else { return nil }
    let destination = TakeFiles.newTakeURL()
    guard (try? FileManager.default.copyItem(at: source, to: destination)) != nil else { return nil }
    let script = Script(text: script)
    context.insert(script)
    let take = Take(script: script, fileName: destination.lastPathComponent, duration: 11.3)
    // Word timestamps recognized from the clip's own audio ahead of time (Whisper), aligned
    // here exactly as a recorded take would be — so the demo works where speech can't run.
    if let url = Bundle.main.url(forResource: "demo-words", withExtension: "json"),
      let data = try? Data(contentsOf: url),
      let heard = try? JSONDecoder().decode([RecognizedWord].self, from: data)
    {
      take.timings = Aligner.align(script: script.words, heard: heard)
      take.timingQuality = .voice
    }
    context.insert(take)
    script.takes.append(take)
    return take
  }
}
