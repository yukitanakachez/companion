@testable import CompanionPageFinder
import CompanionCore
import Testing

private let googleDoc = DriveFileRef(fileId: "d1", title: "Notes", mimeType: "application/vnd.google-apps.document")

private func classroom(attachments: [DriveFileRef]) throws -> TabContext {
    var tab = try FixtureTabs.classroom()
    tab.classroom?.attachments = attachments
    return tab
}

@Test func classroomPicksTitleMatch() throws {
    let tab = try FixtureTabs.classroom()
    #expect(DocumentResolver.resolve(tab: tab, question: "explain pages 231-232 of the textbook", lastUsed: nil, preferred: nil)
            == DocumentChoice(current: FixtureTabs.textbook, alternatives: [FixtureTabs.worksheet]))
    #expect(DocumentResolver.resolve(tab: tab, question: "worksheet page 2", lastUsed: nil, preferred: nil)
            == DocumentChoice(current: FixtureTabs.worksheet, alternatives: [FixtureTabs.textbook]))
}

@Test func classroomWithoutMatchTakesFirstPDF() throws {
    #expect(DocumentResolver.resolve(tab: try FixtureTabs.classroom(), question: "explain page 5", lastUsed: nil, preferred: nil)
            == DocumentChoice(current: FixtureTabs.textbook, alternatives: [FixtureTabs.worksheet]))
}

@Test func driveViewerUsesItsFile() throws {
    #expect(DocumentResolver.resolve(tab: try FixtureTabs.drive(), question: "page 5", lastUsed: FixtureTabs.worksheet, preferred: nil)
            == DocumentChoice(current: FixtureTabs.textbook, alternatives: []))
}

@Test func preferredWins() throws {
    #expect(DocumentResolver.resolve(tab: try FixtureTabs.classroom(), question: "explain page 5 of the textbook",
                                     lastUsed: nil, preferred: FixtureTabs.worksheet)
            == DocumentChoice(current: FixtureTabs.worksheet, alternatives: [FixtureTabs.textbook]))
}

@Test func onlyPDFAttachmentsCount() throws {
    let reading = DriveFileRef(fileId: "d2", title: "Reading.PDF", mimeType: nil)
    #expect(DocumentResolver.resolve(tab: try classroom(attachments: [googleDoc, reading]), question: "page 5", lastUsed: nil, preferred: nil)
            == DocumentChoice(current: reading, alternatives: []))
}

@Test func fallsBackToLastUsed() throws {
    let expected = DocumentChoice(current: FixtureTabs.worksheet, alternatives: [])
    for tab in [nil, try FixtureTabs.youtube(), try classroom(attachments: [googleDoc])] as [TabContext?] {
        #expect(DocumentResolver.resolve(tab: tab, question: "page 5", lastUsed: FixtureTabs.worksheet, preferred: nil) == expected)
    }
}

@Test func nothingAnywhere() {
    #expect(DocumentResolver.resolve(tab: nil, question: "page 5", lastUsed: nil, preferred: nil) == nil)
}
