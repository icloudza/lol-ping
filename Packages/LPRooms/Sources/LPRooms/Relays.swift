import Foundation

public enum Relays {
    /// Public Nostr relays that carry internet rooms. Every member connects to all of them, so two members meet as
    /// long as they share one that works.
    ///
    /// The list is upstream lolPing 0.5.1's, unchanged (chosen there with tools/relay-probe on 2026-10-05).
    ///
    /// Compatibility rule: a later version must keep at least 3 relays from the previous version's list, or old and
    /// new versions can no longer find each other.
    public static let all: [String] = [
        "wss://nos.lol",
        "wss://nostr.mom",
        "wss://relay.snort.social",
        "wss://relay.agentry.com",
        "wss://relay.routstr.com",
        "wss://nostr.rblb.it",
    ]
}
