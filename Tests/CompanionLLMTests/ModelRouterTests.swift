@testable import CompanionLLM
import CompanionCore
import Testing

private let router = ModelRouter(defaults: .standard, cycle: ModelCatalog.defaultCycle)

struct ModelRouterTests {
    @Test func modelForKindUsesDefaults() {
        for k in [ContextKind.youtube, .webPage, .genericWindow] { #expect(router.model(for: k) == ModelCatalog.haiku45) }
        for k in [ContextKind.mathPage, .pdfPages, .region] { #expect(router.model(for: k) == ModelCatalog.sonnet55) }
    }
    @Test func nextWraps() {
        #expect(router.next(after: ModelCatalog.haiku45) == ModelCatalog.sonnet55)
        #expect(router.next(after: ModelCatalog.sonnet55) == ModelCatalog.haiku45)
    }
    @Test func nextFromUnknownReturnsFirst() {
        #expect(router.next(after: ModelRef(providerID: "openai-compatible", modelID: "gpt-test", displayName: "GPT")) == ModelCatalog.haiku45)
    }
    @Test func nextMatchesByIDsNotDisplayName() {
        var renamed = ModelCatalog.haiku45
        renamed.displayName = "Fast"
        #expect(router.next(after: renamed) == ModelCatalog.sonnet55)
    }
    @Test func nextOnEmptyCycleReturnsCurrent() {
        #expect(ModelRouter(defaults: .standard, cycle: []).next(after: ModelCatalog.sonnet55) == ModelCatalog.sonnet55)
    }
}
