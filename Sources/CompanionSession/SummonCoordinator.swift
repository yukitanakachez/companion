import AppKit
import CompanionCapture
import CompanionCore
import CompanionLLM
import CompanionUI
import Foundation

/// Drives the bubble from hotkey to streamed answer. Everything that must feel instant happens
/// synchronously here; keychain reads, prewarm, permission checks and gathering run after `show`.
@MainActor public final class SummonCoordinator: BubbleActions {
    private enum SettingsTarget {
        case app
        case permission(PermissionKind)
    }

    /// The question in flight. `nil` means idle. Cancelling clears it synchronously, so a stale
    /// task sees `isCurrent(id) == false` and touches nothing afterwards.
    struct ActiveRun {
        let id = UUID()
        let question: String
        var model: ModelRef?
        var userMessage: LLMMessage?
        var assistantID: UUID?
        var partial = ""
        var thinkingStepID: UUID?
    }

    private struct FailedQuestion {
        let question: String
        let model: ModelRef
    }

    let viewModel: BubbleViewModel
    private let presenter: any BubblePresenting
    private let providers: any ProviderResolving
    private let settings: any SettingsStoring
    private let permissions: any PermissionChecking
    private let trace: LatencyTrace
    private let cursor: @MainActor () -> NSPoint
    private let openSettings: @MainActor () -> Void

    private(set) var conversation: ConversationStore
    private(set) var context: CapturedContext?
    private var override: ModelRef?
    private var settingsTarget = SettingsTarget.app
    private var failed: FailedQuestion?
    private var prewarmedProviders: Set<String> = []
    var run: ActiveRun?

    private var startupTask: Task<Void, Never>?
    private var prewarmTasks: [Task<Void, Never>] = []
    private var workTask: Task<Void, Never>?

    var gatherer: (any ContextGathering)?
    var regionSelector: any RegionSelecting = LiveRegionSelector()
    var glow: any GlowFlashing = LiveCaptureGlow()
    private var gatherTask: Task<Void, Never>?
    private var regionTask: Task<Void, Never>?
    private var activeGather: UUID?
    private var regionSelectionInProgress = false
    private var glowDone = false
    private var removedItemIDs: Set<UUID> = []
    private var removedPieces: Set<PieceCase> = []

    init(viewModel: BubbleViewModel, presenter: any BubblePresenting, providers: any ProviderResolving,
         settings: any SettingsStoring, permissions: any PermissionChecking, trace: LatencyTrace,
         now: @escaping @Sendable () -> Date = Date.init,
         cursor: @escaping @MainActor () -> NSPoint = { NSEvent.mouseLocation },
         openSettings: @escaping @MainActor () -> Void) {
        self.viewModel = viewModel
        self.presenter = presenter
        self.providers = providers
        self.settings = settings
        self.permissions = permissions
        self.trace = trace
        self.cursor = cursor
        self.openSettings = openSettings
        conversation = ConversationStore(now: now)
    }

    public convenience init(viewModel: BubbleViewModel, bubble: BubbleController, providers: ProviderRegistry,
                            settings: any SettingsStoring, permissions: PermissionsService, trace: LatencyTrace,
                            openSettings: @escaping @MainActor () -> Void) {
        self.init(viewModel: viewModel, presenter: bubble, providers: providers, settings: settings,
                  permissions: permissions, trace: trace, openSettings: openSettings)
    }

    // MARK: Summon

    public func attach(gatherer: ContextGatherer) {
        self.gatherer = gatherer
    }

    public func summon() {
        guard !regionSelectionInProgress else { return }
        if presenter.isVisible {
            presenter.focusInput()
            return
        }
        beginPresentation(avoiding: nil)
        startStartupChecks()
        startGather(.frontWindow, glowAlreadyShown: false)
    }

    public func summonRegion() {
        guard !regionSelectionInProgress else { return }
        regionSelectionInProgress = true
        regionTask = Task {
            let selection = await regionSelector.select()
            regionSelectionInProgress = false
            guard let selection else { return }
            if presenter.isVisible {
                presenter.focusInput()
            } else {
                beginPresentation(avoiding: selection.rect)   // the trace starts now: the drag is not hotkey latency
                startStartupChecks()
            }
            glow.flash(selection.rect)
            startGather(.region(selection), glowAlreadyShown: true)
        }
    }

    private func startGather(_ request: GatherRequest, glowAlreadyShown: Bool) {
        cancelGather()
        removedItemIDs = []
        removedPieces = []
        guard let gatherer else { return }
        glowDone = glowAlreadyShown
        let id = UUID()
        activeGather = id
        gatherTask = Task {
            let stream = await gatherer.gather(request)
            for await emission in stream {
                guard activeGather == id else { return }
                receiveGathered(emission)
            }
            if activeGather == id { activeGather = nil }
        }
    }

    private func cancelGather() {
        gatherTask?.cancel()
        activeGather = nil
    }

    private func receiveGathered(_ emission: CapturedContext) {
        var incoming = emission
        incoming.items.removeAll { item in
            removedItemIDs.contains(item.id) || PieceCase(item.piece).map(removedPieces.contains) == true
        }
        // Pages the finder attached outlive a gather that finishes after them.
        if let pages = context?.items.first(where: { PieceCase($0.piece) == .pdfPages }) {
            incoming.items.append(pages)
            incoming.kind = .pdfPages
        }
        applyContext(incoming)
        trace.mark(.contextFirst)
        if incoming.isComplete { trace.mark(.contextComplete) }
        if !glowDone, let frame = incoming.front?.windowFrame, !isBlocked(incoming.privacy) {
            glowDone = true
            glow.flash(frame)
        }
        guard run == nil else { return }
        let model = chosenModel()
        viewModel.setModelName(model.displayName)
        if prewarmedProviders.insert(model.providerID).inserted {
            Task {
                if case .success(let provider) = await resolveOffMain(model) { prewarm(provider) }
            }
        }
    }

    private func isBlocked(_ privacy: PrivacyDecision) -> Bool {
        if case .blocked = privacy { return true }
        return false
    }

    /// Up to 500 ms, then the question goes ahead with whatever has landed (spec §7).
    private func waitForGather(id: UUID) async {
        let deadline = ContinuousClock.now + .milliseconds(500)
        while activeGather != nil, isCurrent(id), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    /// Cancels in-flight work and keeps partial answers (quit).
    public func cancelAll() {
        cancelRun(keepPartial: true)
        cancelGather()
        startupTask?.cancel()
    }

    /// Summon steps 2–3: cheap in-memory resets, then show.
    private func beginPresentation(avoiding: CGRect?) {
        trace.begin()
        let resumed = conversation.beginSummon()
        viewModel.resetThread(resumed ? conversation.turns.flatMap { turn in
            [ThreadMessage(role: .user, markdown: turn.question), ThreadMessage(role: .assistant, markdown: turn.answer)]
        } : [])
        clearTransientUI()
        override = nil
        prewarmedProviders = []
        applyContext(nil)
        viewModel.setModelName(routed(.genericWindow).displayName)

        presenter.show(cursor: cursor(), avoiding: avoiding)
        trace.mark(.panelVisible)
        Task { @MainActor [trace] in trace.mark(.inputReady) }   // next turn ≈ "panel accepts keys"
    }

    private func clearTransientUI() {
        viewModel.setSteps([])
        viewModel.setPageThumbnails([])
        viewModel.setDocumentChoice(nil)
        viewModel.showError(nil)
        failed = nil
        settingsTarget = .app
    }

    /// Summon step 4. Runs after `show`, so a slow keychain can't delay the bubble.
    private func startStartupChecks() {
        startupTask?.cancel()
        let model = routed(.genericWindow)
        prewarmedProviders.insert(model.providerID)
        startupTask = Task {
            let resolved = await resolveOffMain(model)
            guard !Task.isCancelled else { return }
            switch resolved {
            case .failure(let error):
                present(failure: error, model: model)
            case .success(let provider):
                prewarm(provider)
                checkPermissions()
            }
        }
    }

    private func resolveOffMain(_ model: ModelRef) async -> Result<any LLMProvider, any Error> {
        let providers = providers
        return await Task.detached { Result { try providers.provider(for: model) } }.value
    }

    /// Never awaited by the permission check: a slow network must not hold back the banner.
    private func prewarm(_ provider: any LLMProvider) {
        prewarmTasks.append(Task.detached { await provider.prewarm() })
    }

    private func checkPermissions() {
        guard viewModel.error == nil else { return }
        if !permissions.screenRecordingGranted {
            show(ErrorMessages.screenRecordingMissing, target: .permission(.screenRecording))
        } else if !permissions.accessibilityGranted {
            show(ErrorMessages.accessibilityMissing, target: .permission(.accessibility))
        }
    }

    // MARK: Submit

    public func bubbleDidSubmit(_ text: String) {
        let question = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else { return }
        guard run == nil else { return restoreInput(question) }
        trace.mark(.submit)
        conversation.touch()
        let model = chosenModel()
        do {
            _ = try providers.provider(for: model)
        } catch {
            present(failure: error, model: model)
            return restoreInput(question)
        }
        viewModel.showError(nil)
        failed = nil
        viewModel.appendUserMessage(question)
        startRun(question: question)
    }

    /// The view model clears its input right after `bubbleDidSubmit` returns; a refused question goes back.
    private func restoreInput(_ question: String) {
        Task { @MainActor [viewModel] in viewModel.inputText = question }
    }

    private func startRun(question: String) {
        viewModel.setBusy(true)
        var active = ActiveRun(question: question)
        let thinking = StepItem(text: "Thinking…", state: .active)
        active.thinkingStepID = thinking.id
        viewModel.setSteps([thinking])
        run = active
        let id = active.id
        workTask = Task { await perform(id: id) }
    }

    private func perform(id: UUID) async {
        await waitForGather(id: id)
        guard isCurrent(id) else { return }
        await streamAnswer(id: id, model: chosenModel())
    }

    func isCurrent(_ id: UUID) -> Bool { run?.id == id }

    /// Submit steps 5–9. Every exit checks `isCurrent` first: cancellation has already cleaned up.
    func streamAnswer(id: UUID, model: ModelRef) async {
        guard let question = run?.question else { return }
        run?.model = model
        viewModel.setModelName(model.displayName)
        let prompt = PromptBuilder().build(question: question, context: context, history: conversation.messages,
                                           hintMode: viewModel.hintMode)
        guard let userMessage = prompt.messages.last, userMessage.role == .user else {
            return fail(LLMError.decoding("empty prompt"), model: model)
        }
        run?.userMessage = userMessage
        do {
            let provider = try providers.provider(for: model)
            let request = LLMRequest(model: model, system: prompt.system, messages: prompt.messages)
            for try await event in provider.stream(request) {
                guard isCurrent(id) else { return }
                if case .textDelta(let delta) = event, !delta.isEmpty { receive(delta) }
            }
            guard isCurrent(id) else { return }
            finishNormally(model: model)
        } catch {
            guard isCurrent(id) else { return }
            fail(error, model: model)
        }
    }

    private func receive(_ delta: String) {
        if run?.assistantID == nil {
            trace.mark(.firstToken)
            viewModel.setSteps(viewModel.steps.compactMap { step in
                if step.id == run?.thinkingStepID { return nil }
                var step = step
                if step.state == .active { step.state = .done }
                return step
            })
            run?.assistantID = viewModel.beginAssistantMessage()
        }
        guard let id = run?.assistantID else { return }
        viewModel.appendDelta(delta, to: id)
        run?.partial += delta
    }

    private func finishNormally(model: ModelRef) {
        guard let current = run else { return }
        guard let assistantID = current.assistantID, let userMessage = current.userMessage else {
            // A stream that ends with no text must not leave a blank bubble or an empty turn.
            return fail(LLMError.decoding("empty answer"), model: model)
        }
        viewModel.finishAssistantMessage(assistantID)
        conversation.appendTurn(question: current.question, userMessage: userMessage, answer: current.partial)
        trace.mark(.finished)
        run = nil
        viewModel.setBusy(false)
        if override == model { override = nil }   // a Tab pressed mid-answer applies to the next question
        viewModel.setModelName(chosenModel().displayName)
    }

    private func fail(_ error: any Error, model: ModelRef) {
        guard let current = run else { return }
        if let assistantID = current.assistantID { viewModel.finishAssistantMessage(assistantID) }
        viewModel.setSteps(viewModel.steps.compactMap { step in
            if step.id == current.thinkingStepID { return nil }
            var step = step
            if step.state == .active { step.state = .failed }
            return step
        })
        present(failure: error, model: model)
        failed = FailedQuestion(question: current.question, model: model)
        run = nil
        viewModel.setBusy(false)
    }

    private func cancelRun(keepPartial: Bool) {
        workTask?.cancel()
        workTask = nil
        guard let current = run else { return }
        run = nil
        if let assistantID = current.assistantID { viewModel.finishAssistantMessage(assistantID) }
        if keepPartial, !current.partial.isEmpty, let userMessage = current.userMessage {
            conversation.appendTurn(question: current.question, userMessage: userMessage, answer: current.partial)
        }
        viewModel.setSteps([])
        viewModel.setBusy(false)
    }

    // MARK: Other actions

    public func bubbleDidClose() {
        cancelRun(keepPartial: true)
        cancelGather()
        startupTask?.cancel()
        presenter.hide()
        conversation.touch()
    }

    public func bubbleDidRemoveContextItem(_ id: UUID) {
        removedItemIDs.insert(id)
        if let piece = context?.items.first(where: { $0.id == id })?.piece, let kind = PieceCase(piece) {
            removedPieces.insert(kind)
        }
        applyContext(context?.removingItem(id))
    }

    public func bubbleDidRequestModelCycle() {
        let next = router.next(after: chosenModel())
        override = next
        viewModel.setModelName(next.displayName)
    }

    public func bubbleDidToggleHint() {
        viewModel.setHintMode(!viewModel.hintMode)
    }

    public func bubbleDidRequestNewChat() {
        cancelRun(keepPartial: false)
        cancelGather()
        conversation.reset()
        viewModel.resetThread([])
        clearTransientUI()
        viewModel.setBusy(false)
    }

    public func bubbleDidRequestSettings() {
        switch settingsTarget {
        case .app: openSettings()
        case .permission(let kind): permissions.openSettings(for: kind)
        }
    }

    public func bubbleDidRequestModelSwitchAfterError() {
        guard let failed, run == nil else { return }
        override = router.next(after: failed.model)
        viewModel.showError(nil)
        self.failed = nil
        if let override { viewModel.setModelName(override.displayName) }
        startRun(question: failed.question)
    }

    public func bubbleDidSelectDocument(_ file: DriveFileRef) {}

    // MARK: Helpers

    func applyContext(_ context: CapturedContext?) {
        self.context = context
        viewModel.setContext(context)
    }

    /// Built from the current settings at each use: that is how settings changes take effect.
    private var router: ModelRouter {
        let current = settings.settings
        return ModelRouter(defaults: current.routing, cycle: current.modelCycle)
    }

    private func routed(_ kind: ContextKind) -> ModelRef { router.model(for: kind) }

    func chosenModel() -> ModelRef { override ?? routed(context?.kind ?? .genericWindow) }

    private func present(failure error: any Error, model: ModelRef) {
        show(ErrorMessages.forFailure(error, model: model,
                                      openAICompatibleBaseURL: settings.settings.openAICompatibleBaseURL),
             target: .app)
    }

    private func show(_ copy: ErrorCopy, target: SettingsTarget) {
        settingsTarget = target
        viewModel.showError(BubbleErrorBanner(copy))
    }

    /// Test hook: awaits every in-flight task.
    func settle() async {
        for _ in 0..<2 {
            await regionTask?.value
            await gatherTask?.value
            await startupTask?.value
            await workTask?.value
            for task in prewarmTasks { await task.value }
            prewarmTasks = []
        }
    }
}

/// The removable piece kinds, so a removed chip stays removed across later emissions of a gather.
private enum PieceCase: Hashable {
    case windowImage, regionImage, youtubeVideo, transcriptWindow, webPage, math, pdfPages, selectedText, focusedText

    init?(_ piece: ContextPiece) {
        switch piece {
        case .windowImage: self = .windowImage
        case .regionImage: self = .regionImage
        case .youtubeVideo: self = .youtubeVideo
        case .transcriptWindow: self = .transcriptWindow
        case .webPage: self = .webPage
        case .math: self = .math
        case .pdfPages: self = .pdfPages
        case .selectedText: self = .selectedText
        case .focusedText: self = .focusedText
        case .notice: return nil
        }
    }
}
