import CueCore
import Photos
import SwiftUI

@Observable final class ExportModel {
  enum Captions: String, CaseIterable {
    case burned = "Burned in", off = "Off", sidecar = "Sidecar only"
  }

  enum State {
    case idle
    case exporting(Double)
    case done([URL])
    case failed(String)
  }

  var captions = Captions.burned
  var aspect = CaptionExporter.Aspect.portrait
  var quality = CaptionExporter.Quality.hd
  var codec = CaptionExporter.Codec.hevc
  /// Also write a clean master next to the captioned cut.
  var includesClean = false
  private(set) var state = State.idle
  private(set) var savedToPhotos = false

  var isExporting: Bool {
    if case .exporting = state { true } else { false }
  }

  func run(_ take: Take) async {
    state = .exporting(0)
    savedToPhotos = false
    let base = TakeFiles.exports.appending(path: "Cue \(take.title) \(take.number)".replacing("/", with: "-"))
    let timings = take.timings
    let settings = take.captionSettings
    var outputs: [URL] = []

    do {
      var request = CaptionExporter.Request(source: take.url, destination: base.appendingPathExtension("mp4"))
      request.aspect = aspect
      request.quality = quality
      request.codec = codec
      if aspect != .original, let face = await FaceFocus.horizontalCenter(of: take.url) {
        request.focusX = face
      }

      // Burned-in cut first; a clean master too when asked for, or when captions are off.
      let jobs: [(URL, Bool)] =
        switch captions {
        case .burned: [(base.appendingPathExtension("mp4"), true)] + (includesClean ? [(clean(base), false)] : [])
        case .off, .sidecar: [(base.appendingPathExtension("mp4"), false)]
        }
      for (index, job) in jobs.enumerated() {
        request.destination = job.0
        request.captions = job.1 ? (timings, settings) : nil
        let share = 1 / Double(jobs.count)
        try await CaptionExporter.export(request) { [weak self] fraction in
          Task { @MainActor in self?.state = .exporting((Double(index) + fraction) * share) }
        }
        outputs.append(job.0)
      }

      if captions == .sidecar {
        // Sidecars use readable sentence-sized cues whatever the burned-in style.
        let pages = CaptionPager.pages(timings, rules: CaptionStyleID.pro.pagingRules)
        for format in Subtitles.Format.allCases {
          let url = base.appendingPathExtension(format.fileExtension)
          try Subtitles.render(pages, as: format).write(to: url, atomically: true, encoding: .utf8)
          outputs.append(url)
        }
      }
      state = .done(outputs)
    } catch {
      state = .failed(error.localizedDescription)
    }
  }

  func saveToPhotos(_ urls: [URL]) async {
    guard await PHPhotoLibrary.requestAuthorization(for: .addOnly) == .authorized else {
      state = .failed("Cue needs permission to add videos to Photos.")
      return
    }
    do {
      try await PHPhotoLibrary.shared().performChanges(Self.addVideos(urls))
      savedToPhotos = true
    } catch {
      state = .failed(error.localizedDescription)
    }
  }

  /// Photos runs change blocks on its own queue, so this must not be main-actor isolated.
  private nonisolated static func addVideos(_ urls: [URL]) -> @Sendable () -> Void {
    {
      for url in urls where url.pathExtension == "mp4" {
        PHAssetCreationRequest.creationRequestForAssetFromVideo(atFileURL: url)
      }
    }
  }

  private func clean(_ base: URL) -> URL {
    base.deletingLastPathComponent().appending(path: base.lastPathComponent + " clean.mp4")
  }
}

struct ExportSheet: View {
  let take: Take
  @State private var model = ExportModel()
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    NavigationStack {
      Form {
        Section("Captions") {
          Picker("Captions", selection: $model.captions) {
            ForEach(ExportModel.Captions.allCases, id: \.self) { Text($0.rawValue) }
          }
          .pickerStyle(.segmented)
          if model.captions == .burned {
            Toggle("Also export a clean master", isOn: $model.includesClean)
            LabeledContent("Style", value: take.captionSettings.style.displayName)
          }
          if model.captions == .sidecar {
            Text("A clean video plus .srt and .vtt files with your word timings.")
              .font(.footnote)
              .foregroundStyle(.secondary)
          }
        }
        .disabled(model.isExporting)
        Section {
          Picker("Format", selection: $model.aspect) {
            ForEach(CaptionExporter.Aspect.allCases) { Text($0.label).tag($0) }
          }
          Picker("Quality", selection: $model.quality) {
            ForEach(CaptionExporter.Quality.allCases, id: \.self) { Text($0.label).tag($0) }
          }
          Picker("Codec", selection: $model.codec) {
            ForEach(CaptionExporter.Codec.allCases, id: \.self) { Text($0.label).tag($0) }
          }
        } footer: {
          Text("Crops follow your face.")
        }
        .disabled(model.isExporting)
        Section {
          result
        }
      }
      .navigationTitle("Export")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
      }
    }
  }

  @ViewBuilder private var result: some View {
    switch model.state {
    case .idle, .failed:
      if case .failed(let message) = model.state {
        Text(message).foregroundStyle(.red).font(.footnote)
      }
      Button("Export") { Task { await model.run(take) } }
        .frame(maxWidth: .infinity)
        .fontWeight(.semibold)
    case .exporting(let fraction):
      ProgressView(value: fraction) { Text("Exporting…") }
    case .done(let urls):
      ShareLink(items: urls) {
        Label("Share \(urls.count == 1 ? "video" : "\(urls.count) files")", systemImage: "square.and.arrow.up")
      }
      Button(model.savedToPhotos ? "Saved to Photos" : "Save to Photos", systemImage: model.savedToPhotos ? "checkmark" : "photo.on.rectangle") {
        Task { await model.saveToPhotos(urls) }
      }
      .disabled(model.savedToPhotos)
      Button("Export again", systemImage: "arrow.clockwise") { Task { await model.run(take) } }
    }
  }
}
