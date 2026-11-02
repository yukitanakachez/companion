import CoreGraphics

public struct RoutingDefaults: Codable, Sendable, Equatable {
    public var youtube, mathPage, webPage, pdfPages, genericWindow, region: ModelRef

    public init(youtube: ModelRef, mathPage: ModelRef, webPage: ModelRef,
                pdfPages: ModelRef, genericWindow: ModelRef, region: ModelRef) {
        self.youtube = youtube
        self.mathPage = mathPage
        self.webPage = webPage
        self.pdfPages = pdfPages
        self.genericWindow = genericWindow
        self.region = region
    }

    public func model(for kind: ContextKind) -> ModelRef {
        switch kind {
        case .youtube: youtube
        case .mathPage: mathPage
        case .webPage: webPage
        case .pdfPages: pdfPages
        case .genericWindow: genericWindow
        case .region: region
        }
    }

    public static let standard = RoutingDefaults(
        youtube: ModelCatalog.haiku45,
        mathPage: ModelCatalog.sonnet55,
        webPage: ModelCatalog.haiku45,
        pdfPages: ModelCatalog.sonnet55,
        genericWindow: ModelCatalog.haiku45,
        region: ModelCatalog.sonnet55
    )
}

public struct AppSettings: Codable, Sendable, Equatable {
    public var routing: RoutingDefaults
    public var modelCycle: [ModelRef]
    public var openAICompatibleBaseURL: String
    public var orbEnabled: Bool
    /// nil means bottom-right of the main screen.
    public var orbPosition: CGPoint?
    public var blocklist: BlocklistConfig

    public init(routing: RoutingDefaults, modelCycle: [ModelRef], openAICompatibleBaseURL: String,
                orbEnabled: Bool, orbPosition: CGPoint?, blocklist: BlocklistConfig) {
        self.routing = routing
        self.modelCycle = modelCycle
        self.openAICompatibleBaseURL = openAICompatibleBaseURL
        self.orbEnabled = orbEnabled
        self.orbPosition = orbPosition
        self.blocklist = blocklist
    }

    public static let `default` = AppSettings(
        routing: .standard,
        modelCycle: ModelCatalog.defaultCycle,
        openAICompatibleBaseURL: "https://api.openai.com/v1",
        orbEnabled: true,
        orbPosition: nil,
        blocklist: .starter
    )
}

@MainActor public protocol SettingsStoring: AnyObject {
    var settings: AppSettings { get }
    func update(_ mutate: (inout AppSettings) -> Void)
    /// Observers live for the lifetime of the app.
    func addObserver(_ onChange: @escaping @MainActor (AppSettings) -> Void)
}

public protocol SecretStoring: Sendable {
    func secret(for key: String) -> String?
    /// Passing nil deletes the secret.
    func setSecret(_ value: String?, for key: String) throws
}

public enum SecretKey {
    public static let anthropicAPIKey = "anthropic.apiKey"
    public static let openAICompatibleAPIKey = "openai-compatible.apiKey"
    public static let bridgeToken = "bridge.pairingToken"
}

public struct DocumentChoice: Sendable, Equatable {
    public var current: DriveFileRef
    public var alternatives: [DriveFileRef]

    public init(current: DriveFileRef, alternatives: [DriveFileRef]) {
        self.current = current
        self.alternatives = alternatives
    }
}

public struct BridgeStatus: Sendable, Equatable {
    public var port: UInt16?
    public var connectedBrowsers: [String]

    public init(port: UInt16?, connectedBrowsers: [String]) {
        self.port = port
        self.connectedBrowsers = connectedBrowsers
    }
}

public enum PermissionKind: Sendable, Equatable {
    case screenRecording, accessibility
}

public struct PermissionStatus: Sendable, Equatable {
    public var screenRecording: Bool
    public var accessibility: Bool

    public init(screenRecording: Bool, accessibility: Bool) {
        self.screenRecording = screenRecording
        self.accessibility = accessibility
    }
}
