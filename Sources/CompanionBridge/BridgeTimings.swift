import CompanionCore

struct BridgeTimings: Sendable, Equatable {
    var helloTimeout: Duration
    var pingInterval: Duration
    var drivePdfTimeout: Duration
    var viewerTimeout: Duration

    static let standard = BridgeTimings(helloTimeout: BridgeConstants.helloTimeout,
                                        pingInterval: BridgeConstants.pingInterval,
                                        drivePdfTimeout: BridgeConstants.drivePdfTimeout,
                                        viewerTimeout: BridgeConstants.viewerRequestTimeout)
}
