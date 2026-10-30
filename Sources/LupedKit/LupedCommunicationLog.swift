import Combine
import Foundation

/// The most recent watch communication events, newest last, kept in memory.
@MainActor
public final class LupedCommunicationLog: ObservableObject {
    public enum Kind {
        case toWatch, fromWatch, info, error
    }

    public struct Entry: Identifiable {
        public let id = UUID()
        public let date: Date
        public let kind: Kind
        public let message: String
    }

    public static let capacity = 500

    public init() {}

    @Published public private(set) var entries: [Entry] = []

    public func append(_ kind: Kind, _ message: String) {
        entries.append(Entry(date: Date(), kind: kind, message: message))
        if entries.count > Self.capacity {
            entries.removeFirst(entries.count - Self.capacity)
        }
    }

    public func clear() {
        entries.removeAll()
    }

    /// Plain text for sharing, oldest first.
    public var text: String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return entries.map { entry in
            let marker: String
            switch entry.kind {
            case .toWatch: marker = "→"
            case .fromWatch: marker = "←"
            case .info: marker = "·"
            case .error: marker = "!"
            }
            return "\(formatter.string(from: entry.date)) \(marker) \(entry.message)"
        }.joined(separator: "\n")
    }
}
