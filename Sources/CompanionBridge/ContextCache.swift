import CompanionCore

struct ConnectionID: Hashable, Sendable, CustomStringConvertible {
    let raw: UInt64
    var description: String { "c\(raw)" }
}

/// The latest pushed context per (connection, tab). Separate from the server actor so the hot-path
/// read never waits behind socket or PDF work.
actor ContextCache {
    private struct Key: Hashable {
        let connection: ConnectionID
        let tabId: Int
    }

    private var snapshots: [Key: TabContext] = [:]
    private var activations: [ConnectionID: (tabId: Int, order: UInt64)] = [:]
    private var order: UInt64 = 0
    /// Connection ids are never reused. A late message or answer from a closed one must not bring it back.
    private var closed: Set<ConnectionID> = []

    init() {}

    func apply(_ message: ExtensionToApp, from connection: ConnectionID) {
        guard !closed.contains(connection) else { return }
        switch message {
        case .tabActivated(let activated):
            activations[connection] = (activated.tabId, nextOrder())
        case .tabContext(let context):
            snapshots[Key(connection: connection, tabId: context.tabId)] = context
        case .youtubePlayhead(let playhead):
            let key = Key(connection: connection, tabId: playhead.tabId)
            guard var context = snapshots[key], var youtube = context.youtube,
                  youtube.videoId == playhead.videoId else { return }
            youtube.playheadSeconds = playhead.playheadSeconds
            youtube.chapter = playhead.chapter
            context.youtube = youtube
            snapshots[key] = context
        case .tabClosed(let tabId):
            snapshots[Key(connection: connection, tabId: tabId)] = nil
            if activations[connection]?.tabId == tabId { activations[connection] = nil }
        case .hello, .response, .progress:
            break
        }
    }

    /// Stores a `getTabContext` answer. It activates its tab only when nothing is active: an answer can
    /// race a tab switch, and only `tabActivated` may move an existing activation.
    func store(_ context: TabContext, from connection: ConnectionID) {
        guard !closed.contains(connection) else { return }
        snapshots[Key(connection: connection, tabId: context.tabId)] = context
        if activeConnection() == nil {
            activations[connection] = (context.tabId, nextOrder())
        }
    }

    func connectionClosed(_ connection: ConnectionID) {
        closed.insert(connection)
        snapshots = snapshots.filter { $0.key.connection != connection }
        activations[connection] = nil
    }

    /// The active tab's own snapshot, or nil. Never falls back to another tab.
    func activeTabContext() -> TabContext? {
        guard let connection = activeConnection(), let tabId = activations[connection]?.tabId else { return nil }
        return snapshots[Key(connection: connection, tabId: tabId)]
    }

    func activeConnection() -> ConnectionID? {
        activations.max { $0.value.order < $1.value.order }?.key
    }

    func connection(forTab tabId: Int) -> ConnectionID? {
        snapshots.keys
            .filter { $0.tabId == tabId }
            .map(\.connection)
            .max { rank($0) < rank($1) }
    }

    /// Connections that never activated rank lowest; ties go to the newer connection.
    private func rank(_ connection: ConnectionID) -> (UInt64, UInt64) {
        (activations[connection].map { $0.order + 1 } ?? 0, connection.raw)
    }

    private func nextOrder() -> UInt64 {
        order += 1
        return order
    }
}
