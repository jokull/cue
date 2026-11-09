import StoreKit
import SwiftUI

/// The Cue Voice subscription: the script follows your voice, and captions are timed to your
/// words. Without it Cue is a manual prompter — the thumb scrolls the script — and takes have no
/// captions. Each request to the speech service carries the signed transaction, which the Worker
/// verifies and meters.
@Observable final class CueVoice {
  static let shared = CueVoice()
  static let groupID = "22518543"
  static let productIDs = ["is.solberg.cue.voice.yearly"]

  private(set) var isSubscribed = false
  /// Whether the free week still applies to this Apple Account; Cue only promises it then.
  private(set) var trialEligible = false
  /// The current entitlement's signed transaction, for the speech service.
  @ObservationIgnored private(set) var signedTransaction: String?
  @ObservationIgnored private var updates: Task<Void, Never>?

  private init() {
    #if DEBUG
      // Screenshots and Simulator runs without a sandbox purchase.
      if ProcessInfo.processInfo.arguments.contains("-cueVoice") { isSubscribed = true }
    #endif
  }

  /// Reads the current entitlement and follows renewals, refunds and purchases made elsewhere.
  func start() {
    guard updates == nil else { return }
    updates = Task { [weak self] in
      await self?.refresh()
      for await _ in StoreKit.Transaction.updates {
        await self?.refresh()
      }
    }
  }

  func refresh() async {
    var current: VerificationResult<StoreKit.Transaction>?
    for await result in StoreKit.Transaction.currentEntitlements {
      guard case .verified(let transaction) = result, Self.productIDs.contains(transaction.productID),
        transaction.revocationDate == nil
      else { continue }
      current = result
      await transaction.finish()
    }
    signedTransaction = current?.jwsRepresentation
    trialEligible = await Product.SubscriptionInfo.isEligibleForIntroOffer(for: Self.groupID)
    #if DEBUG
      if ProcessInfo.processInfo.arguments.contains("-cueVoice") { return }
    #endif
    isSubscribed = current != nil
  }
}

/// The upsell: what Cue Voice adds, the plan, and — once subscribed — the one-time permission to
/// send audio to ElevenLabs (Guideline 5.1.2(i)), asked here so it follows the purchase directly.
/// A subscriber who said "Not now" lands on the permission again, not the plans.
struct CueVoicePaywall: View {
  @Environment(\.dismiss) private var dismiss
  @State private var voice = CueVoice.shared
  @State private var showsLanguages = false

  var body: some View {
    Group {
      if voice.isSubscribed && !CloudConsent.granted {
        consent
      } else {
        SubscriptionStoreView(groupID: CueVoice.groupID) {
          marketing
        }
        // One plan: its button is the whole picker.
        .subscriptionStoreControlStyle(.buttons)
        .subscriptionStoreButtonLabel(.multiline)
        .storeButton(.visible, for: .restorePurchases)
        .subscriptionStorePolicyDestination(url: URL(string: "https://cue.solberg.is/terms")!, for: .termsOfService)
        .subscriptionStorePolicyDestination(url: URL(string: "https://cue.solberg.is/privacy")!, for: .privacyPolicy)
        .onInAppPurchaseCompletion { _, result in
          if case .success(.success) = result { await voice.refresh() }
        }
      }
    }
    .tint(.red)
    .onChange(of: voice.isSubscribed) { _, subscribed in
      if subscribed && CloudConsent.asked { dismiss() }
    }
  }

  private var marketing: some View {
    VStack(spacing: 14) {
      VStack(spacing: 2) {
        Text("Cue Voice")
          .font(.title.bold())
        Text(voice.trialEligible ? "Try it free for a week." : "The script follows you. Captions write themselves.")
          .font(.subheadline)
          .foregroundStyle(.secondary)
      }
      .multilineTextAlignment(.center)
      comparison
      Button { showsLanguages = true } label: {
        Label("\(VoiceLanguages.names.count) languages, including English and Icelandic", systemImage: "globe")
          .font(.footnote.weight(.semibold))
          .foregroundStyle(.red)
      }
      // The store view styles every button as its purchase button; this one is a link.
      .buttonStyle(.plain)
      // The name only, not ElevenLabs' logo: their brand page doesn't grant third parties its use.
      Text("Powered by **ElevenLabs** frontier speech recognition, included in the subscription.")
        .font(.caption)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
    }
    .padding(.horizontal, 16)
    .padding(.top, 8)
    .sheet(isPresented: $showsLanguages) { VoiceLanguagesList().presentationDetents([.medium, .large]) }
  }

  /// Free next to Cue Voice: a nil cell is a feature that tier doesn't have, "✓" one it does.
  private let rows: [(feature: String, free: String?, voice: String)] = [
    ("Record & export", "✓", "✓"),
    ("Scrolling", "Thumb", "Voice"),
    ("Steady auto-scroll", nil, "✓"),
    ("Word-timed captions", nil, "✓"),
  ]

  private var comparison: some View {
    Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 8) {
      GridRow {
        Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
        Text("Free").gridColumnAlignment(.center)
        Text("Cue Voice").foregroundStyle(.red).gridColumnAlignment(.center)
      }
      .font(.caption.weight(.semibold))
      ForEach(rows, id: \.feature) { row in
        Divider().gridCellUnsizedAxes(.horizontal)
        GridRow {
          // The feature names never truncate; the narrow tier columns give way first.
          Text(row.feature).fixedSize()
            .frame(maxWidth: .infinity, alignment: .leading)
          cell(row.free).foregroundStyle(.secondary)
          cell(row.voice).fontWeight(.semibold)
        }
      }
    }
    .font(.subheadline)
    .padding(12)
    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
  }

  @ViewBuilder private func cell(_ value: String?) -> some View {
    switch value {
    case nil: Image(systemName: "minus").foregroundStyle(.tertiary)
    case "✓": Image(systemName: "checkmark")
    case let text?: Text(text)
    }
  }

  private var consent: some View {
    VStack(spacing: 20) {
      Spacer()
      Image(systemName: "ear")
        .font(.system(size: 44, weight: .semibold))
        .foregroundStyle(.red)
      Text("Let Cue listen as you read?")
        .font(.title2.bold())
        .multilineTextAlignment(.center)
      Text("Your voice is sent to ElevenLabs as you record, so the script follows you and your captions are timed to your words. Cue doesn't keep it.")
        .multilineTextAlignment(.center)
        .foregroundStyle(.secondary)
      Spacer()
      Button {
        CloudConsent.granted = true
        dismiss()
      } label: {
        Text("Allow").frame(maxWidth: .infinity)
      }
      .buttonStyle(.borderedProminent)
      .controlSize(.large)
      Button("Not now") {
        CloudConsent.granted = false
        dismiss()
      }
    }
    .padding(24)
  }
}
