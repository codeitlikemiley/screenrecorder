import Foundation

// MARK: - Teleprompter Script

/// Holds the user's script text and provides derived reading metrics.
struct TeleprompterScript: Equatable {

    /// The raw script content
    var text: String = ""

    /// Average words per minute for reading duration estimate
    var wordsPerMinute: Double = 150

    // MARK: Derived Metrics

    var wordCount: Int {
        guard !text.isEmpty else { return 0 }
        return text.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .count
    }

    var estimatedDuration: TimeInterval {
        guard wordCount > 0, wordsPerMinute > 0 else { return 0 }
        return (Double(wordCount) / wordsPerMinute) * 60
    }

    var formattedDuration: String {
        let total = Int(estimatedDuration)
        let minutes = total / 60
        let seconds = total % 60
        if minutes > 0 {
            return "\(minutes)m \(seconds)s"
        }
        return "\(seconds)s"
    }

    var isEmpty: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// Split the script into individual lines for indexed rendering.
    var lines: [String] {
        text.components(separatedBy: .newlines)
    }

    /// All words in the script as a flat array (for Auto continuous-scroll mode).
    var allWords: [String] {
        text.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
    }

    // MARK: - Smart Slide Chunking

    /// User-insertable separator to force a slide break.
    static let manualSeparator = "---"

    /// Split the script into slides by grouping sentences until a slide is full.
    ///
    /// Algorithm:
    /// 1. Split on `---` (explicit user-defined separators) — forced slide break
    /// 2. Split each segment on newlines to get individual lines
    /// 3. Split each line at sentence boundaries (. ! ?)
    /// 4. Group sentences onto a slide until adding another would exceed `maxWords`
    /// 5. If a single sentence exceeds `maxWords`, split at word boundaries
    ///    so overflow words go to the next slide
    /// 6. Trim whitespace, filter empty slides
    func slides(maxWords: Int = 60) -> [String] {
        guard !isEmpty else { return [] }

        // Step 1: Split on explicit separators
        let manualSegments = text.components(separatedBy: Self.manualSeparator)

        var result: [String] = []

        for segment in manualSegments {
            let trimmed = segment.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

            // Step 2+3: Collect all sentences from this segment
            var allSentences: [String] = []
            let lines = trimmed.components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }

            for line in lines {
                let sentences = splitIntoSentences(line)
                allSentences.append(contentsOf: sentences)
            }

            // Step 4: Group sentences into slides
            var currentSlide: [String] = []
            var currentWordCount = 0

            for sentence in allSentences {
                let words = sentence.components(separatedBy: .whitespacesAndNewlines)
                    .filter { !$0.isEmpty }
                let wordCount = words.count

                if wordCount > maxWords {
                    // Step 5: Single sentence too long — flush current slide, then split
                    if !currentSlide.isEmpty {
                        result.append(currentSlide.joined(separator: "\n"))
                        currentSlide = []
                        currentWordCount = 0
                    }
                    let wordSlides = splitAtWordBoundaries(words: words, maxWords: maxWords)
                    result.append(contentsOf: wordSlides)
                } else if currentWordCount + wordCount > maxWords && !currentSlide.isEmpty {
                    // Adding this sentence would overflow — flush and start new slide
                    result.append(currentSlide.joined(separator: "\n"))
                    currentSlide = [sentence]
                    currentWordCount = wordCount
                } else {
                    // Fits on current slide
                    currentSlide.append(sentence)
                    currentWordCount += wordCount
                }
            }

            // Flush remaining
            if !currentSlide.isEmpty {
                result.append(currentSlide.joined(separator: "\n"))
            }
        }

        return result
    }

    /// Split a list of words into slides of at most `maxWords` each.
    /// Overflow words go to the next slide — never cuts mid-word.
    private func splitAtWordBoundaries(words: [String], maxWords: Int) -> [String] {
        var result: [String] = []
        var i = 0

        while i < words.count {
            let end = min(i + maxWords, words.count)
            let chunk = words[i..<end].joined(separator: " ")
            result.append(chunk)
            i = end
        }

        return result
    }

    /// Simple sentence splitter: splits on . ! ? followed by a space or end of string.
    private func splitIntoSentences(_ text: String) -> [String] {
        var sentences: [String] = []
        var current = ""

        let chars = Array(text)
        for i in 0..<chars.count {
            current.append(chars[i])

            let isTerminator = chars[i] == "." || chars[i] == "!" || chars[i] == "?"
            let isEnd = i == chars.count - 1
            let nextIsSpace = !isEnd && (chars[i + 1] == " " || chars[i + 1] == "\n")

            if isTerminator && (isEnd || nextIsSpace) {
                let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    sentences.append(trimmed)
                }
                current = ""
            }
        }

        // Remaining text (no terminator)
        let remaining = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !remaining.isEmpty {
            sentences.append(remaining)
        }

        return sentences
    }
}

// MARK: - Persistence

extension TeleprompterScript {

    private static var storageDirectory: URL {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        return appSupport.appendingPathComponent("ScreenRecorder", isDirectory: true)
    }

    private static var fileURL: URL {
        storageDirectory.appendingPathComponent("teleprompter_script.txt")
    }

    /// Load the last-saved script from disk.
    static func loadFromDisk() -> TeleprompterScript {
        var script = TeleprompterScript()
        guard let data = try? Data(contentsOf: fileURL),
              let text = String(data: data, encoding: .utf8)
        else { return script }
        script.text = text
        return script
    }

    /// Persist the current script text to disk.
    func saveToDisk() {
        let dir = Self.storageDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? text.write(to: Self.fileURL, atomically: true, encoding: .utf8)
    }
}
