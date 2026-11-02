public struct ModelRef: Codable, Sendable, Hashable {
    public var providerID: String
    public var modelID: String
    public var displayName: String

    public static let anthropicProviderID = "anthropic"
    public static let openAICompatibleProviderID = "openai-compatible"

    public init(providerID: String, modelID: String, displayName: String) {
        self.providerID = providerID
        self.modelID = modelID
        self.displayName = displayName
    }
}

public enum ModelCatalog {
    public static let haiku45 = ModelRef(providerID: "anthropic", modelID: "claude-haiku-4-5-20251001", displayName: "Haiku 4.5")
    public static let sonnet55 = ModelRef(providerID: "anthropic", modelID: "claude-sonnet-5-5", displayName: "Sonnet 5.5")
    public static let defaultCycle: [ModelRef] = [haiku45, sonnet55]
}

public enum LLMRole: String, Codable, Sendable {
    case user, assistant
}

public enum LLMContent: Sendable, Equatable {
    case text(String)
    case image(ImageAttachment)
    case toolUse(id: String, name: String, inputJSON: String)              // reserved for v2
    case toolResult(toolUseID: String, content: String, isError: Bool)     // reserved for v2
}

public struct LLMMessage: Sendable, Equatable {
    public var role: LLMRole
    public var content: [LLMContent]

    public init(role: LLMRole, content: [LLMContent]) {
        self.role = role
        self.content = content
    }
}

public struct LLMToolSpec: Sendable, Equatable {
    public var name: String
    public var description: String
    public var inputSchemaJSON: String

    public init(name: String, description: String, inputSchemaJSON: String) {
        self.name = name
        self.description = description
        self.inputSchemaJSON = inputSchemaJSON
    }
}

public struct LLMRequest: Sendable, Equatable {
    public var model: ModelRef
    public var system: String
    public var messages: [LLMMessage]
    public var maxTokens: Int
    public var tools: [LLMToolSpec]

    public init(model: ModelRef, system: String, messages: [LLMMessage], maxTokens: Int = 4096, tools: [LLMToolSpec] = []) {
        self.model = model
        self.system = system
        self.messages = messages
        self.maxTokens = maxTokens
        self.tools = tools
    }
}

public enum LLMStreamEvent: Sendable, Equatable {
    case textDelta(String)
    case toolUse(id: String, name: String, inputJSON: String)
    case finished(stopReason: String?)
}

public enum LLMError: Error, Sendable, Equatable {
    case missingAPIKey(providerID: String)
    case http(status: Int, message: String)
    case network(String)
    case decoding(String)
}

public protocol LLMProvider: Sendable {
    var providerID: String { get }
    func stream(_ request: LLMRequest) -> AsyncThrowingStream<LLMStreamEvent, any Error>
    func prewarm() async
}
