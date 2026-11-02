import CompanionCore
import Foundation

struct ChipModel: Identifiable, Equatable {
    let id: UUID
    let label: String
    let isRemovable: Bool
    /// PNG only for `.windowImage` / `.regionImage`.
    let thumbnailPNG: Data?

    static func chips(from context: CapturedContext?) -> [ChipModel] {
        (context?.items ?? []).map { item in
            let png: Data?
            switch item.piece {
            case .windowImage(let image), .regionImage(let image): png = image.png
            default: png = nil
            }
            return ChipModel(id: item.id, label: item.chipLabel, isRemovable: item.isRemovable, thumbnailPNG: png)
        }
    }
}
