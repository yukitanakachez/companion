import CoreGraphics
import PDFKit

/// Printed-number lookup from the PDF's `/PageLabels`, only when they carry real information.
struct PageLabelTable: Sendable {
    private let firstIndexByLabel: [String: Int]

    /// nil unless the catalog has /PageLabels AND at least one page's label differs from "\(index + 1)"
    /// (identity labels carry no information: scanners write them over an offset printed numbering).
    static func make(for document: PDFDocument) -> PageLabelTable? {
        var labelsObject: CGPDFObjectRef?
        guard let catalog = document.documentRef?.catalog,
              CGPDFDictionaryGetObject(catalog, "PageLabels", &labelsObject) else { return nil }

        var firstIndex: [String: Int] = [:]
        var isIdentity = true
        for index in 0..<document.pageCount {
            guard let label = document.page(at: index)?.label else {
                isIdentity = false
                continue
            }
            if label != "\(index + 1)" { isIdentity = false }
            if firstIndex[label] == nil { firstIndex[label] = index }
        }
        return isIdentity ? nil : PageLabelTable(firstIndexByLabel: firstIndex)
    }

    /// The first page whose label is exactly "\(page)".
    func index(ofPrinted page: Int) -> Int? {
        firstIndexByLabel["\(page)"]
    }
}
