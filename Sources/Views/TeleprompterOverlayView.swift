import SwiftUI

// MARK: - Teleprompter Overlay View

/// The main teleprompter view rendered inside the floating NSPanel.
///
/// **Voice-Guided Slides** — unified system:
/// - Slides are the unit of navigation (⌘F1/F2 for manual override)
/// - When voice tracking is enabled, words highlight as the speaker says them
/// - When all words in a slide are spoken, it auto-advances to the next slide
/// - When voice tracking is off, it's pure manual slide navigation
struct TeleprompterOverlayView: View {
    @ObservedObject var appState: AppState
    @ObservedObject var scrollController: AutoScrollController

    @State private var isHovering = false
    @State private var controlsVisible = true
    @State private var controlsHideWorkItem: DispatchWorkItem?

    private var settings: TeleprompterSettings { appState.teleprompterSettings }
    private var script: TeleprompterScript { appState.teleprompterScript }

    private var safeAreaTopPadding: CGFloat {
        if settings.placementMode == .dynamicIsland {
            if let screen = NSScreen.main {
                let menuBarHeight = screen.frame.maxY - screen.visibleFrame.maxY
                // Give a tiny extra buffer (e.g., 4pt) below the notch
                return menuBarHeight > 0 ? menuBarHeight + 4 : 37
            }
            return 37
        }
        return 0
    }

    var body: some View {
        let isDynamicIsland = settings.placementMode == .dynamicIsland

        ZStack {
            backgroundLayer

            GeometryReader { geo in
                ZStack {
                    slideContent(in: geo)
                        .padding(.top, safeAreaTopPadding)
                }
            }

            VStack {
                Spacer()
                if !settings.isClickThrough && (controlsVisible || isHovering) {
                    miniControlBar
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.easeInOut(duration: 0.25), value: controlsVisible)
            .animation(.easeInOut(duration: 0.25), value: isHovering)

            if !settings.isClickThrough {
                VStack {
                    Spacer()
                    progressBar
                }
            }
        }
        // Dynamic Island: notch-wrapping shape
        .clipShape(
            isDynamicIsland
                ? AnyShape(DynamicIslandShape())
                : AnyShape(RoundedRectangle(cornerRadius: 0, style: .continuous))
        )
        .overlay {
            if isDynamicIsland {
                DynamicIslandShape()
                    .stroke(Color.white.opacity(0.08), lineWidth: 1)
            }
        }
        .onHover { hovering in
            isHovering = hovering
            if hovering { showControls() }
        }
    }

    // MARK: - Slide Content (with optional word highlighting)

    @ViewBuilder
    private func slideContent(in geo: GeometryProxy) -> some View {
        let padding: CGFloat = max(24, geo.size.width * 0.08)

        ZStack {
            if !scrollController.currentSlide.isEmpty {
                VStack(spacing: 0) {
                    Spacer(minLength: 16)

                    if scrollController.isVoiceTrackingEnabled {
                        // Voice-tracked: individual words with opacity + auto-scroll
                        voiceTrackedScrollView(padding: padding)
                    } else {
                        // Pure manual: slide text as a block with regular scrolling
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
                    }

                    Spacer(minLength: 16)
                }
                .id(scrollController.currentSlideIndex)
                .transition(.opacity)
                .animation(.easeInOut(duration: 0.3), value: scrollController.currentSlideIndex)
                .mask(
                    LinearGradient(
                        stops: [
                            .init(color: .clear, location: 0.0),
                            .init(color: .black, location: 0.1),
                            .init(color: .black, location: 0.9),
                            .init(color: .clear, location: 1.0)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
            } else {
                emptyState
            }

            // Slide counter + status
            if !settings.isClickThrough && scrollController.slideCount > 0 {
                VStack {
                    HStack {
                        if scrollController.isVoiceTrackingEnabled {
                            voiceStatusIndicator
                        }
                        Spacer()
                        slideCounter
                    }
                    Spacer()
                }
            }

            // Navigation hints (always shown in active state unless click-through)
            if !settings.isClickThrough && scrollController.state == .active {
                slideNavigationHints
            }
        }
    }

    // MARK: - Voice-Tracked ScrollView (with auto-scroll to current word)

    @ViewBuilder
    private func voiceTrackedScrollView(padding: CGFloat) -> some View {
        let tracker = scrollController.voiceTracker

        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                WordFlowLayout(
                    spacing: settings.fontSize * 0.3,
                    lineSpacing: settings.fontSize * (settings.lineHeight - 1.0)
                ) {
                    ForEach(Array(tracker.displayWords.enumerated()), id: \.offset) { index, word in
                        Text(word)
                            .font(.system(size: settings.fontSize, weight: .medium))
                            .foregroundStyle(.white.opacity(opacityForWord(at: index, tracker: tracker)))
                            .id(index)
                            .animation(.easeOut(duration: 0.15), value: tracker.confirmedUpTo)
                    }
                }
                .padding(.horizontal, padding)
                .padding(.bottom, 60) // Extra space so last words can scroll up
            }
            .onChange(of: tracker.confirmedUpTo) { _, newValue in
                // Voice advanced — clear manual scroll so viewport follows voice
                scrollController.clearManualScroll()

                // Auto-scroll to keep the current word visible
                let scrollTarget = min(newValue + 2, tracker.wordCount - 1)
                guard scrollTarget >= 0 else { return }
                withAnimation(.easeOut(duration: 0.25)) {
                    proxy.scrollTo(scrollTarget, anchor: .center)
                }
            }
            .onChange(of: scrollController.manualScrollTarget) { _, newTarget in
                // Manual scroll (⌘F1/F2) — jump viewport to requested position
                guard let target = newTarget, target >= 0, target < tracker.wordCount else { return }
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo(target, anchor: .center)
                }
            }
        }
    }

    /// Determines word opacity based on voice tracking state:
    /// - Spoken words: full white (1.0)
    /// - Current word (tentative): bright with subtle visual emphasis
    /// - Upcoming words: dimmed (0.35)
    private func opacityForWord(at index: Int, tracker: SlideVoiceTracker) -> Double {
        if index < tracker.confirmedUpTo {
            return 1.0      // Already spoken
        }
        if let tentative = tracker.tentativeWord, index == tentative {
            return 0.75     // Currently being spoken (speculative)
        }
        return 0.35         // Not yet spoken
    }

    // MARK: - Voice Status Indicator

    private var voiceStatusIndicator: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(voiceStatusColor)
                .frame(width: 8, height: 8)

            Text(scrollController.voiceFollowStatus)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.6))
        }
        .padding(10)
    }

    private var voiceStatusColor: Color {
        switch scrollController.voiceTracker.state {
        case .idle:       return .gray
        case .tracking:   return .green
        case .adlibbing:  return .orange
        case .paused:     return .yellow
        }
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


    // MARK: - Background

    @ViewBuilder
    private var backgroundLayer: some View {
        if settings.placementMode == .dynamicIsland {
            // Native Dynamic Island: pure black
            Color.black
        } else {
            switch settings.backgroundStyle {

            case .frosted:
                ZStack {
                    VisualEffectBlur(material: .hudWindow, blendingMode: .behindWindow)
                    Color.black.opacity(0.25)
                }
            case .solid:
                Color(nsColor: NSColor(white: 0.08, alpha: 1.0))
            }
        }
    }


    // MARK: - Mini Control Bar

    private var miniControlBar: some View {
        HStack(spacing: 12) {
            // Slide navigation (always available)
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

            // Voice tracking status (if enabled)
            if scrollController.isVoiceTrackingEnabled {
                Divider()
                    .frame(height: 16)

                Circle()
                    .fill(voiceStatusColor)
                    .frame(width: 6, height: 6)

                Text(scrollController.progressText)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.5))
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

// MARK: - Dynamic Island Shape

/// A custom shape that visually wraps the MacBook notch.
/// It has concave top corners and convex bottom corners.
struct DynamicIslandShape: Shape {
    var topInset: CGFloat = 16
    var bottomRadius: CGFloat = 18

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(topInset, bottomRadius) }
        set {
            topInset = newValue.first
            bottomRadius = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        let w = rect.width
        let h = rect.height
        let t = topInset
        let br = bottomRadius
        var p = Path()

        // Start at top-left corner
        p.move(to: CGPoint(x: 0, y: 0))

        // Top-left curve: from (0,0) curve down-right to (t, t)
        p.addQuadCurve(
            to: CGPoint(x: t, y: t),
            control: CGPoint(x: t, y: 0)
        )

        // Left edge down
        p.addLine(to: CGPoint(x: t, y: h - br))

        // Bottom-left convex corner
        p.addQuadCurve(
            to: CGPoint(x: t + br, y: h),
            control: CGPoint(x: t, y: h)
        )

        // Bottom edge
        p.addLine(to: CGPoint(x: w - t - br, y: h))

        // Bottom-right convex corner
        p.addQuadCurve(
            to: CGPoint(x: w - t, y: h - br),
            control: CGPoint(x: w - t, y: h)
        )

        // Right edge up
        p.addLine(to: CGPoint(x: w - t, y: t))

        // Top-right curve: from (w-t, t) curve up-right to (w, 0)
        p.addQuadCurve(
            to: CGPoint(x: w, y: 0),
            control: CGPoint(x: w - t, y: 0)
        )

        // Top edge back to start
        p.closeSubpath()
        return p
    }
}
