import Foundation

/// Hand-written PDF, because PDFKit can't write page labels.
enum RawPDF {
    /// `nums` is the verbatim /Nums array, nil → no /PageLabels in the catalog.
    static func make(pageCount: Int, nums: String?, printed: (Int) -> String? = { _ in nil }) -> Data {
        var out = "%PDF-1.4\n"
        var offsets: [Int] = []
        func object(_ number: Int, _ body: String) {
            precondition(number == offsets.count + 1)
            offsets.append(out.utf8.count)
            out += "\(number) 0 obj\n\(body)\nendobj\n"
        }

        let labels = nums.map { " /PageLabels << /Nums \($0) >>" } ?? ""
        object(1, "<< /Type /Catalog /Pages 2 0 R\(labels) >>")
        let kids = (0..<pageCount).map { "\(4 + 2 * $0) 0 R" }.joined(separator: " ")
        object(2, "<< /Type /Pages /Kids [\(kids)] /Count \(pageCount) >>")
        object(3, "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>")
        for index in 0..<pageCount {
            object(4 + 2 * index, "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] "
                + "/Resources << /Font << /F1 3 0 R >> >> /Contents \(5 + 2 * index) 0 R >>")
            var content = "BT /F1 12 Tf 72 400 Td (Body text \(index)) Tj ET"
            if let label = printed(index) { content += "\nBT /F1 14 Tf 300 40 Td (\(label)) Tj ET" }
            object(5 + 2 * index, "<< /Length \(content.utf8.count) >>\nstream\n\(content)\nendstream")
        }

        let xref = out.utf8.count
        let size = offsets.count + 1
        out += "xref\n0 \(size)\n0000000000 65535 f \n"
        for offset in offsets { out += String(format: "%010d 00000 n \n", offset) }
        out += "trailer\n<< /Size \(size) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n"
        return Data(out.utf8)
    }
}
