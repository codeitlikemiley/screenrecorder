import Foundation
import Combine

/// Orchestrates the post-recording processing pipeline.
/// Runs key frame extraction, speech transcription, and AI step generation after a recording completes,
/// producing a complete RecordingSession bundle and workflow.
///
/// Pipeline stages:
/// 1. Load interaction metadata from JSON sidecar
/// 2. Extract key frames at interaction timestamps
/// 3. Transcribe speech from audio track
/// 4. Generate AI steps (if configured)
/// 5. Build and save RecordingSession
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
        case generatingSteps = "Generating AI steps…"
        case buildingSession = "Building session…"
        case complete = "Complete"
        case failed = "Failed"
    }

    // MARK: - Components

    private let keyFrameExtractor = KeyFrameExtractor()
    private let speechTranscriber = SpeechTranscriber()
    private lazy var stepGenerator: StepGenerator = {
        // Default AIService — will be replaced at generation time with active provider
        let service = AIProviderManager.shared.makeService() ?? DummyAIService()
        return StepGenerator(aiService: service)
    }()

    // MARK: - Process Recording

    /// Process a completed recording.
    /// - Parameters:
    ///   - videoURL: URL of the recorded video file
    ///   - metadataURL: URL of the interaction metadata JSON (from InteractionLogger)
    ///   - duration: Total recording duration in seconds
    /// - Returns: A fully processed RecordingSession
    func process(
        videoURL: URL,
        metadataURL: URL?,
        duration: TimeInterval
    ) async -> RecordingSession? {
        isProcessing = true
        progress = 0

        print("⚙️ Post-recording processing started")
        var events: [InteractionEvent] = []

        // Stage 1: Load interaction metadata
        updateStage(.loadingMetadata, progress: 0.05)

        if let metadataURL = metadataURL {
            do {
                let data = try Data(contentsOf: metadataURL)
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                let metadata = try decoder.decode(RecordingMetadata.self, from: data)
                events = metadata.events
                print("  📋 Loaded \(events.count) interaction events")
            } catch {
                print("  ⚠️ Failed to load interaction metadata: \(error.localizedDescription)")
            }
        }

        // Create initial session
        var session = RecordingSession.create(
            videoURL: videoURL,
            metadataURL: metadataURL,
            duration: duration,
            events: events
        )
        session.processingState = .processing

        // Stage 2: Extract key frames
        updateStage(.extractingFrames, progress: 0.1)

        let framesDir = videoURL.deletingLastPathComponent()
            .appendingPathComponent(session.framesDirectory ?? "frames", isDirectory: true)

        do {
            let strategy: KeyFrameExtractor.ExtractionStrategy
            if events.isEmpty {
                // No interaction data — extract at 2-second intervals
                strategy = .atInterval(2.0)
            } else {
                strategy = .atInteractions(events)
            }

            let extractedFrames = try await keyFrameExtractor.extractFrames(
                from: videoURL,
                strategy: strategy,
                outputDirectory: framesDir
            )

            session.frames = extractedFrames.map { frame in
                RecordingSession.FrameReference(
                    filename: frame.imageURL.lastPathComponent,
                    timestamp: frame.timestamp,
                    trigger: frame.trigger
                )
            }

            updateStage(.extractingFrames, progress: 0.3)
            print("  📸 Extracted \(extractedFrames.count) key frames")
        } catch {
            print("  ⚠️ Key frame extraction failed: \(error.localizedDescription)")
            // Non-fatal — continue processing
        }

        // Stage 3: Transcribe speech
        updateStage(.transcribingSpeech, progress: 0.35)

        if SpeechTranscriber.isAvailable {
            do {
                let transcript = try await speechTranscriber.transcribe(videoURL: videoURL)
                session.transcript = transcript

                if transcript.fullText.isEmpty {
                    print("  🎙️ No speech detected in recording")
                } else {
                    print("  🎙️ Transcribed: \"\(String(transcript.fullText.prefix(80)))...\"")
                }

                updateStage(.transcribingSpeech, progress: 0.5)
            } catch {
                print("  ⚠️ Speech transcription failed: \(error.localizedDescription)")
                // Non-fatal — continue without transcript
            }
        } else {
            print("  🎙️ Speech recognition not available — skipping transcription")
        }

        // Stage 4: AI Step Generation (if configured)
        let aiManager = AIProviderManager.shared
        if aiManager.isAIEnabled, let aiService = aiManager.makeService() {
            // Create a fresh StepGenerator with the active provider
            let generator = StepGenerator(aiService: aiService)
            updateStage(.generatingSteps, progress: 0.55)

            do {
                let workflow = try await generator.generate(from: session, framesDirectory: framesDir)
                lastWorkflow = workflow

                // Save workflow JSON alongside the recording
                let baseName = (videoURL.deletingPathExtension().lastPathComponent)
                let _ = try workflow.save(
                    in: videoURL.deletingLastPathComponent(),
                    baseName: baseName
                )

                updateStage(.generatingSteps, progress: 0.85)
                print("  🧠 AI generated \(workflow.steps.count) steps: \"\(workflow.title)\"")
            } catch {
                print("  ⚠️ AI step generation failed: \(error.localizedDescription)")
                // Non-fatal — session is still saved without AI steps
            }
        } else {
            if !aiManager.isAIEnabled {
                print("  🧠 AI step generation disabled in settings")
            } else {
                print("  🧠 AI step generation skipped — no provider configured")
            }
        }

        // Stage 5: Save session
        updateStage(.buildingSession, progress: 0.9)

        session.processingState = .completed

        do {
            let sessionURL = try session.save(in: videoURL.deletingLastPathComponent())
            print("⚙️ Processing complete! Session saved: \(sessionURL.lastPathComponent)")
        } catch {
            print("  ⚠️ Failed to save session: \(error.localizedDescription)")
            session.processingState = .failed
        }

        // Done
        updateStage(.complete, progress: 1.0)
        isProcessing = false

        // Open the session viewer window
        SessionViewerWindowManager.shared.open(
            session: session,
            workflow: lastWorkflow,
            baseDirectory: videoURL.deletingLastPathComponent()
        )

        return session
    }

    // MARK: - Re-process

    /// Re-process an existing recording with the current AI provider.
    /// Reuses existing frames (skips extraction), re-runs AI, saves updated workflow.
    func reprocess(videoURL: URL, baseDirectory: URL) async {
        isProcessing = true
        progress = 0

        let baseName = videoURL.deletingPathExtension().lastPathComponent

        // Load existing session
        let sessionURL = baseDirectory.appendingPathComponent("\(baseName)_session.json")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        guard let sessionData = try? Data(contentsOf: sessionURL),
              var session = try? decoder.decode(RecordingSession.self, from: sessionData) else {
            print("⚠️ Cannot re-process: no session file found for \(baseName)")
            // If no session exists, fall through to full process
            _ = await process(videoURL: videoURL, metadataURL: nil, duration: 0)
            return
        }

        print("🔄 Re-processing: \(baseName)")

        // Use existing frames directory
        let framesDir = baseDirectory
            .appendingPathComponent(session.framesDirectory ?? "\(baseName)_frames", isDirectory: true)

        updateStage(.generatingSteps, progress: 0.2)

        // Re-run AI with current active provider
        let aiManager = AIProviderManager.shared
        guard aiManager.isAIEnabled, let aiService = aiManager.makeService() else {
            print("⚠️ Re-process failed: no AI provider configured")
            updateStage(.failed, progress: 0)
            isProcessing = false
            return
        }

        let generator = StepGenerator(aiService: aiService)

        do {
            let workflow = try await generator.generate(from: session, framesDirectory: framesDir)
            lastWorkflow = workflow

            // Save updated workflow JSON (overwrites previous)
            let _ = try workflow.save(in: baseDirectory, baseName: baseName)

            updateStage(.generatingSteps, progress: 0.9)
            print("  🧠 Re-generated \(workflow.steps.count) steps: \"\(workflow.title)\"")

            // Update session processing state
            session.processingState = .completed
            let _ = try session.save(in: baseDirectory)

        } catch {
            print("  ⚠️ AI re-processing failed: \(error.localizedDescription)")
            session.processingState = .failed
            let _ = try? session.save(in: baseDirectory)
        }

        updateStage(.complete, progress: 1.0)
        isProcessing = false

        // Open the session viewer with the updated data
        SessionViewerWindowManager.shared.open(
            session: session,
            workflow: lastWorkflow,
            baseDirectory: baseDirectory
        )
    }

    // MARK: - Private

    private func updateStage(_ stage: Stage, progress: Double) {
        self.currentStage = stage
        self.progress = progress
    }
}
