import Foundation

public protocol BrowserContextProviding: Sendable {
    /// No I/O; the most recently activated tab across connected browsers.
    func cachedActiveTabContext() async -> TabContext?
    /// Asks the extension; nil on timeout or disconnect.
    func requestActiveTabContext(timeout: Duration) async -> TabContext?
    func isConnected() async -> Bool
}

public protocol DocumentFetching: Sendable {
    /// Throws `BridgeError`.
    func fetchDrivePDF(fileId: String) async throws -> (data: Data, title: String)
}

public struct ViewerInfo: Codable, Sendable, Equatable {
    public var pageCount: Int
    /// 0-based.
    public var currentIndex: Int

    public init(pageCount: Int, currentIndex: Int) {
        self.pageCount = pageCount
        self.currentIndex = currentIndex
    }
}

public protocol ViewerDriving: Sendable {
    func viewerInfo(tabId: Int) async throws -> ViewerInfo
    func capturePage(tabId: Int, pageIndex: Int) async throws -> ImageAttachment
    func restore(tabId: Int, pageIndex: Int) async throws
}
