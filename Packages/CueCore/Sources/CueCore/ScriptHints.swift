import Foundation

/// What to tell the speech service about the script before it hears it. Both made the opening
/// of Icelandic takes correct instead of garbled in testing (research/elevenlabs-api.md).
public enum ScriptHints {
  /// Context for the recognizer: up to `limit` characters of script, ending on a word boundary,
  /// leading up to word `index`. At the start of a take that's the script's opening; after a
  /// reconnect mid-take, the text just before the reader's position.
  public static func previousText(_ words: [ScriptWord], before index: Int = 0, limit: Int = 50) -> String {
    if index == 0 {
      var text = ""
      for word in words {
        let next = text.isEmpty ? word.text : text + " " + word.text
        guard next.count <= limit else { break }
        text = next
      }
      return text
    }
    var text = ""
    for word in words[..<min(index, words.count)].reversed() {
      let next = text.isEmpty ? word.text : word.text + " " + text
      guard next.count <= limit else { break }
      text = next
    }
    return text
  }

  /// The script's most distinctive words — names, compounds, rare terms — that a recognizer is
  /// likeliest to get wrong. Ranked by rarity in the script, then capitalization, then length.
  public static func keyterms(_ words: [ScriptWord], limit: Int = 50, maxLength: Int = 20) -> [String] {
    var counts: [String: Int] = [:]
    var spelling: [String: String] = [:]
    var capitalized: Set<String> = []
    for (index, word) in words.enumerated() {
      let clean = word.text.trimmingCharacters(in: .punctuationCharacters.union(.symbols))
      guard clean.count >= 5, clean.count <= maxLength, !word.key.isEmpty else { continue }
      counts[word.key, default: 0] += 1
      spelling[word.key] = spelling[word.key] ?? clean
      // A capital that doesn't start a sentence is a name.
      let startsSentence = index == 0 || words[index - 1].endsSentence
      if !startsSentence, clean.first?.isUppercase == true { capitalized.insert(word.key) }
    }
    return counts.keys
      .sorted { a, b in
        if counts[a]! != counts[b]! { return counts[a]! < counts[b]! }
        if capitalized.contains(a) != capitalized.contains(b) { return capitalized.contains(a) }
        if a.count != b.count { return a.count > b.count }
        return a < b
      }
      .prefix(limit)
      .compactMap { spelling[$0] }
  }
}
