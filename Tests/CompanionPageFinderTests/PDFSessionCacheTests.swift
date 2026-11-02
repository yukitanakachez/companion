@testable import CompanionPageFinder
import Foundation
import Testing

private func threePages() -> Data { TestPDF.text(pageCount: 3, printed: { _ in nil }) }

@Test func storesFileAtFileIdPath() async throws {
    let dir = temporaryDirectory(); let cache = PDFSessionCache(directory: dir)
    let loaded = try await cache.store(threePages(), fileId: "abc")
    #expect(loaded.document.pageCount == 3)
    #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("abc.pdf").path))
}

@Test func memoizesPerFileId() async throws {
    let cache = PDFSessionCache(directory: temporaryDirectory())
    let stored = try await cache.store(threePages(), fileId: "abc")
    let first = await cache.cached(fileId: "abc")
    let second = await cache.cached(fileId: "abc")
    #expect(first === stored && second === stored)
}

@Test func reloadsFromDiskInANewCache() async throws {
    let dir = temporaryDirectory()
    _ = try await PDFSessionCache(directory: dir).store(threePages(), fileId: "abc")
    let reloaded = await PDFSessionCache(directory: dir).cached(fileId: "abc")
    #expect(reloaded != nil)
}

@Test func rejectsNonPDF() async throws {
    let dir = temporaryDirectory(); let cache = PDFSessionCache(directory: dir)
    await #expect(throws: PageFinderError.notAPDF) { try await cache.store(Data("<html>".utf8), fileId: "x") }
    #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("x.pdf").path))
}

@Test func clearAllDeletesDirectory() async throws {
    let dir = temporaryDirectory(); let cache = PDFSessionCache(directory: dir)
    _ = try await cache.store(threePages(), fileId: "abc")
    await cache.clearAll()
    #expect(!FileManager.default.fileExists(atPath: dir.path))
    let cached = await cache.cached(fileId: "abc")
    #expect(cached == nil)
}

@Test func fileIdCannotEscapeDirectory() async {
    let dir = temporaryDirectory(); let cache = PDFSessionCache(directory: dir)
    let url = await cache.fileURL(for: "../x")
    #expect(url.deletingLastPathComponent().standardizedFileURL.path == dir.standardizedFileURL.path)
    #expect(url.lastPathComponent == "___x.pdf")
}
