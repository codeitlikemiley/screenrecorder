import SwiftUI

// MARK: - Teleprompter Overlay View

/// The main teleprompter view rendered inside the floating NSPanel.
/// - **Manual mode**: Slide-by-slide with transitions
/// - **Auto-Scroll mode**: Continuous scroll at fixed WPM
/// - **Voice-Follow mode**: Continuous scroll driven by voice alignment
///
/// For continuous scroll modes, all text is uniformly white.
/// The reading position is communicated by WHERE the text sits
/// on screen (in the focus zone), not by per-word coloring.
struct TeleprompterOverlayView: View {
    @ObservedObject var appState: AppState
    @ObservedObject var scrollController: AutoScrollController

    @State private var isHovering = false
    @State private var controlsVisible = true
    @State private var controlsHideWorkItem: DispatchWorkItem?

    private var settings: TeleprompterSettings { appState.teleprompterSettings }
    private var script: TeleprompterScript { appState.teleprompterScript }

    var body: some View {
        ZStack {
            backgroundLayer

            GeometryReader { geo in
                ZStack {
                    contentForMode(in: geo)

                    if scrollController.state == .finished {
                        endOfScriptIndicator
                    }
                }
            }

            VStack {
                Spacer()
                if controlsVisible || isHovering {
                    miniControlBar
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.easeInOut(duration: 0.25), value: controlsVisible)
            .animation(.easeInOut(duration: 0.25), value: isHovering)

            VStack {
                Spacer()
                progressBar
            }
        }
        .onHover { hovering in
            isHovering = hovering
            if hovering { showControls() }
        }
        .scaleEffect(x: settings.isMirrorMode ? -1 : 1, y: 1)
    }

    // MARK: - Mode-Aware Content

    @ViewBuilder
    private func contentForMode(in geo: GeometryProxy) -> some View {
        switch scrollController.mode {
        case .manual:
            slideContent(in: geo)
        case .autoScroll:
            autoScrollContent(in: geo)
        case .voiceFollow:
            voiceFollowContent(in: geo)
        }
    }

    // MARK: - Manual Slide Content

    @ViewBuilder
    private func slideContent(in geo: GeometryProxy) -> some View {
        let padding: CGFloat = max(24, geo.size.width * 0.08)

        ZStack {
            if !scrollController.currentSlide.isEmpty {
                VStack(spacing: 0) {
                    Spacer(minLength: 16)
                    ScrollView(.vertical, showsIndicators: false) {
                        Text(scrollController.currentSlide)
                            .font(.system(size: settings.fontSize, weight: .medium))
                            .lineSpacing(settings.fontSize * (settings.lineHeight - 1.0))
                            .foregroundStyle(.white)
                            .multilineTextAlignment(textMultilineAlignment)
                            .frame(maxWidth: .infinity, alignment: textFrameAlignment)
                            .padding(.horizontal, padding)
                            .minimumScaleFactor(0.5)
                    }
                    .id(scrollController.currentSlideIndex)
                    .transition(slideTransition)
                    .animation(.easeInOut(duration: 0.3), value: scrollController.currentSlideIndex)
                    Spacer(minLength: 16)
                }
            } else {
                emptyState
            }

            if scrollController.slideCount > 0 {
                VStack {
                    HStack {
                        Spacer()
                        slideCounter
                    }
                    Spacer()
                }
            }

            if scrollController.state == .active {
                slideNavigationHints
            }
        }
    }

    // MARK: - Continuous Scroll Content (shared by Auto-Scroll and Voice-Follow)

    @ViewBuilder
    private func continuousScrollContent(in geo: GeometryProxy, wordIndex: Int) -> some View {
        let padding: CGFloat = max(24, geo.size.width * 0.08)
        let words = scrollController.fullScriptWords

        ZStack {
            if !words.isEmpty {
                ScrollViewReader { proxy in
                    ScrollView(.vertical, showsIndicators: false) {
                        VStack(spacing: 0) {
                            Spacer()
                                .frame(height: 16)

                            WordFlowLayout(
                                spacing: settings.fontSize * 0.3,
                                lineSpacing: settings.fontSize * (settings.lineHeight - 1.0)
                            ) {
                                ForEach(Array(words.enumerated()), id: \.offset) { index, word in
                                    Text(word)
                                        .font(.system(size: settings.fontSize, weight: .medium))
                                        .foregroundStyle(.white)
                                        .id("word-\(index)")
                                }
                            }
                            .padding(.horizontal, padding)

                            Spacer()
                                .frame(height: geo.size.height * 0.5)
                        }
                    }
                    .scrollDisabled(true)
                    .onChange(of: wordIndex) { _, newIndex in
                        let clamped = max(0, min(newIndex, words.count - 1))
                        withAnimation(.easeInOut(duration: 0.35)) {
                            proxy.scrollTo("word-\(clamped)", anchor: UnitPoint(x: 0.5, y: 0.2))
                        }
                    }
                }

                focusGuideOverlay(height: geo.size.height)
            } else {
                emptyState
            }
        }
    }

    // MARK: - Auto-Scroll Content

    @ViewBuilder
    private func autoScrollContent(in geo: GeometryProxy) -> some View {
        let engine = scrollController.autoScrollEngine
        let wordIndex = autoScrollWordIndex(engine: engine)

        ZStack {
            continuousScrollContent(in: geo, wordIndex: wordIndex)

            VStack {
                HStack {
                    wpmIndicator
                    Spacer()
                }
                Spacer()
            }
        }
    }

    /// Convert auto-scroll progress to a word index
    private func autoScrollWordIndex(engine: AutoScrollEngine) -> Int {
        let totalWords = scrollController.fullScriptWords.count
        guard totalWords > 0 else { return 0 }
        return min(Int(engine.progress * Double(totalWords)), totalWords - 1)
    }

    // MARK: - Voice-Follow Content

    @ViewBuilder
    private func voiceFollowContent(in geo: GeometryProxy) -> some View {
        let engine = scrollController.voiceFollowEngine
        let wordIndex = Int(engine.displayPosition)

        ZStack {
            continuousScrollContent(in: geo, wordIndex: wordIndex)

            VStack {
                HStack {
                    voiceFollowStatusIndicator(engine: engine)
                    Spacer()
                    wordCounter
                }
                Spacer()
            }
        }
    }

    // MARK: - Focus Guide (top/bottom fade)

    @ViewBuilder
    private func focusGuideOverlay(height: CGFloat) -> some View {
        let fadeHeight = height * 0.25

        VStack(spacing: 0) {
            LinearGradient(
                stops: [
                    .init(color: .black.opacity(0.85), location: 0),
                    .init(color: .clear, location: 1)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: fadeHeight)
            .allowsHitTesting(false)

            Spacer()

            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0),
                    .init(color: .black.opacity(0.85), location: 1)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: fadeHeight)
            .allowsHitTesting(false)
        }
    }

    // MARK: - Status Indicators

    @ViewBuilder
    private func voiceFollowStatusIndicator(engine: VoiceFollowEngine) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(statusColor(for: engine.state))
                .frame(width: 8, height: 8)

            Text(scrollController.voiceFollowStatus)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.6))
        }
        .padding(10)
    }

    private func statusColor(for state: VoiceFollowEngine.FollowState) -> Color {
        switch state {
        case .idle:       return .gray
        case .tracking:   return .green
        case .adlibbing:  return .orange
        case .lost:       return .red.opacity(0.7)
        }
    }

    private var wpmIndicator: some View {
        HStack(spacing: 6) {
            Image(systemName: "scroll")
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.5))

            Text("\(Int(scrollController.autoScrollEngine.wordsPerMinute)) WPM")
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(0.6))
        }
        .padding(10)
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "text.justify.left")
                .font(.system(size: 36))
                .foregroundStyle(.white.opacity(0.2))
            Text("No script loaded")
                .font(.system(size: 14))
                .foregroundStyle(.white.opacity(0.3))
            Text("Press ⌘F5 to edit script")
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.2))
        }
    }

    // MARK: - Counters

    private var slideCounter: some View {
        Text(scrollController.slideProgressText)
            .font(.system(size: 11, weight: .medium, design: .monospaced))
            .foregroundStyle(.white.opacity(0.5))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Capsule().fill(.white.opacity(0.1)))
            .padding(12)
    }

    private var wordCounter: some View {
        Text(scrollController.progressText)
            .font(.system(size: 11, weight: .medium, design: .monospaced))
            .foregroundStyle(.white.opacity(0.5))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Capsule().fill(.white.opacity(0.1)))
            .padding(12)
    }

    private var slideNavigationHints: some View {
        HStack {
            if !scrollController.isFirstSlide {
                VStack {
                    Spacer()
                    Image(systemName: "chevron.left")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.white.opacity(0.15))
                        .padding(8)
                    Spacer()
                }
            }
            Spacer()
            if !scrollController.isLastSlide {
                VStack {
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.white.opacity(0.15))
                        .padding(8)
                    Spacer()
                }
            }
        }
    }

    private var slideTransition: AnyTransition {
        switch settings.slideTransition {
        case .fade:    return .opacity
        case .slide:
            return .asymmetric(
                insertion: .move(edge: .trailing).combined(with: .opacity),
                removal: .move(edge: .leading).combined(with: .opacity)
            )
        case .instant: return .identity
        }
    }

    // MARK: - Background

    @ViewBuilder
    private var backgroundLayer: some View {
        switch settings.backgroundStyle {
        case .transparent:
            Color.clear
        case .frosted:
            ZStack {
                VisualEffectBlur(material: .hudWindow, blendingMode: .behindWindow)
                Color.black.opacity(0.25)
            }
        case .solid:
            Color(nsColor: NSColor(white: 0.08, alpha: 1.0))
        }
    }

    // MARK: - End of Script

    private var endOfScriptIndicator: some View {
        VStack(spacing: 8) {
            Spacer()
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text("End of Script")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.white.opacity(0.7))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial)
            .clipShape(Capsule())
            .padding(.bottom, 48)
        }
    }

    // MARK: - Mini Control Bar

    private var miniControlBar: some View {
        HStack(spacing: 12) {
            switch scrollController.mode {
            case .manual:
                Button(action: { scrollController.previousSlide() }) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.white.opacity(scrollController.isFirstSlide ? 0.2 : 0.7))
                }
                .buttonStyle(.plain)
                .disabled(scrollController.isFirstSlide)

                Text(scrollController.slideProgressText)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.6))

                Button(action: { scrollController.nextSlide() }) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.white.opacity(scrollController.isLastSlide ? 0.2 : 0.7))
                }
                .buttonStyle(.plain)
                .disabled(scrollController.isLastSlide)

            case .autoScroll:
                Button(action: { scrollController.nudgeSpeed(faster: false) }) {
                    Image(systemName: "tortoise")
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.6))
                }
                .buttonStyle(.plain)

                Text("\(Int(scrollController.autoScrollEngine.wordsPerMinute)) WPM")
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.6))

                Button(action: { scrollController.nudgeSpeed(faster: true) }) {
                    Image(systemName: "hare")
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.6))
                }
                .buttonStyle(.plain)

            case .voiceFollow:
                Circle()
                    .fill(statusColor(for: scrollController.voiceFollowEngine.state))
                    .frame(width: 8, height: 8)

                Text(scrollController.progressText)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.6))
            }

            Text("\(Int(scrollController.progress * 100))%")
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(0.5))

            Button(action: { scrollController.reset() }) {
                Image(systemName: "arrow.counterclockwise")
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.6))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(.ultraThinMaterial)
                .environment(\.colorScheme, .dark)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(.white.opacity(0.1), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.3), radius: 10, y: 4)
        .padding(.bottom, 16)
    }

    // MARK: - Progress Bar

    private var progressBar: some View {
        GeometryReader { geo in
            Rectangle()
                .fill(LinearGradient(colors: [.blue, .cyan], startPoint: .leading, endPoint: .trailing))
                .frame(width: geo.size.width * scrollController.progress, height: 2)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: 2)
    }

    // MARK: - Helpers

    private var textMultilineAlignment: TextAlignment {
        settings.textAlignment == .center ? .center : .leading
    }
    private var textFrameAlignment: Alignment {
        settings.textAlignment == .center ? .center : .leading
    }

    private func showControls() {
        controlsVisible = true
        controlsHideWorkItem?.cancel()
        let work = DispatchWorkItem { [self] in
            if !isHovering { controlsVisible = false }
        }
        controlsHideWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0, execute: work)
    }
}

// MARK: - Visual Effect Blur (NSVisualEffectView wrapper)

struct VisualEffectBlur: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blendingMode: NSVisualEffectView.BlendingMode

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
    }
}

// MARK: - WordFlowLayout

/// A custom Layout that wraps children (words) into lines, similar to how text wraps.
struct WordFlowLayout: Layout {
    var spacing: CGFloat = 4
    var lineSpacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = computeLayout(proposal: proposal, subviews: subviews)
        return result.size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = computeLayout(proposal: proposal, subviews: subviews)

        for (index, subview) in subviews.enumerated() {
            guard index < result.positions.count else { break }
            let pos = result.positions[index]
            subview.place(
                at: CGPoint(x: bounds.minX + pos.x, y: bounds.minY + pos.y),
                proposal: .unspecified
            )
        }
    }

    private struct LayoutResult {
        var positions: [CGPoint]
        var size: CGSize
    }

    private func computeLayout(proposal: ProposedViewSize, subviews: Subviews) -> LayoutResult {
        let maxWidth = proposal.width ?? .infinity
        var positions: [CGPoint] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var lineHeight: CGFloat = 0
        var maxX: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)

            if x + size.width > maxWidth && x > 0 {
                x = 0
                y += lineHeight + lineSpacing
                lineHeight = 0
            }

            positions.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
            maxX = max(maxX, x)
        }

        return LayoutResult(
            positions: positions,
            size: CGSize(width: maxX, height: y + lineHeight)
        )
    }
}
