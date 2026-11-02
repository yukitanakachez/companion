import CompanionCore
import Foundation

public struct ErrorCopy: Sendable, Equatable {
    public var message: String
    public var offerModelSwitch: Bool
    public var offerSettings: Bool

    public init(message: String, offerModelSwitch: Bool, offerSettings: Bool) {
        self.message = message
        self.offerModelSwitch = offerModelSwitch
        self.offerSettings = offerSettings
    }
}

public enum ErrorMessages {
    public static func forFailure(_ error: any Error, model: ModelRef, openAICompatibleBaseURL: String) -> ErrorCopy {
        let name = model.displayName
        if error is URLError {
            return networkCopy(model: model, base: openAICompatibleBaseURL)
        }
        guard let error = error as? LLMError else {
            return switchable("\(name) ran into an unexpected error. Try again.")
        }
        switch error {
        case .missingAPIKey(providerID: "anthropic"):
            return settings("Add your Anthropic API key in Settings to start asking.")
        case .missingAPIKey:
            return settings("Add an API key for your OpenAI-compatible provider in Settings.")
        case .http(status: 401, _), .http(status: 403, _):
            return settings("\(name) rejected the API key. Check it in Settings.")
        case .http(status: 429, _):
            return switchable("\(name) is rate-limiting requests. Try again in a moment or switch models.")
        case .http(status: 500, _), .http(status: 503, _), .http(status: 529, _):
            return switchable("\(name) is overloaded right now. Switch models or try again.")
        case let .http(status, message):
            return switchable("\(name) returned an error (\(status)): \(message)")
        case .network:
            return networkCopy(model: model, base: openAICompatibleBaseURL)
        case .decoding:
            return switchable("Got an unreadable reply from \(name). Try again.")
        }
    }

    public static let screenRecordingMissing = settings("Companion can't see your screen yet. Grant Screen Recording in System Settings.")
    public static let accessibilityMissing = settings("Companion can't read text in other apps yet. Grant Accessibility in System Settings.")

    private static func settings(_ message: String) -> ErrorCopy {
        ErrorCopy(message: message, offerModelSwitch: false, offerSettings: true)
    }

    private static func switchable(_ message: String) -> ErrorCopy {
        ErrorCopy(message: message, offerModelSwitch: true, offerSettings: false)
    }

    private static func networkCopy(model: ModelRef, base: String) -> ErrorCopy {
        let host = model.providerID == "anthropic" ? "api.anthropic.com" : (URL(string: base)?.host ?? base)
        return ErrorCopy(message: "Couldn't reach \(host). Check your internet connection.", offerModelSwitch: false, offerSettings: false)
    }
}
