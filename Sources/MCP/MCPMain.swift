import Foundation

/// Entry point for the sr-mcp binary.
/// This is invoked by MCP clients (Claude Code, Cursor) via stdio.
@main
struct MCPMain {
    static func main() async {
        // Check for subcommands
        let args = CommandLine.arguments.dropFirst()

        if let firstArg = args.first {
            switch firstArg {
            case "activate":
                guard let key = args.dropFirst().first else {
                    fputs("Usage: sr-mcp activate <LICENSE_KEY>\n", stderr)
                    exit(1)
                }
                do {
                    let license = try await LicenseManager.shared.activate(key: key)
                    fputs("✅ License activated!\n", stderr)
                    fputs("   Plan: \(license.plan)\n", stderr)
                    fputs("   Email: \(license.email)\n", stderr)
                } catch {
                    fputs("❌ \(error.localizedDescription)\n", stderr)
                    exit(1)
                }
                return

            case "deactivate":
                LicenseManager.shared.deactivate()
                fputs("License deactivated.\n", stderr)
                return

            case "usage":
                let usage = LicenseManager.shared.currentUsage
                fputs("Plan: \(usage.plan)\n", stderr)
                if usage.limit == -1 {
                    fputs("Calls today: \(usage.used) (unlimited)\n", stderr)
                } else {
                    fputs("Calls today: \(usage.used) / \(usage.limit)\n", stderr)
                }
                return

            case "serve", "--stdio":
                break // Fall through to server mode

            default:
                fputs("Unknown command: \(firstArg)\n", stderr)
                fputs("Usage:\n", stderr)
                fputs("  sr-mcp serve         Start MCP server (stdio)\n", stderr)
                fputs("  sr-mcp activate KEY  Activate a license\n", stderr)
                fputs("  sr-mcp deactivate    Remove license\n", stderr)
                fputs("  sr-mcp usage         Show usage stats\n", stderr)
                exit(1)
            }
        }

        // Default: start MCP server
        let server = MCPServer()
        await server.start()
    }
}
