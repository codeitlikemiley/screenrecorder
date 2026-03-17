import AppKit
import ApplicationServices

/// Bridge to the macOS Accessibility (AX) API for programmatic UI element interaction.
/// Provides access to the accessibility tree of running applications, enabling
/// AI agents to discover and interact with real UI elements (buttons, text fields,
/// menus, etc.) beyond what OCR can detect.
///
/// Requires the same Accessibility permission as `InputSynthesizer`.
class AccessibilityBridge {

    // MARK: - System-Wide Element

    /// Get the system-wide accessibility element (root of all UI).
    static let systemWide = AXUIElementCreateSystemWide()

    // MARK: - Focused Application

    /// Get the accessibility element for the currently focused application.
    static func focusedApplication() -> AXUIElement? {
        var app: AnyObject?
        let result = AXUIElementCopyAttributeValue(systemWide, kAXFocusedApplicationAttribute as CFString, &app)
        guard result == .success else { return nil }
        return (app as! AXUIElement)
    }

    /// Get the currently focused UI element.
    static func focusedElement() -> AXUIElement? {
        guard let app = focusedApplication() else { return nil }
        var element: AnyObject?
        let result = AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &element)
        guard result == .success else { return nil }
        return (element as! AXUIElement)
    }

    // MARK: - App Element from PID

    /// Create an accessibility element for a running app by its PID.
    static func appElement(pid: pid_t) -> AXUIElement {
        return AXUIElementCreateApplication(pid)
    }

    /// Create an accessibility element for a running app by name.
    static func appElement(named name: String) -> AXUIElement? {
        guard let app = NSWorkspace.shared.runningApplications.first(where: {
            $0.localizedName?.localizedCaseInsensitiveContains(name) ?? false
        }) else { return nil }
        return AXUIElementCreateApplication(app.processIdentifier)
    }

    /// Create an accessibility element for a running app by bundle ID.
    static func appElement(bundleId: String) -> AXUIElement? {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).first
        else { return nil }
        return AXUIElementCreateApplication(app.processIdentifier)
    }

    // MARK: - Attribute Reading

    /// Get a string attribute value from an element.
    static func stringAttribute(_ attribute: String, of element: AXUIElement) -> String? {
        var value: AnyObject?
        let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard result == .success else { return nil }
        return value as? String
    }

    /// Get an integer attribute value from an element.
    static func intAttribute(_ attribute: String, of element: AXUIElement) -> Int? {
        var value: AnyObject?
        let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard result == .success else { return nil }
        return value as? Int
    }

    /// Get a boolean attribute value from an element.
    static func boolAttribute(_ attribute: String, of element: AXUIElement) -> Bool? {
        var value: AnyObject?
        let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard result == .success else { return nil }
        return (value as? NSNumber)?.boolValue
    }

    /// Get the position of an element on screen.
    static func position(of element: AXUIElement) -> CGPoint? {
        var value: AnyObject?
        let result = AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &value)
        guard result == .success else { return nil }
        var point = CGPoint.zero
        AXValueGetValue(value as! AXValue, .cgPoint, &point)
        return point
    }

    /// Get the size of an element.
    static func size(of element: AXUIElement) -> CGSize? {
        var value: AnyObject?
        let result = AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &value)
        guard result == .success else { return nil }
        var size = CGSize.zero
        AXValueGetValue(value as! AXValue, .cgSize, &size)
        return size
    }

    /// Get the bounding frame (position + size) of an element.
    static func frame(of element: AXUIElement) -> CGRect? {
        guard let pos = position(of: element), let sz = size(of: element) else {
            return nil
        }
        return CGRect(origin: pos, size: sz)
    }

    /// Get the center point of an element.
    static func center(of element: AXUIElement) -> CGPoint? {
        guard let frame = frame(of: element) else { return nil }
        return CGPoint(x: frame.midX, y: frame.midY)
    }

    /// Get all attribute names supported by an element.
    static func attributeNames(of element: AXUIElement) -> [String] {
        var names: CFArray?
        let result = AXUIElementCopyAttributeNames(element, &names)
        guard result == .success, let nameArray = names as? [String] else { return [] }
        return nameArray
    }

    /// Get all available actions for an element.
    static func actionNames(of element: AXUIElement) -> [String] {
        var names: CFArray?
        let result = AXUIElementCopyActionNames(element, &names)
        guard result == .success, let nameArray = names as? [String] else { return [] }
        return nameArray
    }

    // MARK: - Children / Tree Traversal

    /// Get children of an element.
    static func children(of element: AXUIElement) -> [AXUIElement] {
        var value: AnyObject?
        let result = AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value)
        guard result == .success, let children = value as? [AXUIElement] else { return [] }
        return children
    }

    /// Get the window elements of an app.
    static func windows(of appElement: AXUIElement) -> [AXUIElement] {
        var value: AnyObject?
        let result = AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &value)
        guard result == .success, let windows = value as? [AXUIElement] else { return [] }
        return windows
    }

    /// Get the focused window of an app.
    static func focusedWindow(of appElement: AXUIElement) -> AXUIElement? {
        var value: AnyObject?
        let result = AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &value)
        guard result == .success else { return nil }
        return (value as! AXUIElement)
    }

    // MARK: - Actions

    /// Perform an accessibility action on an element (e.g., AXPress, AXOpen).
    @discardableResult
    static func performAction(_ action: String, on element: AXUIElement) -> Bool {
        return AXUIElementPerformAction(element, action as CFString) == .success
    }

    /// Press (click) an element.
    @discardableResult
    static func press(_ element: AXUIElement) -> Bool {
        return performAction(kAXPressAction as String, on: element)
    }

    /// Set the value of an element (e.g., set text field content).
    @discardableResult
    static func setValue(_ value: Any, on element: AXUIElement) -> Bool {
        return AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, value as CFTypeRef) == .success
    }

    /// Set focus on an element.
    @discardableResult
    static func setFocus(on element: AXUIElement) -> Bool {
        return AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, true as CFTypeRef) == .success
    }

    // MARK: - Element Search

    /// Find elements matching a role within a subtree (limited depth search).
    /// - Parameters:
    ///   - root: Starting element
    ///   - role: AX role to match (e.g., "AXButton", "AXTextField", "AXStaticText")
    ///   - maxDepth: Maximum tree depth to search (default: 10)
    ///   - maxResults: Maximum results to return (default: 50)
    static func findElements(
        in root: AXUIElement,
        role: String,
        maxDepth: Int = 10,
        maxResults: Int = 50
    ) -> [AXUIElement] {
        var results: [AXUIElement] = []
        findElementsRecursive(element: root, role: role, depth: 0, maxDepth: maxDepth, maxResults: maxResults, results: &results)
        return results
    }

    private static func findElementsRecursive(
        element: AXUIElement,
        role: String,
        depth: Int,
        maxDepth: Int,
        maxResults: Int,
        results: inout [AXUIElement]
    ) {
        guard depth < maxDepth, results.count < maxResults else { return }

        let elementRole = stringAttribute(kAXRoleAttribute as String, of: element) ?? ""
        if elementRole == role {
            results.append(element)
        }

        for child in children(of: element) {
            findElementsRecursive(element: child, role: role, depth: depth + 1, maxDepth: maxDepth, maxResults: maxResults, results: &results)
        }
    }

    /// Find an element by its title/label text within a subtree.
    static func findElement(
        in root: AXUIElement,
        withTitle title: String,
        maxDepth: Int = 10
    ) -> AXUIElement? {
        return findElementByTitle(element: root, title: title.lowercased(), depth: 0, maxDepth: maxDepth)
    }

    private static func findElementByTitle(
        element: AXUIElement,
        title: String,
        depth: Int,
        maxDepth: Int
    ) -> AXUIElement? {
        guard depth < maxDepth else { return nil }

        let elementTitle = stringAttribute(kAXTitleAttribute as String, of: element)?.lowercased() ?? ""
        let elementValue = stringAttribute(kAXValueAttribute as String, of: element)?.lowercased() ?? ""
        let elementDesc = stringAttribute(kAXDescriptionAttribute as String, of: element)?.lowercased() ?? ""
        let elementLabel = stringAttribute(kAXLabelValueAttribute as String, of: element)?.lowercased() ?? ""

        if elementTitle.contains(title) || elementValue.contains(title) ||
           elementDesc.contains(title) || elementLabel.contains(title) {
            return element
        }

        for child in children(of: element) {
            if let found = findElementByTitle(element: child, title: title, depth: depth + 1, maxDepth: maxDepth) {
                return found
            }
        }

        return nil
    }

    // MARK: - Element Serialization

    /// Serialize an element's essential properties to a dictionary for JSON output.
    static func serialize(_ element: AXUIElement, includeChildren: Bool = false, depth: Int = 0, maxDepth: Int = 3) -> [String: Any] {
        var dict: [String: Any] = [:]

        dict["role"] = stringAttribute(kAXRoleAttribute as String, of: element) ?? "unknown"
        if let subrole = stringAttribute(kAXSubroleAttribute as String, of: element) {
            dict["subrole"] = subrole
        }
        if let title = stringAttribute(kAXTitleAttribute as String, of: element), !title.isEmpty {
            dict["title"] = title
        }
        if let value = stringAttribute(kAXValueAttribute as String, of: element), !value.isEmpty {
            dict["value"] = value
        }
        if let desc = stringAttribute(kAXDescriptionAttribute as String, of: element), !desc.isEmpty {
            dict["description"] = desc
        }
        if let label = stringAttribute(kAXLabelValueAttribute as String, of: element), !label.isEmpty {
            dict["label"] = label
        }
        if let roleDesc = stringAttribute(kAXRoleDescriptionAttribute as String, of: element), !roleDesc.isEmpty {
            dict["role_description"] = roleDesc
        }
        if let enabled = boolAttribute(kAXEnabledAttribute as String, of: element) {
            dict["enabled"] = enabled
        }
        if let frame = frame(of: element) {
            dict["frame"] = [
                "x": frame.origin.x, "y": frame.origin.y,
                "width": frame.size.width, "height": frame.size.height,
            ]
            dict["center"] = ["x": frame.midX, "y": frame.midY]
        }

        let actions = actionNames(of: element)
        if !actions.isEmpty {
            dict["actions"] = actions
        }

        if includeChildren && depth < maxDepth {
            let childElements = children(of: element)
            if !childElements.isEmpty {
                dict["children"] = childElements.prefix(50).map {
                    serialize($0, includeChildren: true, depth: depth + 1, maxDepth: maxDepth)
                }
                if childElements.count > 50 {
                    dict["children_truncated"] = true
                    dict["total_children"] = childElements.count
                }
            }
        }

        return dict
    }

    /// Serialize the UI tree of an app to a flat list of actionable elements.
    /// Only includes elements that have a title/label AND at least one action.
    static func serializeActionableElements(
        of root: AXUIElement,
        maxDepth: Int = 10,
        maxResults: Int = 100
    ) -> [[String: Any]] {
        var results: [[String: Any]] = []
        collectActionable(element: root, depth: 0, maxDepth: maxDepth, maxResults: maxResults, results: &results)
        return results
    }

    private static func collectActionable(
        element: AXUIElement,
        depth: Int,
        maxDepth: Int,
        maxResults: Int,
        results: inout [[String: Any]]
    ) {
        guard depth < maxDepth, results.count < maxResults else { return }

        let role = stringAttribute(kAXRoleAttribute as String, of: element) ?? ""
        let title = stringAttribute(kAXTitleAttribute as String, of: element) ?? ""
        let value = stringAttribute(kAXValueAttribute as String, of: element) ?? ""
        let desc = stringAttribute(kAXDescriptionAttribute as String, of: element) ?? ""
        let actions = actionNames(of: element)

        // Include if it has some identity AND is actionable
        let hasIdentity = !title.isEmpty || !value.isEmpty || !desc.isEmpty
        let isActionable = !actions.isEmpty || ["AXButton", "AXTextField", "AXTextArea", "AXCheckBox",
            "AXRadioButton", "AXPopUpButton", "AXMenuItem", "AXLink", "AXSlider",
            "AXTab", "AXComboBox"].contains(role)

        if hasIdentity && isActionable {
            var item = serialize(element)
            item["depth"] = depth
            results.append(item)
        }

        for child in children(of: element) {
            collectActionable(element: child, depth: depth + 1, maxDepth: maxDepth, maxResults: maxResults, results: &results)
        }
    }
}
