import CompanionCore
@testable import CompanionSession
import Foundation
import Testing

private let haiku = ModelCatalog.haiku45
private let base = "https://api.openai.com/v1"

private func copy(_ error: any Error, _ model: ModelRef = haiku, _ baseURL: String = base) -> ErrorCopy {
    ErrorMessages.forFailure(error, model: model, openAICompatibleBaseURL: baseURL)
}

@Test func missingKeyCopy() {
    #expect(copy(LLMError.missingAPIKey(providerID: "anthropic")) == ErrorCopy(message: "Add your Anthropic API key in Settings to start asking.", offerModelSwitch: false, offerSettings: true))
    #expect(copy(LLMError.missingAPIKey(providerID: "openai-compatible")) == ErrorCopy(message: "Add an API key for your OpenAI-compatible provider in Settings.", offerModelSwitch: false, offerSettings: true))
}

@Test func httpCopy() {
    for status in [401, 403] {
        #expect(copy(LLMError.http(status: status, message: "")) == ErrorCopy(message: "Haiku 4.5 rejected the API key. Check it in Settings.", offerModelSwitch: false, offerSettings: true))
    }
    #expect(copy(LLMError.http(status: 429, message: "")) == ErrorCopy(message: "Haiku 4.5 is rate-limiting requests. Try again in a moment or switch models.", offerModelSwitch: true, offerSettings: false))
    for status in [500, 503, 529] {
        #expect(copy(LLMError.http(status: status, message: "")) == ErrorCopy(message: "Haiku 4.5 is overloaded right now. Switch models or try again.", offerModelSwitch: true, offerSettings: false))
    }
    #expect(copy(LLMError.http(status: 418, message: "teapot")) == ErrorCopy(message: "Haiku 4.5 returned an error (418): teapot", offerModelSwitch: true, offerSettings: false))
}

@Test func networkCopy() {
    #expect(copy(LLMError.network("offline")) == ErrorCopy(message: "Couldn't reach api.anthropic.com. Check your internet connection.", offerModelSwitch: false, offerSettings: false))
    let llama = ModelRef(providerID: "openai-compatible", modelID: "llama", displayName: "Llama")
    #expect(copy(URLError(.notConnectedToInternet), llama, "http://localhost:1234/v1").message == "Couldn't reach localhost. Check your internet connection.")
}

@Test func decodingAndUnknownCopy() {
    #expect(copy(LLMError.decoding("x")) == ErrorCopy(message: "Got an unreadable reply from Haiku 4.5. Try again.", offerModelSwitch: true, offerSettings: false))
    #expect(copy(CocoaError(.featureUnsupported)) == ErrorCopy(message: "Haiku 4.5 ran into an unexpected error. Try again.", offerModelSwitch: true, offerSettings: false))
}

@Test func permissionCopy() {
    #expect(ErrorMessages.screenRecordingMissing == ErrorCopy(message: "Companion can't see your screen yet. Grant Screen Recording in System Settings.", offerModelSwitch: false, offerSettings: true))
    #expect(ErrorMessages.accessibilityMissing == ErrorCopy(message: "Companion can't read text in other apps yet. Grant Accessibility in System Settings.", offerModelSwitch: false, offerSettings: true))
}
