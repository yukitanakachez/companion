import CompanionCore
import CompanionTestSupport
import Foundation

enum FixtureTabs {
    struct NotATabContext: Error {}

    static func tab(_ fixture: String) throws -> TabContext {
        let message = try JSONDecoder().decode(ExtensionToApp.self, from: Fixtures.bridgeFixture(fixture))
        guard case .tabContext(let context) = message else { throw NotATabContext() }
        return context
    }

    static func classroom() throws -> TabContext { try tab("ext-tabContext-classroom.json") }
    static func drive() throws -> TabContext { try tab("ext-tabContext-drive.json") }
    static func youtube() throws -> TabContext { try tab("ext-tabContext-youtube.json") }

    static let textbook = DriveFileRef(fileId: "1AbCdEfGhIjKlMnOpQrStUvWxYz012345", title: "Algebra 2 Textbook.pdf", mimeType: "application/pdf")
    static let worksheet = DriveFileRef(fileId: "1ZyXwVuTsRqPoNmLkJiHgFeDcBa987654", title: "Worksheet 5.2.pdf", mimeType: "application/pdf")
}
