import Foundation
import Combine

/// Orchestrates the post-recording processing pipeline.
/// Runs key frame extraction, event aggregation, speech transcription, AI step generation,
/// and frame annotation after a recording completes.
///
/// Pipeline stages:
/// 1. Load interaction metadata from JSON sidecar
/// 2. Extract key frames at interaction timestamps
/// 3. Transcribe speech from audio track
/// 4. Aggregate raw events into semantic actions
/// 5. Generate AI steps (if configured)
/// 6. Annotate frames with bounding boxes
/// 7. Build and save RecordingSession
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

            updateStage(.extractingFrames, progress: 0.25)
            print("  📸 Extracted \(extractedFrames.count) key frames")
        } catch {
            print("  ⚠️ Key frame extraction failed: \(error.localizedDescription)")
        }

        // Stage 3: Transcribe speech
        updateStage(.transcribingSpeech, progress: 0.3)

        if SpeechTranscriber.isAvailable {
            do {
                let transcript = try await speechTranscriber.transcribe(videoURL: videoURL)
                session.transcript = transcript

                if transcript.fullText.isEmpty {
                    print("  🎙️ No speech detected in recording")
                } else {
                    print("  🎙️ Transcribed: \"\(String(transcript.fullText.prefix(80)))...\"")
                }

                updateStage(.transcribingSpeech, progress: 0.4)
            } catch {
                print("  ⚠️ Speech transcription failed: \(error.localizedDescription)")
            }
        } else {
            print("  🎙️ Speech recognition not available — skipping transcription")
        }

        // Stage 4: Aggregate events
        updateStage(.aggregatingEvents, progress: 0.45)

        let aggregatedActions: [AggregatedAction]
        if !events.isEmpty {
            aggregatedActions = eventAggregator.aggregate(
                events: events,
                transcript: session.transcript
            )
            session.aggregatedActions = aggregatedActions
        } else {
            aggregatedActions = []
        }

        updateStage(.aggregatingEvents, progress: 0.5)

        // Stage 5: AI Step Generation (if configured)
        let aiManager = AIProviderManager.shared
        if aiManager.isAIEnabled, let aiService = aiManager.makeService() {
            let generator = StepGenerator(aiService: aiService)
            updateStage(.generatingSteps, progress: 0.55)

            do {
                let workflow = try await generator.generate(
                    from: session,
                    framesDirectory: framesDir,
                    aggregatedActions: aggregatedActions.isEmpty ? nil : aggregatedActions
                )
                lastWorkflow = workflow

                // Save workflow JSON alongside the recording
                let baseName = videoURL.deletingPathExtension().lastPathComponent
                let _ = try workflow.save(
                    in: videoURL.deletingLastPathComponent(),
                    baseName: baseName
                )

                updateStage(.generatingSteps, progress: 0.75)
                print("  🧠 AI generated \(workflow.steps.count) steps: \"\(workflow.title)\"")

                // Stage 6: Annotate frames with bounding boxes
                updateStage(.annotatingFrames, progress: 0.8)

                if !aggregatedActions.isEmpty {
                    let annotationMap = frameAnnotator.annotateAllFrames(
                        steps: workflow.steps,
                        actions: aggregatedActions,
                        framesDirectory: framesDir
                    )

                    // Update workflow steps with annotated screenshot references
                    if !annotationMap.isEmpty, var updatedWorkflow = lastWorkflow {
                        var updatedSteps = updatedWorkflow.steps
                        for i in updatedSteps.indices {
                            if let original = updatedSteps[i].screenshotFile,
                               let annotated = annotationMap[original] {
                                updatedSteps[i].annotatedScreenshotFile = annotated
                            }
                        }
                        updatedWorkflow = GeneratedWorkflow(
                            title: updatedWorkflow.title,
                            summary: updatedWorkflow.summary,
                            steps: updatedSteps,
                            aiAgentPrompt: updatedWorkflow.aiAgentPrompt,
                            modelUsed: updatedWorkflow.modelUsed
                        )
                        lastWorkflow = updatedWorkflow

                        // Re-save workflow with annotation references
                        let _ = try? updatedWorkflow.save(
                            in: videoURL.deletingLastPathComponent(),
                            baseName: baseName
                        )
                        print("  🎨 Updated workflow with \(annotationMap.count) annotated frames")
                    }
                }

            } catch {
                print("  ⚠️ AI step generation failed: \(error.localizedDescription)")
            }
        } else {
            if !aiManager.isAIEnabled {
                print("  🧠 AI step generation disabled in settings")
            } else {
                print("  🧠 AI step generation skipped — no provider configured")
            }
        }

        // Stage 7: Save session
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
    /// Re-aggregates events, re-runs AI, annotates frames, saves updated workflow.
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
            _ = await process(videoURL: videoURL, metadataURL: nil, duration: 0)
            return
        }

        print("🔄 Re-processing: \(baseName)")

        let framesDir = baseDirectory
            .appendingPathComponent(session.framesDirectory ?? "\(baseName)_frames", isDirectory: true)

        // Re-aggregate events if we have raw events or metadata
        updateStage(.aggregatingEvents, progress: 0.1)

        var events: [InteractionEvent] = session.rawEvents ?? []

        // If no raw events in session, try loading from metadata file
        if events.isEmpty, let metadataFile = session.metadataFile {
            let metadataURL = baseDirectory.appendingPathComponent(metadataFile)
            if let data = try? Data(contentsOf: metadataURL) {
                let metaDecoder = JSONDecoder()
                metaDecoder.dateDecodingStrategy = .iso8601
                if let metadata = try? metaDecoder.decode(RecordingMetadata.self, from: data) {
                    events = metadata.events
                }
            }
        }

        let aggregatedActions: [AggregatedAction]
        if !events.isEmpty {
            aggregatedActions = eventAggregator.aggregate(
                events: events,
                transcript: session.transcript
            )
            session.aggregatedActions = aggregatedActions
            session.rawEvents = events
        } else {
            aggregatedActions = session.aggregatedActions ?? []
        }

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
            let workflow = try await generator.generate(
                from: session,
                framesDirectory: framesDir,
                aggregatedActions: aggregatedActions.isEmpty ? nil : aggregatedActions
            )
            lastWorkflow = workflow

            // Save updated workflow JSON
            let _ = try workflow.save(in: baseDirectory, baseName: baseName)

            updateStage(.annotatingFrames, progress: 0.7)

            // Re-annotate frames
            if !aggregatedActions.isEmpty {
                let annotationMap = frameAnnotator.annotateAllFrames(
                    steps: workflow.steps,
                    actions: aggregatedActions,
                    framesDirectory: framesDir
                )

                if !annotationMap.isEmpty {
                    var updatedSteps = workflow.steps
                    for i in updatedSteps.indices {
                        if let original = updatedSteps[i].screenshotFile,
                           let annotated = annotationMap[original] {
                            updatedSteps[i].annotatedScreenshotFile = annotated
                        }
                    }
                    let updatedWorkflow = GeneratedWorkflow(
                        title: workflow.title,
                        summary: workflow.summary,
                        steps: updatedSteps,
                        aiAgentPrompt: workflow.aiAgentPrompt,
                        modelUsed: workflow.modelUsed
                    )
                    lastWorkflow = updatedWorkflow
                    let _ = try? updatedWorkflow.save(in: baseDirectory, baseName: baseName)
                }
            }

            updateStage(.generatingSteps, progress: 0.9)
            print("  🧠 Re-generated \(workflow.steps.count) steps: \"\(workflow.title)\"")

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
