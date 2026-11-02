import CompanionCore
import CompanionPageFinder

protocol PageFinding: Sendable {
    func find(_ reference: PageReference, question: String, tab: TabContext?, lastUsed: DriveFileRef?,
              preferred: DriveFileRef?, progress: @escaping @Sendable (PageFinderStep) -> Void) async -> PageFinderOutcome
}

extension PageFinder: PageFinding {}
