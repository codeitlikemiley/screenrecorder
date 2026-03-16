import ArgumentParser

/// `sr` — command-line interface for Screen Recorder.
/// Talks to the running app via JSON-RPC on localhost:19820.
@main
struct SR: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "sr",
        abstract: "Control Screen Recorder from the command line.",
        discussion: """
            Communicates with the running Screen Recorder app via its \
            JSON-RPC server on localhost:19820. The app must be running.
            """,
        version: "1.0.0",
        subcommands: [
            Status.self,
            Record.self,
            Annotate.self,
            Screenshot.self,
            Tool.self,
            Screen.self,
            Windows.self,
            Detect.self,
            Session.self,
        ],
        defaultSubcommand: Status.self
    )
}
