import AVFoundation

/// Front camera and microphone into an mp4, with the microphone also fed to speech recognition.
///
/// One capture queue owns the session outputs and the writer, which is why this is
/// `@unchecked Sendable`: every mutable property below is only touched on `queue`.
nonisolated final class CameraRecorder: NSObject, @unchecked Sendable {
  enum Failure: LocalizedError {
    case noCamera, noMicrophone, notAuthorized, cannotWrite

    var errorDescription: String? {
      switch self {
      case .noCamera: "No front camera is available. The Simulator has none — try the demo take."
      case .noMicrophone: "No microphone is available."
      case .notAuthorized: "Cue needs camera and microphone access. You can allow it in Settings."
      case .cannotWrite: "Couldn't start writing the recording."
      }
    }
  }

  let session = AVCaptureSession()
  private let queue = DispatchQueue(label: "is.solberg.cue.capture")
  private let videoOutput = AVCaptureVideoDataOutput()
  private let audioOutput = AVCaptureAudioDataOutput()

  private var writer: AVAssetWriter?
  private var videoInput: AVAssetWriterInput?
  private var audioInput: AVAssetWriterInput?
  private var isRecording = false
  private var firstFrame: CMTime?
  private var lastFrame: CMTime = .zero
  private var onAudio: (@Sendable (CMSampleBuffer) -> Void)?

  static func requestAccess() async -> Bool {
    let video = await AVCaptureDevice.requestAccess(for: .video)
    let audio = await AVCaptureDevice.requestAccess(for: .audio)
    return video && audio
  }

  func configure(onAudio: @escaping @Sendable (CMSampleBuffer) -> Void) async throws {
    guard await Self.requestAccess() else { throw Failure.notAuthorized }
    try await perform {
      self.onAudio = onAudio
      guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front) else {
        throw Failure.noCamera
      }
      guard let microphone = AVCaptureDevice.default(for: .audio) else { throw Failure.noMicrophone }

      self.session.beginConfiguration()
      defer { self.session.commitConfiguration() }
      self.session.sessionPreset = .hd1920x1080
      for input in [try AVCaptureDeviceInput(device: camera), try AVCaptureDeviceInput(device: microphone)]
      where self.session.canAddInput(input) {
        self.session.addInput(input)
      }
      for output in [self.videoOutput, self.audioOutput] as [AVCaptureOutput] where self.session.canAddOutput(output) {
        self.session.addOutput(output)
      }
      self.videoOutput.setSampleBufferDelegate(self, queue: self.queue)
      self.audioOutput.setSampleBufferDelegate(self, queue: self.queue)

      // Rotate buffers upright so the file plays portrait with no transform.
      if let connection = self.videoOutput.connection(with: .video) {
        let angle = AVCaptureDevice.RotationCoordinator(device: camera, previewLayer: nil)
          .videoRotationAngleForHorizonLevelCapture
        if connection.isVideoRotationAngleSupported(angle) { connection.videoRotationAngle = angle }
        // The preview mirrors the front camera like a mirror; record it the same way, or the take
        // plays back flipped left-to-right from what the reader saw while filming.
        if connection.isVideoMirroringSupported {
          connection.automaticallyAdjustsVideoMirroring = false
          connection.isVideoMirrored = true
        }
      }
    }
  }

  func startRunning() {
    queue.async { if !self.session.isRunning { self.session.startRunning() } }
  }

  func stopRunning() {
    queue.async { if self.session.isRunning { self.session.stopRunning() } }
  }

  func startRecording(to url: URL) async throws {
    try await perform {
      let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
      let video = AVAssetWriterInput(
        mediaType: .video,
        outputSettings: self.videoOutput.recommendedVideoSettingsForAssetWriter(writingTo: .mp4))
      let audio = AVAssetWriterInput(
        mediaType: .audio,
        outputSettings: self.audioOutput.recommendedAudioSettingsForAssetWriter(writingTo: .mp4))
      for input in [video, audio] {
        input.expectsMediaDataInRealTime = true
        guard writer.canAdd(input) else { throw Failure.cannotWrite }
        writer.add(input)
      }
      self.writer = writer
      self.videoInput = video
      self.audioInput = audio
      self.firstFrame = nil
      self.isRecording = true
    }
  }

  /// Finishes the file and returns its duration.
  func finishRecording() async -> TimeInterval {
    await withCheckedContinuation { continuation in
      queue.async {
        self.isRecording = false
        guard let writer = self.writer, writer.status == .writing, let first = self.firstFrame else {
          self.writer?.cancelWriting()
          self.writer = nil
          continuation.resume(returning: 0)
          return
        }
        let duration = (self.lastFrame - first).seconds
        self.videoInput?.markAsFinished()
        self.audioInput?.markAsFinished()
        writer.endSession(atSourceTime: self.lastFrame)
        writer.finishWriting {
          continuation.resume(returning: duration)
        }
        self.writer = nil
      }
    }
  }

  private func perform(_ work: @escaping @Sendable () throws -> Void) async throws {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
      queue.async {
        do {
          try work()
          continuation.resume()
        } catch {
          continuation.resume(throwing: error)
        }
      }
    }
  }
}

// `nonisolated` on the class doesn't reach its extensions; without it this would be main-actor
// isolated and trap when AVFoundation calls it on the capture queue.
nonisolated extension CameraRecorder: AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
  func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
    guard isRecording, let writer else { return }
    let time = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

    if output === videoOutput {
      // The file starts on a video frame so it never opens on black.
      if firstFrame == nil {
        guard writer.startWriting() else { return }
        writer.startSession(atSourceTime: time)
        firstFrame = time
      }
      if videoInput?.isReadyForMoreMediaData == true, videoInput?.append(sampleBuffer) == true {
        lastFrame = time
      }
    } else if firstFrame != nil {
      if audioInput?.isReadyForMoreMediaData == true { audioInput?.append(sampleBuffer) }
      onAudio?(sampleBuffer)
    }
  }
}
