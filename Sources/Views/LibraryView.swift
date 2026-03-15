import SwiftUI
import AppKit

/// Library view showing all past recordings with thumbnails, dates, status, and actions.
struct LibraryView: View {
    @ObservedObject var library: RecordingLibrary
    let directory: URL
    @State private var selectedEntry: LibraryEntry?
    @State private var showDeleteConfirm = false
    @State private var entryToDelete: LibraryEntry?
    @State private var isReprocessing: String? = nil // entry ID being reprocessed

    var body: some View {
        VStack(spacing: 0) {
            // Header
            header

            Divider()

            // Content
            if library.entries.isEmpty {
                emptyState
            } else {
                entryList
            }
        }
        .frame(minWidth: 700, minHeight: 460)
        .background(.ultraThickMaterial)
        .task {
            await library.scan(directory: directory)
        }
        .alert("Delete Recording?", isPresented: $showDeleteConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                if let entry = entryToDelete {
                    library.delete(entry: entry)
                    if selectedEntry?.id == entry.id {
                        selectedEntry = nil
                    }
                }
            }
        } message: {
            if let entry = entryToDelete {
                Text("This will permanently remove the video, session data, AI-generated steps, and all extracted frames for \"\(entry.title)\".")
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "film.stack")
                .font(.system(size: 18))
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 1) {
                Text("Recording Library")
                    .font(.system(size: 16, weight: .semibold))
                Text("\(library.entries.count) recording\(library.entries.count == 1 ? "" : "s")")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                Task { await library.scan(directory: directory) }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
                    .font(.system(size: 12))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            Button {
                NSWorkspace.shared.open(directory)
            } label: {
                Label("Reveal in Finder", systemImage: "folder")
                    .font(.system(size: 12))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.5))
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "video.slash")
                .font(.system(size: 48))
                .foregroundStyle(.quaternary)
            Text("No recordings yet")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(.secondary)
            Text("Press ⌘⇧S to start your first recording")
                .font(.system(size: 13))
                .foregroundStyle(.tertiary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Entry List

    private var entryList: some View {
        ScrollView {
            LazyVStack(spacing: 1) {
                ForEach(library.entries) { entry in
                    entryRow(entry)
                        .background(
                            selectedEntry?.id == entry.id
                                ? Color.accentColor.opacity(0.1)
                                : Color.clear
                        )
                        .contentShape(Rectangle())
                        .onTapGesture {
                            selectedEntry = entry
                        }
                        .onTapGesture(count: 2) {
                            openSession(entry)
                        }
                }
            }
            .padding(.vertical, 4)
        }
    }

    // MARK: - Entry Row

    private func entryRow(_ entry: LibraryEntry) -> some View {
        HStack(spacing: 14) {
            // Thumbnail
            thumbnailView(for: entry)
                .frame(width: 120, height: 68)
                .clipShape(RoundedRectangle(cornerRadius: 6))

            // Info
            VStack(alignment: .leading, spacing: 4) {
                Text(entry.title)
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(1)

                HStack(spacing: 10) {
                    // Date
                    Label(formatDate(entry.recordingDate), systemImage: "calendar")
                    // Duration
                    Label(formatDuration(entry.duration), systemImage: "clock")
                    // Events
                    if entry.eventCount > 0 {
                        Label("\(entry.eventCount)", systemImage: "hand.tap")
                    }
                    // Steps
                    if entry.stepCount > 0 {
                        Label("\(entry.stepCount) steps", systemImage: "list.number")
                    }
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

                // Status badge
                statusBadge(entry.status)
            }

            Spacer()

            // Actions
            HStack(spacing: 6) {
                // Play video
                Button {
                    NSWorkspace.shared.open(entry.videoURL)
                } label: {
                    Image(systemName: "play.fill")
                        .font(.system(size: 13))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Play Original Video")

                // Open
                Button {
                    openSession(entry)
                } label: {
                    Image(systemName: "eye")
                        .font(.system(size: 13))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Open in Session Viewer")

                // Re-process with AI
                Button {
                    reprocessEntry(entry)
                } label: {
                    if isReprocessing == entry.id {
                        ProgressView()
                            .controlSize(.small)
                            .scaleEffect(0.7)
                    } else {
                        Image(systemName: "sparkles")
                            .font(.system(size: 13))
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(isReprocessing != nil)
                .help("Re-process with AI")

                // Reveal in Finder
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([entry.videoURL])
                } label: {
                    Image(systemName: "folder")
                        .font(.system(size: 13))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Reveal in Finder")

                // Delete
                Button {
                    entryToDelete = entry
                    showDeleteConfirm = true
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 13))
                        .foregroundStyle(.red)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Delete recording and all files")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: - Thumbnail

    @ViewBuilder
    private func thumbnailView(for entry: LibraryEntry) -> some View {
        if let image = library.thumbnail(for: entry) {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
        } else {
            ZStack {
                Color(nsColor: .controlBackgroundColor)
                Image(systemName: "film")
                    .font(.system(size: 24))
                    .foregroundStyle(.quaternary)
            }
        }
    }

    // MARK: - Status Badge

    private func statusBadge(_ status: LibraryEntry.Status) -> some View {
        HStack(spacing: 4) {
            Image(systemName: status.icon)
                .font(.system(size: 9))
            Text(status.rawValue)
                .font(.system(size: 10, weight: .medium))
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        .background(statusColor(status).opacity(0.12))
        .foregroundStyle(statusColor(status))
        .clipShape(Capsule())
    }

    private func statusColor(_ status: LibraryEntry.Status) -> Color {
        switch status {
        case .processed: return .green
        case .unprocessed: return .secondary
        case .processing: return .blue
        case .failed: return .red
        }
    }

    // MARK: - Actions

    private func openSession(_ entry: LibraryEntry) {
        SessionViewerWindowManager.shared.open(videoURL: entry.videoURL)
    }

    private func reprocessEntry(_ entry: LibraryEntry) {
        isReprocessing = entry.id
        Task {
            let processor = PostRecordingProcessor()
            await processor.reprocess(
                videoURL: entry.videoURL,
                baseDirectory: entry.videoURL.deletingLastPathComponent()
            )
            isReprocessing = nil
            // Refresh library to show updated status
            await library.scan(directory: directory)
        }
    }

    // MARK: - Formatting

    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        if mins > 0 {
            return "\(mins)m \(secs)s"
        }
        return "\(secs)s"
    }
}
