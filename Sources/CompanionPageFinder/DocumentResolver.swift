import CompanionCore
import Foundation

/// Picks the Drive file a page question is about.
enum DocumentResolver {
    static let stopwords: Set<String> = ["page", "pages", "explain", "example", "problem", "problems",
                                         "what", "does", "this", "that", "with", "from", "about", "the"]

    static func isPDF(_ file: DriveFileRef) -> Bool {
        file.mimeType == "application/pdf" || file.title.lowercased().hasSuffix(".pdf")
    }

    static func resolve(tab: TabContext?, question: String, lastUsed: DriveFileRef?, preferred: DriveFileRef?) -> DocumentChoice? {
        let attachments = tab?.drive == nil ? (tab?.classroom?.attachments ?? []).filter(isPDF) : []
        if let preferred {
            let candidates = tab?.drive.map { [$0.file] } ?? attachments
            return DocumentChoice(current: preferred, alternatives: candidates.filter { $0.fileId != preferred.fileId })
        }
        if let drive = tab?.drive {
            return DocumentChoice(current: drive.file, alternatives: [])
        }
        if let chosen = bestMatch(in: attachments, question: question) ?? attachments.first {
            return DocumentChoice(current: chosen, alternatives: attachments.filter { $0.fileId != chosen.fileId })
        }
        return lastUsed.map { DocumentChoice(current: $0, alternatives: []) }
    }

    /// The attachment sharing the most words with the question; ties go to the earlier attachment.
    private static func bestMatch(in attachments: [DriveFileRef], question: String) -> DriveFileRef? {
        let questionWords = words(in: question)
        var best: (file: DriveFileRef, score: Int)?
        for file in attachments {
            let score = questionWords.intersection(words(in: titleWithoutExtension(file.title))).count
            if score > (best?.score ?? 0) { best = (file, score) }
        }
        return best?.file
    }

    private static func titleWithoutExtension(_ title: String) -> String {
        title.lowercased().hasSuffix(".pdf") ? String(title.dropLast(4)) : title
    }

    /// Maximal runs of letters, lowercased, length ≥ 4 and not stopwords, with one trailing "s" stripped.
    private static func words(in text: String) -> Set<String> {
        let runs = text.lowercased().split { !$0.isLetter }.map(String.init)
        return Set(runs.filter { $0.count >= 4 && !stopwords.contains($0) }
            .map { $0.hasSuffix("s") ? String($0.dropLast()) : $0 })
    }
}
