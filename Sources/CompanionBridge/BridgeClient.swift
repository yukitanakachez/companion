import CompanionCore
import Foundation
import ImageIO

/// Adapts `BridgeServer` to the CompanionCore service protocols.
struct BridgeClient: BrowserContextProviding {
    let server: BridgeServer

    func cachedActiveTabContext() async -> TabContext? {
        await server.cache.activeTabContext()
    }

    func requestActiveTabContext(timeout: Duration) async -> TabContext? {
        guard let target = await server.requestTarget() else { return nil }
        do {
            let outcome = try await perform(on: target, timeout: timeout) { .getTabContext(id: $0, tabId: nil) }
            guard let context = try outcome.response.decodeResult(TabContextResult.self).context else { return nil }
            await server.cache.store(context, from: target)
            return context
        } catch {
            return nil
        }
    }

    func isConnected() async -> Bool {
        await server.hasAuthenticatedSession()
    }

    private func perform(on target: ConnectionID, timeout: Duration,
                         _ makeRequest: @escaping @Sendable (String) -> BridgeRequest) async throws -> RequestOutcome {
        try await server.multiplexer.perform(on: target, timeout: timeout, makeRequest) { [server] request in
            try await server.send(.request(request), to: target)
        }
    }
}

extension BridgeClient: DocumentFetching, ViewerDriving {
    func fetchDrivePDF(fileId: String) async throws -> (data: Data, title: String) {
        try await mappingErrors {
            guard let target = await server.requestTarget() else { throw Self.notConnected }
            let outcome = try await perform(on: target, timeout: server.timings.drivePdfTimeout) {
                .fetchDrivePdf(id: $0, fileId: fileId)
            }
            let result = try outcome.response.decodeResult(DrivePdfResult.self)
            guard result.fileId == fileId else {
                throw BridgeError(code: .internal, message: "Asked for file \(fileId), got \(result.fileId)")
            }
            // Runs on the caller's task, not on any actor.
            let data = try outcome.chunks?.assemble() ?? Data()
            guard data.count == result.byteLength else {
                throw BridgeError(code: .internal, message: "PDF size mismatch: expected \(result.byteLength) bytes, got \(data.count)")
            }
            return (data, result.title)
        }
    }

    func viewerInfo(tabId: Int) async throws -> ViewerInfo {
        try await mappingErrors {
            try await viewerRequest(tabId: tabId) { .viewerInfo(id: $0, tabId: tabId) }
                .response.decodeResult(ViewerInfo.self)
        }
    }

    func capturePage(tabId: Int, pageIndex: Int) async throws -> ImageAttachment {
        try await mappingErrors {
            let result = try await viewerRequest(tabId: tabId) { .viewerCapturePage(id: $0, tabId: tabId, pageIndex: pageIndex) }
                .response.decodeResult(ViewerPageResult.self)
            guard result.pageIndex == pageIndex else {
                throw BridgeError(code: .internal, message: "Asked for viewer page \(pageIndex), got \(result.pageIndex)")
            }
            return try Self.imageAttachment(fromBase64: result.pngBase64)
        }
    }

    func restore(tabId: Int, pageIndex: Int) async throws {
        try await mappingErrors {
            _ = try await viewerRequest(tabId: tabId) { .viewerRestore(id: $0, tabId: tabId, pageIndex: pageIndex) }
        }
    }

    static func imageAttachment(fromBase64 png: String) throws -> ImageAttachment {
        guard let data = Data(base64Encoded: png),
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else {
            throw BridgeError(code: .internal, message: "Viewer capture is not a decodable image")
        }
        return ImageAttachment(png: data, pixelWidth: width, pixelHeight: height)
    }

    private static let notConnected = BridgeError(code: .notConnected, message: "Extension not connected")

    private func viewerRequest(tabId: Int, _ makeRequest: @escaping @Sendable (String) -> BridgeRequest) async throws -> RequestOutcome {
        guard let target = await server.viewerTarget(tabId: tabId) else { throw Self.notConnected }
        return try await perform(on: target, timeout: server.timings.viewerTimeout, makeRequest)
    }

    /// Every error that leaves the client is a `BridgeError`.
    private func mappingErrors<T: Sendable>(_ body: () async throws -> T) async throws -> T {
        do {
            return try await body()
        } catch let error as BridgeError {
            throw error
        } catch {
            throw BridgeError(code: .internal, message: "Bad response from the extension: \(error.localizedDescription)")
        }
    }
}
