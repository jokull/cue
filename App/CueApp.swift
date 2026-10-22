import SwiftData
import SwiftUI

@main
struct CueApp: App {
  var body: some Scene {
    WindowGroup {
      RecordingsView()
        .tint(.red)
    }
    .modelContainer(for: [Script.self, Take.self])
  }
}
