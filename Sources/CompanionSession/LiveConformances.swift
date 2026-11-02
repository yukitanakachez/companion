import CompanionLLM
import CompanionUI

extension BubbleController: BubblePresenting {}
extension ProviderRegistry: ProviderResolving {}

extension BubbleErrorBanner {
    init(_ copy: ErrorCopy) {
        self.init(message: copy.message, offerModelSwitch: copy.offerModelSwitch, offerSettings: copy.offerSettings)
    }
}
