import ArgumentParser
import Foundation

/// `sr ax` — Accessibility API commands for native app automation.
///
/// Uses the macOS Accessibility (AX) API to discover and interact with UI elements
/// in native apps — buttons, text fields, menus, checkboxes, sliders.
/// This is MORE RELIABLE than coordinate-based clicks or OCR for native apps
/// because it works on the actual UI element tree, not a screenshot.
///
/// Requires Accessibility permission (System Settings → Privacy → Accessibility).
struct Ax: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ax",
        abstract: "Interact with native app UI elements via the Accessibility API (AX).",
        discussion: """
            Uses the macOS Accessibility (AX) API to discover and interact with UI elements
            in native apps without coordinate guessing or OCR.

            Examples:
              sr ax tree --app Safari                     # dump Safari's UI tree
              sr ax find --app Safari --title "Search"    # find element by title
              sr ax find --app Safari --role AXTextField  # find all text fields
              sr ax press --app Safari --title "Go"       # press (click) a button
              sr ax set-value --app Safari --title "Address and Search Bar" --value "https://youtube.com"
              sr ax focused                               # get focused UI element
              sr ax actionable --app Safari               # list all clickable elements
            """,
        subcommands: [
            Tree.self,
            Find.self,
            Press.self,
            SetValue.self,
            Focused.self,
            Actionable.self,
        ]
    )

    // MARK: - ax tree

    struct Tree: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Dump the UI element tree of an app."
        )

        @Option(name: .long, help: "App name (e.g. 'Safari', 'Finder')")
        var app: String?

        @Option(name: .long, help: "App bundle ID (e.g. 'com.apple.Safari')")
        var bundleId: String?

        @Option(name: .long, help: "Process PID")
        var pid: Int?

        @Option(name: .long, help: "Max tree depth (default: 3)")
        var maxDepth: Int = 3

        @Flag(name: .long, help: "Output as JSON")
        var json = false

        @Option(name: .long, help: "Server port")
        var port: Int = 19820

        func run() throws {
            let client = RPCClient(port: port)
            var params: [String: Any] = ["max_depth": maxDepth]
            if let a = app { params["app"] = a }
            if let b = bundleId { params["bundle_id"] = b }
            if let p = pid { params["pid"] = p }

            let result = try client.call("ax.tree", params: params)
            if json {
                print(try jsonString(result))
            } else if let ok = result["ok"] as? Bool, ok {
                print("🌲 Accessibility tree:")
                if let tree = result["tree"] as? [String: Any] {
                    printAXNode(tree, indent: "")
                }
            } else {
                print("❌ \(result["error"] as? String ?? "Failed to get AX tree")")
            }
        }
    }

    // MARK: - ax find

    struct Find: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Find UI elements by title or role."
        )

        @Option(name: .long, help: "App name")
        var app: String?

        @Option(name: .long, help: "App bundle ID")
        var bundleId: String?

        @Option(name: .long, help: "Process PID")
        var pid: Int?

        @Option(name: .long, help: "Title/label substring to match (e.g. 'Submit', 'Search')")
        var title: String?

        @Option(name: .long, help: "AX role to match (e.g. AXButton, AXTextField, AXCheckBox)")
        var role: String?

        @Option(name: .long, help: "Max results (default: 50)")
        var maxResults: Int = 50

        @Flag(name: .long, help: "Output as JSON")
        var json = false

        @Option(name: .long, help: "Server port")
        var port: Int = 19820

        func run() throws {
            guard title != nil || role != nil else {
                print("❌ Provide --title or --role (or both)")
                return
            }
            let client = RPCClient(port: port)
            var params: [String: Any] = ["max_results": maxResults]
            if let a = app { params["app"] = a }
            if let b = bundleId { params["bundle_id"] = b }
            if let p = pid { params["pid"] = p }
            if let t = title { params["title"] = t }
            if let r = role { params["role"] = r }

            let result = try client.call("ax.find", params: params)
            if json {
                print(try jsonString(result))
            } else if let ok = result["ok"] as? Bool, ok {
                if let el = result["element"] as? [String: Any] {
                    print("✅ Found element:")
                    printAXNode(el, indent: "  ")
                } else if let els = result["elements"] as? [[String: Any]] {
                    print("✅ Found \(els.count) element(s):")
                    for el in els { printAXNode(el, indent: "  "); print("") }
                }
            } else {
                print("❌ \(result["error"] as? String ?? "Element not found")")
            }
        }
    }

    // MARK: - ax press

    struct Press: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Press (click) a UI element by its title/label."
        )

        @Option(name: .long, help: "App name")
        var app: String?

        @Option(name: .long, help: "App bundle ID")
        var bundleId: String?

        @Option(name: .long, help: "Process PID")
        var pid: Int?

        @Option(name: .long, help: "Title/label of the element to press (e.g. 'Submit', 'Cancel')")
        var title: String

        @Option(name: .long, help: "AX action to perform (default: AXPress)")
        var action: String?

        @Option(name: .long, help: "Server port")
        var port: Int = 19820

        func run() throws {
            let client = RPCClient(port: port)
            var params: [String: Any] = ["title": title]
            if let a = app { params["app"] = a }
            if let b = bundleId { params["bundle_id"] = b }
            if let p = pid { params["pid"] = p }
            if let ac = action { params["action"] = ac }

            let result = try client.call("ax.press", params: params)
            if result["ok"] as? Bool == true {
                print("✅ Pressed: '\(title)'")
            } else {
                print("❌ \(result["error"] as? String ?? "Could not press element")")
            }
        }
    }

    // MARK: - ax set-value

    struct SetValue: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "set-value",
            abstract: "Set the value of a UI element (type into a text field, toggle a checkbox, etc.)."
        )

        @Option(name: .long, help: "App name")
        var app: String?

        @Option(name: .long, help: "App bundle ID")
        var bundleId: String?

        @Option(name: .long, help: "Process PID")
        var pid: Int?

        @Option(name: .long, help: "Title/label of the element (e.g. 'Address and Search Bar')")
        var title: String

        @Option(name: .long, help: "Value to set")
        var value: String

        @Option(name: .long, help: "Server port")
        var port: Int = 19820

        func run() throws {
            let client = RPCClient(port: port)
            var params: [String: Any] = ["title": title, "value": value]
            if let a = app { params["app"] = a }
            if let b = bundleId { params["bundle_id"] = b }
            if let p = pid { params["pid"] = p }

            let result = try client.call("ax.set_value", params: params)
            if result["ok"] as? Bool == true {
                print("✅ Set '\(title)' = \"\(value)\"")
            } else {
                print("❌ \(result["error"] as? String ?? "Could not set value")")
            }
        }
    }

    // MARK: - ax focused

    struct Focused: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Get the currently focused UI element."
        )

        @Flag(name: .long, help: "Output as JSON")
        var json = false

        @Option(name: .long, help: "Server port")
        var port: Int = 19820

        func run() throws {
            let client = RPCClient(port: port)
            let result = try client.call("ax.focused")
            if json {
                print(try jsonString(result))
            } else if let ok = result["ok"] as? Bool, ok,
                      let el = result["element"] as? [String: Any] {
                print("🔍 Focused element:")
                printAXNode(el, indent: "  ")
            } else {
                print("❌ \(result["error"] as? String ?? "No focused element")")
            }
        }
    }

    // MARK: - ax actionable

    struct Actionable: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "List all actionable UI elements (buttons, fields, menus) in an app."
        )

        @Option(name: .long, help: "App name")
        var app: String?

        @Option(name: .long, help: "App bundle ID")
        var bundleId: String?

        @Option(name: .long, help: "Process PID")
        var pid: Int?

        @Option(name: .long, help: "Max results (default: 100)")
        var maxResults: Int = 100

        @Flag(name: .long, help: "Output as JSON")
        var json = false

        @Option(name: .long, help: "Server port")
        var port: Int = 19820

        func run() throws {
            let client = RPCClient(port: port)
            var params: [String: Any] = ["max_results": maxResults]
            if let a = app { params["app"] = a }
            if let b = bundleId { params["bundle_id"] = b }
            if let p = pid { params["pid"] = p }

            let result = try client.call("ax.actionable", params: params)
            if json {
                print(try jsonString(result))
            } else if let ok = result["ok"] as? Bool, ok,
                      let elements = result["elements"] as? [[String: Any]] {
                let count = result["count"] as? Int ?? elements.count
                print("🎯 \(count) actionable element(s):")
                print("──────────────────────────────")
                for el in elements {
                    let role = el["role"] as? String ?? "?"
                    let title = el["title"] as? String ?? el["description"] as? String ?? el["label"] as? String ?? "(untitled)"
                    let actions = (el["actions"] as? [String] ?? []).joined(separator: ", ")
                    var center = ""
                    if let c = el["center"] as? [String: Any],
                       let cx = c["x"] as? Double, let cy = c["y"] as? Double {
                        center = " @ (\(Int(cx)), \(Int(cy)))"
                    }
                    print("  [\(role)] \(title)\(center)  [\(actions)]")
                }
            } else {
                print("❌ \(result["error"] as? String ?? "Failed")")
            }
        }
    }
}

// MARK: - Pretty-print helpers

private func printAXNode(_ node: [String: Any], indent: String) {
    let role = node["role"] as? String ?? "?"
    let title = node["title"] as? String ?? ""
    let value = node["value"] as? String ?? ""
    let desc = node["description"] as? String ?? ""
    let actions = (node["actions"] as? [String] ?? []).joined(separator: ", ")

    var line = "\(indent)[\(role)]"
    if !title.isEmpty { line += " \"\(title)\"" }
    if !value.isEmpty { line += " = \"\(value.prefix(60))\"" }
    if !desc.isEmpty && desc != title { line += " (\(desc.prefix(40)))" }
    if !actions.isEmpty { line += "  [\(actions)]" }

    if let c = node["center"] as? [String: Any],
       let cx = c["x"] as? Double, let cy = c["y"] as? Double {
        line += "  📍(\(Int(cx)), \(Int(cy)))"
    }
    print(line)

    if let children = node["children"] as? [[String: Any]] {
        for child in children {
            printAXNode(child, indent: indent + "  ")
        }
    }
}
