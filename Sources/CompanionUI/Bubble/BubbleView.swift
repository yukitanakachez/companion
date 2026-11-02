import AppKit
import CompanionCore
import ImageIO
import SwiftUI

struct BubbleView: View {
    /// `.bubble`: width 380, height ≤ 520. `.window`: fills its window.
    enum Style { case bubble, window }

    let viewModel: BubbleViewModel
    let answer: AnswerWebController
    let input: BubbleInputTextView
    let style: Style
    let onPopOut: () -> Void
    let onContentHeight: (CGFloat) -> Void

    @State private var answerHeight: CGFloat = 0
    @State private var inputHeight = BubbleInputField.lineHeight

    init(viewModel: BubbleViewModel, answer: AnswerWebController, input: BubbleInputTextView, style: Style,
         onPopOut: @escaping () -> Void, onContentHeight: @escaping (CGFloat) -> Void) {
        self.viewModel = viewModel
        self.answer = answer
        self.input = input
        self.style = style
        self.onPopOut = onPopOut
        self.onContentHeight = onContentHeight
    }

    private var chips: [ChipModel] { ChipModel.chips(from: viewModel.context) }

    var body: some View {
        Group {
            switch style {
            case .bubble:
                content(answerIdeal: answerHeight, live: true)
                    .frame(width: BubbleMetrics.width)
                    .frame(maxHeight: BubbleMetrics.maxHeight, alignment: .top)
                    .background(HeightReporter(natural: content(answerIdeal: answerHeight, live: false), report: onContentHeight))
            case .window:
                content(answerIdeal: nil, live: true).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
        }
        .background(BubbleBackground(cornerRadius: style == .bubble ? BubbleMetrics.cornerRadius : 0))
        .clipShape(RoundedRectangle(cornerRadius: style == .bubble ? BubbleMetrics.cornerRadius : 0))
        .environment(\.colorScheme, .dark)
        .onAppear { answer.onContentHeight = { answerHeight = $0 } }
    }

    /// `answerIdeal` nil means the answer takes all the room left (pop-out window).
    /// `live` false builds the measuring copy: the web view and text view are single AppKit
    /// instances that can't sit in two places, so it uses spacers of their heights instead,
    /// and it skips thumbnail decoding.
    private func content(answerIdeal: CGFloat?, live: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            header(live: live)
            if let choice = viewModel.documentChoice { documentChip(choice) }
            if !viewModel.steps.isEmpty { stepsList }
            if !viewModel.pageThumbnails.isEmpty { pageThumbnails(live: live) }
            if !viewModel.thread.isEmpty {
                if live {
                    AnswerWebView(controller: answer, thread: viewModel.thread)
                        .frame(minHeight: 0, idealHeight: answerIdeal, maxHeight: answerIdeal ?? .infinity)
                        .layoutPriority(-1)
                } else {
                    Color.clear.frame(height: answerIdeal ?? 0)
                }
            }
            if let banner = viewModel.error { errorBanner(banner) }
            if live { inputField } else { Color.clear.frame(height: inputHeight + 12) }
            footer
        }
        .padding(12)
        .foregroundStyle(Theme.text)
        .font(.system(size: 13))
    }

    @ViewBuilder private func header(live: Bool) -> some View {
        let showPopOut = style == .bubble && !viewModel.thread.isEmpty
        if !chips.isEmpty || showPopOut {
            HStack(alignment: .top, spacing: 6) {
                WrappingLayout(spacing: 4) {
                    ForEach(chips) { chip in
                        ChipView(chip: chip, live: live) { viewModel.removeContextItem(chip.id) }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if showPopOut {
                    Button("↗ pop out", action: onPopOut)
                        .buttonStyle(.plain)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.accent)
                        .fixedSize()
                }
            }
        }
    }

    private func documentChip(_ choice: DocumentChoice) -> some View {
        Menu {
            ForEach(choice.alternatives.filter { $0 != choice.current }, id: \.self) { file in
                Button(file.title) { viewModel.selectDocument(file) }
            }
        } label: {
            Text("using: \(choice.current.title)")
                .font(.system(size: 11))
                .foregroundStyle(Theme.chipText)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Theme.chipBackground, in: RoundedRectangle(cornerRadius: Theme.chipRadius))
    }

    private var stepsList: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(viewModel.steps) { step in
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    switch step.state {
                    case .done: Text("✓").foregroundStyle(Theme.stepDone)
                    case .active: Text("●").foregroundStyle(Theme.stepActive)
                    case .failed: Text("✕").foregroundStyle(Theme.stepFailed)
                    }
                    Text(step.text).foregroundStyle(Theme.stepText)
                }
                .font(.system(size: 12))
            }
        }
    }

    private func pageThumbnails(live: Bool) -> some View {
        WrappingLayout(spacing: 5) {
            ForEach(viewModel.pageThumbnails, id: \.pdfIndex) { page in
                ZStack(alignment: .bottomTrailing) {
                    ThumbnailImage(png: live ? page.image.png : nil, maxPixels: 128)
                        .frame(width: Theme.pageThumb.width, height: Theme.pageThumb.height)
                        .background(Color(hex: 0xF2F2F2))
                        .clipShape(RoundedRectangle(cornerRadius: 2))
                    Text(page.printedLabel)
                        .font(.system(size: 8))
                        .foregroundStyle(Color(hex: 0x666666))
                        .padding(.trailing, 3)
                        .padding(.bottom, 1)
                }
            }
        }
    }

    private func errorBanner(_ banner: BubbleErrorBanner) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(banner.message)
                .font(.system(size: 12))
                .foregroundStyle(Theme.stepFailed)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                if banner.offerModelSwitch {
                    Button("Switch model") { viewModel.switchModelAfterError() }
                }
                if banner.offerSettings {
                    Button("Open Settings") { viewModel.openSettings() }
                }
            }
            .controlSize(.small)
        }
    }

    private var inputField: some View {
        ZStack(alignment: .topLeading) {
            BubbleInputField(input: input, text: viewModel.inputText, height: $inputHeight)
                .frame(height: inputHeight)
            if viewModel.inputText.isEmpty {
                Text(viewModel.inputPlaceholder)
                    .foregroundStyle(Theme.placeholder)
                    .allowsHitTesting(false)
            }
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 6)
        .background(Theme.inputBackground, in: RoundedRectangle(cornerRadius: Theme.inputRadius))
    }

    private var footer: some View {
        HStack(spacing: 4) {
            if viewModel.isBusy {
                ProgressView().controlSize(.mini)
            }
            Text(viewModel.modelName)
            Keycap("⇥")
            Text("switch")
            if !viewModel.thread.isEmpty {
                Text("· new chat")
                Keycap("⌘N")
            }
            Spacer(minLength: 8)
            HStack(spacing: 3) {
                Text("Hints")
                Keycap("⌘H")
            }
            .foregroundStyle(viewModel.hintMode ? Theme.accent : Theme.footer)
            .padding(.horizontal, viewModel.hintMode ? 3 : 0)
            .fixedSize()
            .background(viewModel.hintMode ? Theme.accent.opacity(0.18) : .clear, in: RoundedRectangle(cornerRadius: 4))
            Text("Esc to close").fixedSize()
        }
        .font(.system(size: 10.5))
        .foregroundStyle(Theme.footer)
        .lineLimit(1)
    }
}

private struct Keycap: View {
    let label: String
    init(_ label: String) { self.label = label }
    var body: some View {
        Text(label)
            .padding(.horizontal, 3)
            .overlay(RoundedRectangle(cornerRadius: 3).stroke(Theme.hairline, lineWidth: 1))
    }
}

private struct ChipView: View {
    let chip: ChipModel
    let live: Bool
    let onRemove: () -> Void
    var body: some View {
        HStack(spacing: 4) {
            if let png = chip.thumbnailPNG {
                ThumbnailImage(png: live ? png : nil, maxPixels: 64)
                    .frame(width: Theme.windowThumb.width, height: Theme.windowThumb.height)
                    .clipShape(RoundedRectangle(cornerRadius: 3))
                    .overlay(RoundedRectangle(cornerRadius: 3).stroke(Theme.hairline, lineWidth: 1))
            }
            Text(chip.label).lineLimit(1)
            if chip.isRemovable {
                Button("✕", action: onRemove)
                    .buttonStyle(.plain)
                    .opacity(Theme.chipCloseOpacity)
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(Theme.chipText)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Theme.chipBackground, in: RoundedRectangle(cornerRadius: Theme.chipRadius))
    }
}

/// Decodes a small thumbnail off the main actor, once per `png` value; context screenshots are ~1500 px.
private struct ThumbnailImage: View {
    let png: Data?
    let maxPixels: Int
    @State private var image: CGImage?

    var body: some View {
        Group {
            if let image {
                Image(decorative: image, scale: 1).resizable().aspectRatio(contentMode: .fill)
            } else {
                Color.black
            }
        }
        .task(id: png) {
            guard let png else { return }
            let size = maxPixels
            image = await Task.detached(priority: .userInitiated) { Self.decode(png, maxPixels: size) }.value
        }
    }

    private nonisolated static func decode(_ png: Data, maxPixels: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(png as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}

/// Measures the view at its ideal height, without the bubble's 520 cap, and reports it.
private struct HeightReporter<Content: View>: View {
    let natural: Content
    let report: (CGFloat) -> Void
    var body: some View {
        natural
            .frame(width: BubbleMetrics.width)
            .fixedSize(horizontal: false, vertical: true)
            .hidden()
            .background(GeometryReader { proxy in
                Color.clear.preference(key: BubbleHeightKey.self, value: proxy.size.height)
            })
            .onPreferenceChange(BubbleHeightKey.self) { height in
                MainActor.assumeIsolated { report(height) }
            }
    }
}

private struct BubbleHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// Flow layout for chips.
struct WrappingLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        return CGSize(width: rows.map(\.width).max() ?? 0, height: rows.last.map { $0.y + $0.height } ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: bounds.minY + row.y),
                                      proposal: ProposedViewSize(width: min(size.width, bounds.width), height: size.height))
                x += size.width + spacing
            }
        }
    }

    private struct Row { var indices: [Int] = []; var width: CGFloat = 0; var height: CGFloat = 0; var y: CGFloat = 0 }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = []
        var row = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = row.indices.isEmpty ? size.width : row.width + spacing + size.width
            if needed > width, !row.indices.isEmpty {
                rows.append(row)
                row = Row(y: row.y + row.height + spacing)
            }
            row.width = row.indices.isEmpty ? size.width : row.width + spacing + size.width
            row.height = max(row.height, size.height)
            row.indices.append(index)
        }
        if !row.indices.isEmpty { rows.append(row) }
        return rows
    }
}

/// Dark blur under the #1C1C1E 92 % fill. The state is `.active` because the app is never active,
/// and an inactive effect view goes flat.
struct BubbleBackground: View {
    let cornerRadius: CGFloat
    var body: some View {
        ZStack {
            VisualEffectBackdrop()
            Theme.bubbleFill
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
    }
}

private struct VisualEffectBackdrop: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        view.appearance = NSAppearance(named: .darkAqua)
        return view
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
