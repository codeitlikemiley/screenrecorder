import Foundation
import AVFoundation
import Combine

/// Orchestrates the post-recording processing pipeline.
///
/// Pipeline stages:
/// 1. Load interaction metadata (raw events + capture geometry) from the JSON sidecar
/// 2. Aggregate raw events into semantic actions
/// 3. Extract one key frame per action, while transcribing narration in parallel
/// 4. Attach narration to the actions it overlaps
/// 5. Generate AI steps (if configured)
/// 6. Annotate each step's frame (off the main thread)
/// 7. Save the session and open the viewer
///
/// The raw metadata file is never modified; everything derived lives in the session and
/// workflow files, so re-processing always starts from the original recording.
@MainActor
class PostRecordingProcessor: ObservableObject {

    // MARK: - Published State

    @Published var isProcessing = false
    @Published var currentStage: Stage = .idle
    @Published var progress: Double = 0  // 0.0 to 1.0
    @Published var lastWorkflow: GeneratedWorkflow?

    enum Stage: String, CaseIterable {
        case idle = "Idle"
        case loadingMetadata = "Loading metadata…"
        case extractingFrames = "Extracting key frames…"
        case transcribingSpeech = "Transcribing speech…"
        case aggregatingEvents = "Aggregating events…"
        case generatingSteps = "Generating AI steps…"
        case annotatingFrames = "Annotating frames…"
        case buildingSession = "Building session…"
        case complete = "Complete"
        case failed = "Failed"
    }

    // MARK: - Components

    private let keyFrameExtractor = KeyFrameExtractor()
    private let speechTranscriber = SpeechTranscriber()
    private let eventAggregator = EventAggregator()
    private let frameAnnotator = FrameAnnotator()

    // MARK: - Process Recording

    /// Process a completed recording.
    @discardableResult
    func process(
        videoURL: URL,
        metadataURL: URL?,
        duration fallbackDuration: TimeInterval
    ) async -> RecordingSession? {
        isProcessing = true
        progress = 0
        defer { isProcessing = false }

        print("⚙️ Post-recording processing started")
        let directory = videoURL.deletingLastPathComponent()
        let baseName = videoURL.deletingPathExtension().lastPathComponent

        // Stage 1: Load raw events + capture geometry
        updateStage(.loadingMetadata, progress: 0.05)
        var events: [InteractionEvent] = []
        var geometry: CaptureGeometry?
        if let metadataURL {
            do {
                let metadata = try RecordingMetadata.load(from: metadataURL)
                events = metadata.events
                geometry = metadata.captureGeometry
                print("  📋 Loaded \(events.count) interaction events")
            } catch {
                print("  ⚠️ Failed to load interaction metadata: \(error.localizedDescription)")
            }
        }

        // The file's real duration beats the UI timer (which is whole seconds).
        let assetDuration = (try? await AVURLAsset(url: videoURL).load(.duration).seconds) ?? 0
        let duration = assetDuration > 0 ? assetDuration : fallbackDuration

        var session = RecordingSession.create(
            videoURL: videoURL,
            metadataURL: metadataURL,
            duration: duration,
            events: events
        )
        session.captureGeometry = geometry
        session.processingState = .processing

        // Stage 2: Aggregate events into actions (narration is attached after transcription)
        updateStage(.aggregatingEvents, progress: 0.1)
        var actions = events.isEmpty ? [] : eventAggregator.aggregate(events: events)

        // Stage 3: Frames and transcription run in parallel
        updateStage(.extractingFrames, progress: 0.15)
        let framesDir = directory.appendingPathComponent(session.framesDirectory ?? "\(baseName)_frames", isDirectory: true)
        clearFramesDirectory(framesDir, baseName: baseName)

        async let transcriptTask = transcribeIfPossible(videoURL)
        let strategy: KeyFrameExtractor.ExtractionStrategy = actions.isEmpty ? .atInterval(2.0) : .atActions(actions)
        do {
            let frames = try await keyFrameExtractor.extractFrames(from: videoURL, strategy: strategy, outputDirectory: framesDir)
            session.frames = frames.map {
                RecordingSession.FrameReference(
                    filename: $0.imageURL.lastPathComponent,
                    timestamp: $0.timestamp,
                    trigger: $0.trigger,
                    actionIndex: $0.actionIndex
                )
            }
            print("  📸 Extracted \(frames.count) key frames")
        } catch {
            print("  ⚠️ Key frame extraction failed: \(error.localizedDescription)")
        }

        updateStage(.transcribingSpeech, progress: 0.35)
        session.transcript = await transcriptTask

        // Stage 4: Attach narration to actions
        if let transcript = session.transcript, !actions.isEmpty {
            actions = eventAggregator.attachSpeech(transcript: transcript, to: actions)
        }
        session.aggregatedActions = actions.isEmpty ? nil : actions
        updateStage(.aggregatingEvents, progress: 0.45)

        // Stages 5–6: AI steps + annotated frames
        lastWorkflow = nil
        let aiManager = AIProviderManager.shared
        if aiManager.isAIEnabled, let aiService = aiManager.makeService() {
            updateStage(.generatingSteps, progress: 0.5)
            do {
                let workflow = try await StepGenerator(aiService: aiService).generate(
                    from: session,
                    framesDirectory: framesDir,
                    aggregatedActions: actions.isEmpty ? nil : actions
                )
                updateStage(.annotatingFrames, progress: 0.8)
                let annotated = await annotate(workflow: workflow, actions: actions, framesDir: framesDir, geometry: geometry)
                lastWorkflow = annotated
                _ = try annotated.save(in: directory, baseName: baseName)
                print("  🧠 AI generated \(annotated.steps.count) steps: \"\(annotated.title)\"")
            } catch {
                print("  ⚠️ AI step generation failed: \(error.localizedDescription)")
            }
        } else {
            print(aiManager.isAIEnabled
                  ? "  🧠 AI step generation skipped — no provider configured"
                  : "  🧠 AI step generation disabled in settings")
        }

        // Stage 7: Save session
        updateStage(.buildingSession, progress: 0.95)
        session.processingState = .completed
        do {
            let sessionURL = try session.save(in: directory)
            print("⚙️ Processing complete! Session saved: \(sessionURL.lastPathComponent)")
        } catch {
            print("  ⚠️ Failed to save session: \(error.localizedDescription)")
            session.processingState = .failed
        }

        updateStage(session.processingState == .failed ? .failed : .complete, progress: 1.0)

        SessionViewerWindowManager.shared.open(
            session: session,
            workflow: lastWorkflow,
            baseDirectory: directory
        )
        return session
    }

    // MARK: - Re-process

    /// Re-run the whole pipeline for an existing recording from its raw inputs
    /// (video + metadata sidecar): frames, transcript, AI steps and annotations are all rebuilt.
    func reprocess(videoURL: URL, baseDirectory: URL) async {
        let baseName = videoURL.deletingPathExtension().lastPathComponent
        let sessionURL = baseDirectory.appendingPathComponent("\(baseName)_session.json")
        let existing = try? RecordingSession.load(from: sessionURL)

        var metadataURL = existing?.metadataFile.map { baseDirectory.appendingPathComponent($0) }
        if metadataURL == nil {
            let guess = baseDirectory.appendingPathComponent("\(baseName)_metadata.json")
            if FileManager.default.fileExists(atPath: guess.path) { metadataURL = guess }
        }

        print("🔄 Re-processing: \(baseName)")
        await process(videoURL: videoURL, metadataURL: metadataURL, duration: existing?.duration ?? 0)
    }

    // MARK: - Private

    private func transcribeIfPossible(_ videoURL: URL) async -> SpeechTranscriber.TranscriptResult? {
        guard SpeechTranscriber.isAvailable else {
            print("  🎙️ Speech recognition not available — skipping transcription")
            return nil
        }
        do {
            let transcript = try await speechTranscriber.transcribe(videoURL: videoURL)
            if transcript.fullText.isEmpty {
                print("  🎙️ No speech detected in recording")
            }
            return transcript
        } catch {
            print("  ⚠️ Speech transcription skipped: \(error.localizedDescription)")
            return nil
        }
    }

    /// Draw each step's annotated frame on a background thread and attach the filenames.
    private func annotate(
        workflow: GeneratedWorkflow,
        actions: [AggregatedAction],
        framesDir: URL,
        geometry: CaptureGeometry?
    ) async -> GeneratedWorkflow {
        let annotator = frameAnnotator
        let steps = workflow.steps
        let map = await Task.detached(priority: .userInitiated) {
            annotator.annotateAllFrames(steps: steps, actions: actions, framesDirectory: framesDir, geometry: geometry)
        }.value

        guard !map.isEmpty else { return workflow }
        var updated = steps
        for i in updated.indices {
            if let file = map[updated[i].stepNumber] {
                updated[i].annotatedScreenshotFile = file
            }
        }
        return GeneratedWorkflow(
            title: workflow.title,
            summary: workflow.summary,
            steps: updated,
            aiAgentPrompt: workflow.aiAgentPrompt,
            modelUsed: workflow.modelUsed
        )
    }

    /// Remove frames from a previous run so re-processing doesn't mix old and new files.
    /// Only touches the recording's own `<base>_frames` directory.
    private func clearFramesDirectory(_ url: URL, baseName: String) {
        guard url.lastPathComponent == "\(baseName)_frames",
              FileManager.default.fileExists(atPath: url.path) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    private func updateStage(_ stage: Stage, progress: Double) {
        self.currentStage = stage
        self.progress = progress
    }
}
