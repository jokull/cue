import SwiftUI

/// Languages Cue Voice follows: ElevenLabs Scribe v2's excellent, high and good accuracy tiers
/// (≤ 20% word error rate). Left out: the moderate tier, and languages written without spaces
/// (Japanese, Mandarin, Cantonese, Thai, Burmese) — the script tracker matches space-separated
/// words, so it can't follow them yet.
enum VoiceLanguages {
  static let names = [
    "Afrikaans", "Arabic", "Armenian", "Assamese", "Asturian", "Azerbaijani", "Belarusian", "Bengali",
    "Bosnian", "Bulgarian", "Catalan", "Croatian", "Czech", "Danish", "Dutch", "English", "Estonian",
    "Filipino", "Finnish", "French", "Galician", "Georgian", "German", "Greek", "Gujarati", "Hausa",
    "Hebrew", "Hindi", "Hungarian", "Icelandic", "Indonesian", "Italian", "Javanese", "Kannada",
    "Kazakh", "Korean", "Kyrgyz", "Latvian", "Lithuanian", "Luxembourgish", "Macedonian", "Malay",
    "Malayalam", "Maltese", "Māori", "Marathi", "Nepali", "Norwegian", "Occitan", "Odia", "Persian",
    "Polish", "Portuguese", "Punjabi", "Romanian", "Russian", "Serbian", "Slovak", "Slovenian",
    "Spanish", "Swahili", "Swedish", "Tajik", "Tamil", "Telugu", "Turkish", "Ukrainian", "Uzbek",
    "Vietnamese", "Welsh",
  ]
}

struct VoiceLanguagesList: View {
  var body: some View {
    NavigationStack {
      List(VoiceLanguages.names, id: \.self) { Text($0) }
        .navigationTitle("\(VoiceLanguages.names.count) languages")
        .navigationBarTitleDisplayMode(.inline)
    }
  }
}
