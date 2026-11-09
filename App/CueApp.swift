import SwiftData
import SwiftUI

@main
struct CueApp: App {
  var body: some Scene {
    WindowGroup {
      RecordingsView()
        .tint(.red)
        .task { CueVoice.shared.start() }
    }
    .modelContainer(for: [Script.self, Take.self])
  }
}
