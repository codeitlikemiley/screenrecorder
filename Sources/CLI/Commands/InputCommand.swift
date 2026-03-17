import ArgumentParser
import Foundation

struct Input: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Control the computer — click, type, scroll, drag.",
        discussion: """
            Synthesize mouse and keyboard input. Requires Accessibility permission.
            Use 'sr input check-access' to verify permission is granted.

            Examples:
              sr input click 500 300              # click at (500, 300)
              sr input click 500 300 --count 2    # double-click
              sr input right-click 500 300        # right-click
              sr input drag 100 200 500 300       # drag from → to
              sr input scroll 500 300 --dy -100   # scroll down
              sr input move 500 300               # move cursor
              sr input type "hello world"         # type text
              sr input key return                 # press key
              sr input hotkey cmd+c               # keyboard shortcut
              sr input click-text "Submit"        # find text → click it
            """,
        subcommands: [
            Click.self,
            RightClick.self,
            DoubleClick.self,
            Drag.self,
            Scroll.self,
            Move.self,
            TypeText.self,
            Key.self,
            Hotkey.self,
            ClickText.self,
            CheckAccess.self,
        ]
    )

    // MARK: - Click

    struct Click: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Click at screen coordinates."
        )

        @Argument(help: "X coordinate")
        var x: Double

        @Argument(help: "Y coordinate")
        var y: Double

        @Option(name: .long, help: "Click count (2 = double-click)")
        var count: Int = 1

        @Option(name: .long, help: "Window app name for relative coordinates")
        var windowRef: String?

        @Option(name: .long, help: "Server port")
        var port: Int = 19820

        func run() throws {
            let client = RPCClient(port: port)
            var params: [String: Any] = ["x": x, "y": y, "click_count": count]
            if let wr = windowRef { params["window_ref"] = wr }
            let result = try client.call("input.click", params: params)
            let target = result["clicked_at"] as? [String: Any] ?? [:]
            print("🖱️ Clicked at (\(Int(target["x"] as? Double ?? x)), \(Int(target["y"] as? Double ?? y)))")
        }
    }

    // MARK: - Right-Click

    struct RightClick: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "right-click",
            abstract: "Right-click at screen coordinates."
        )

        @Argument(help: "X coordinate")
        var x: Double

        @Argument(help: "Y coordinate")
        var y: Double

        @Option(name: .long, help: "Window app name for relative coordinates")
        var windowRef: String?

        @Option(name: .long, help: "Server port")
        var port: Int = 19820

        func run() throws {
            let client = RPCClient(port: port)
            var params: [String: Any] = ["x": x, "y": y]
            if let wr = windowRef { params["window_ref"] = wr }
            _ = try client.call("input.right_click", params: params)
            print("🖱️ Right-clicked at (\(Int(x)), \(Int(y)))")
        }
    }

    // MARK: - Double-Click

    struct DoubleClick: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "double-click",
            abstract: "Double-click at screen coordinates."
        )

        @Argument(help: "X coordinate")
        var x: Double

        @Argument(help: "Y coordinate")
        var y: Double

        @Option(name: .long, help: "Window app name for relative coordinates")
        var windowRef: String?

        @Option(name: .long, help: "Server port")
        var port: Int = 19820

        func run() throws {
            let client = RPCClient(port: port)
            var params: [String: Any] = ["x": x, "y": y]
            if let wr = windowRef { params["window_ref"] = wr }
            _ = try client.call("input.double_click", params: params)
            print("🖱️ Double-clicked at (\(Int(x)), \(Int(y)))")
        }
    }

    // MARK: - Drag

    struct Drag: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Drag from one point to another."
        )

        @Argument(help: "Start X coordinate")
        var fromX: Double

        @Argument(help: "Start Y coordinate")
        var fromY: Double

        @Argument(help: "End X coordinate")
        var toX: Double

        @Argument(help: "End Y coordinate")
        var toY: Double

        @Option(name: .long, help: "Drag duration in seconds (default: 0.5)")
        var duration: Double = 0.5

        @Option(name: .long, help: "Window app name for relative coordinates")
        var windowRef: String?

        @Option(name: .long, help: "Server port")
        var port: Int = 19820

        func run() throws {
            let client = RPCClient(port: port)
            var params: [String: Any] = [
                "from_x": fromX, "from_y": fromY,
                "to_x": toX, "to_y": toY,
                "duration": duration,
            ]
            if let wr = windowRef { params["window_ref"] = wr }
            _ = try client.call("input.drag", params: params)
            print("🖱️ Dragged (\(Int(fromX)),\(Int(fromY))) → (\(Int(toX)),\(Int(toY)))")
        }
    }

    // MARK: - Scroll

    struct Scroll: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Scroll at a screen position."
        )

        @Argument(help: "X coordinate")
        var x: Double

        @Argument(help: "Y coordinate")
        var y: Double

        @Option(name: .long, help: "Horizontal scroll delta")
        var dx: Double = 0

        @Option(name: .long, help: "Vertical scroll delta (negative = down)")
        var dy: Double = 0

        @Option(name: .long, help: "Window app name for relative coordinates")
        var windowRef: String?

        @Option(name: .long, help: "Server port")
        var port: Int = 19820

        func run() throws {
            let client = RPCClient(port: port)
            var params: [String: Any] = ["x": x, "y": y, "delta_x": dx, "delta_y": dy]
            if let wr = windowRef { params["window_ref"] = wr }
            _ = try client.call("input.scroll", params: params)
            let dir = dy < 0 ? "down" : "up"
            print("🖱️ Scrolled \(dir) at (\(Int(x)), \(Int(y)))")
        }
    }

    // MARK: - Move

    struct Move: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Move cursor to a screen position."
        )

        @Argument(help: "X coordinate")
        var x: Double

        @Argument(help: "Y coordinate")
        var y: Double

        @Option(name: .long, help: "Window app name for relative coordinates")
        var windowRef: String?

        @Option(name: .long, help: "Server port")
        var port: Int = 19820

        func run() throws {
            let client = RPCClient(port: port)
            var params: [String: Any] = ["x": x, "y": y]
            if let wr = windowRef { params["window_ref"] = wr }
            _ = try client.call("input.move_mouse", params: params)
            print("🖱️ Moved to (\(Int(x)), \(Int(y)))")
        }
    }

    // MARK: - Type Text

    struct TypeText: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "type",
            abstract: "Type a string of text."
        )

        @Argument(help: "Text to type")
        var text: String

        @Option(name: .long, help: "Delay between chars in ms (default: 50)")
        var intervalMs: Int = 50

        @Option(name: .long, help: "Server port")
        var port: Int = 19820

        func run() throws {
            let client = RPCClient(port: port)
            _ = try client.call("input.type_text", params: ["text": text, "interval_ms": intervalMs])
            print("⌨️ Typed: \"\(text)\"")
        }
    }

    // MARK: - Key Press

    struct Key: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Press a named key (return, tab, escape, up, down, etc)."
        )

        @Argument(help: "Key name: return, tab, space, delete, escape, up, down, left, right, f1-f12")
        var key: String

        @Option(name: .long, help: "Modifier keys (comma-separated: cmd,shift,alt,ctrl)")
        var modifiers: String?

        @Option(name: .long, help: "Server port")
        var port: Int = 19820

        func run() throws {
            let client = RPCClient(port: port)
            var params: [String: Any] = ["key": key]
            if let mods = modifiers {
                params["modifiers"] = mods.split(separator: ",").map(String.init)
            }
            _ = try client.call("input.press_key", params: params)
            let modStr = modifiers.map { "\($0)+" } ?? ""
            print("⌨️ Pressed: \(modStr)\(key)")
        }
    }

    // MARK: - Hotkey

    struct Hotkey: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Execute a keyboard shortcut (e.g. cmd+c, ctrl+shift+4)."
        )

        @Argument(help: "Hotkey combo (e.g. cmd+c, cmd+shift+s)")
        var keys: String

        @Option(name: .long, help: "Server port")
        var port: Int = 19820

        func run() throws {
            let client = RPCClient(port: port)
            _ = try client.call("input.hotkey", params: ["keys": keys])
            print("⌨️ Executed: \(keys)")
        }
    }

    // MARK: - Click Text (OCR + Click)

    struct ClickText: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "click-text",
            abstract: "Find on-screen text via OCR and click its center."
        )

        @Argument(help: "Text to find and click")
        var text: String

        @Option(name: .long, help: "Window app name to search in")
        var window: String?

        @Option(name: .long, help: "Server port")
        var port: Int = 19820

        func run() throws {
            let client = RPCClient(port: port)
            var params: [String: Any] = ["text": text]
            if let w = window { params["window"] = w }
            let result = try client.call("input.click_element", params: params)
            if let ok = result["ok"] as? Bool, ok {
                let at = result["clicked_at"] as? [String: Any] ?? [:]
                let cx = at["x"] as? Double ?? 0
                let cy = at["y"] as? Double ?? 0
                print("🖱️ Clicked \"\(result["clicked_element"] as? String ?? text)\" at (\(Int(cx)), \(Int(cy)))")
            } else {
                let err = result["error"] as? String ?? "Element not found"
                print("❌ \(err)")
                if let available = result["available_elements"] as? [String] {
                    print("  Available: \(available.joined(separator: ", "))")
                }
            }
        }
    }

    // MARK: - Check Accessibility

    struct CheckAccess: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "check-access",
            abstract: "Check if Accessibility permission is granted."
        )

        @Option(name: .long, help: "Server port")
        var port: Int = 19820

        func run() throws {
            let client = RPCClient(port: port)
            let result = try client.call("accessibility.check")
            let granted = result["granted"] as? Bool ?? false
            let message = result["message"] as? String ?? ""
            print(granted ? "✅ \(message)" : "❌ \(message)")
        }
    }
}
