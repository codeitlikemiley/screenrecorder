import AppKit
import CoreGraphics
import Foundation

@MainActor
final class InteractionShieldManager {
    static let shared = InteractionShieldManager()

    private struct ShieldSnapshot {
        let scope: String
        var target: [String: Any]
        var mode: String = "automatic"
        var status: String
        var message: String
        var reason: String?
        var expiresAt: Date?

        func dictionary() -> [String: Any] {
            var dict: [String: Any] = [
                "scope": scope,
                "target": target,
                "mode": mode,
                "status": status,
                "message": message,
            ]
            if let reason {
                dict["reason"] = reason
            }
            if let expiresAt {
                dict["expires_at"] = ISO8601DateFormatter().string(from: expiresAt)
            }
            return dict
        }
    }

    private let autoDismissSeconds: TimeInterval = 8

    private var browserShield: ShieldSnapshot?
    private var nativeShield: ShieldSnapshot?

    private var nativeOverlayWindow: ShieldOverlayWindow?
    private var nativeRefreshTimer: Timer?
    private var nativeDismissTask: Task<Void, Never>?

    private init() {}

    func status() -> [String: Any] {
        var result: [String: Any] = ["ok": true]
        result["browser"] = browserShield?.dictionary() ?? [
            "scope": "browser_tab",
            "status": "dismissed",
            "mode": "automatic",
            "message": "",
            "target": [:],
        ]
        result["native"] = nativeShield?.dictionary() ?? [
            "scope": "native_window",
            "status": "dismissed",
            "mode": "automatic",
            "message": "",
            "target": [:],
        ]
        result["active_scope"] = activeScope()
        return result
    }

    func recordBrowserActive(
        backend: String,
        port: Int,
        tabId: String,
        title: String,
        url: String,
        message: String
    ) {
        browserShield = ShieldSnapshot(
            scope: "browser_tab",
            target: [
                "backend": backend,
                "port": port,
                "tab_id": tabId,
                "title": title,
                "url": url,
            ],
            status: "active",
            message: message,
            expiresAt: Date().addingTimeInterval(autoDismissSeconds)
        )
    }

    func recordBrowserFailed(
        backend: String,
        port: Int,
        message: String,
        reason: String
    ) {
        browserShield = ShieldSnapshot(
            scope: "browser_tab",
            target: ["backend": backend, "port": port],
            status: "failed",
            message: message,
            reason: reason
        )
    }

    func dismissBrowser(reason: String = "dismissed") {
        if let current = browserShield {
            browserShield = ShieldSnapshot(
                scope: current.scope,
                target: current.target,
                status: "dismissed",
                message: current.message,
                reason: reason
            )
        } else {
            browserShield = ShieldSnapshot(
                scope: "browser_tab",
                target: [:],
                status: "dismissed",
                message: "",
                reason: reason
            )
        }
    }

    @discardableResult
    func activateNative(windowId: Int?, pid: Int?, appName: String?, message: String) -> [String: Any] {
        guard let target = resolveNativeTarget(windowId: windowId, pid: pid, appName: appName),
              let bounds = windowBounds(windowId: target.windowId) else {
            hideNativeOverlay()
            nativeShield = ShieldSnapshot(
                scope: "native_window",
                target: [
                    "window_id": windowId as Any,
                    "pid": pid as Any,
                    "app": appName as Any,
                ].compactMapValues { $0 },
                status: "failed",
                message: message,
                reason: "Target window not found"
            )
            return nativeShield?.dictionary() ?? ["ok": false]
        }

        if let overlay = nativeOverlayWindow {
            overlay.update(frame: bounds, message: message)
        } else {
            nativeOverlayWindow = ShieldOverlayWindow(frame: bounds, message: message)
            nativeOverlayWindow?.orderFrontRegardless()
        }

        let targetDict: [String: Any] = [
            "window_id": target.windowId,
            "pid": target.pid,
            "app": target.appName,
            "bounds": [
                "x": Double(bounds.origin.x),
                "y": Double(bounds.origin.y),
                "width": Double(bounds.width),
                "height": Double(bounds.height),
            ],
        ]
        nativeShield = ShieldSnapshot(
            scope: "native_window",
            target: targetDict,
            status: "active",
            message: message,
            expiresAt: Date().addingTimeInterval(autoDismissSeconds)
        )

        startNativeRefreshLoop()
        scheduleNativeDismiss()
        return nativeShield?.dictionary() ?? ["ok": false]
    }

    @discardableResult
    func dismissNative(reason: String = "dismissed") -> [String: Any] {
        hideNativeOverlay()
        if let current = nativeShield {
            nativeShield = ShieldSnapshot(
                scope: current.scope,
                target: current.target,
                status: "dismissed",
                message: current.message,
                reason: reason
            )
        } else {
            nativeShield = ShieldSnapshot(
                scope: "native_window",
                target: [:],
                status: "dismissed",
                message: "",
                reason: reason
            )
        }
        return nativeShield?.dictionary() ?? ["ok": true]
    }

    private func activeScope() -> String? {
        if browserShield?.status == "active" { return "browser_tab" }
        if nativeShield?.status == "active" { return "native_window" }
        return nil
    }

    private func scheduleNativeDismiss() {
        nativeDismissTask?.cancel()
        let autoDismissSeconds = self.autoDismissSeconds
        nativeDismissTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(autoDismissSeconds * 1_000_000_000))
            guard let self,
                  self.nativeShield?.status == "active",
                  let expiresAt = self.nativeShield?.expiresAt,
                  expiresAt <= Date() else { return }
            _ = self.dismissNative(reason: "idle_timeout")
        }
    }

    private func startNativeRefreshLoop() {
        guard nativeRefreshTimer == nil else { return }
        nativeRefreshTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshNativeOverlay()
            }
        }
    }

    private func hideNativeOverlay() {
        nativeDismissTask?.cancel()
        nativeDismissTask = nil
        nativeRefreshTimer?.invalidate()
        nativeRefreshTimer = nil
        nativeOverlayWindow?.orderOut(nil)
        nativeOverlayWindow = nil
    }

    private func refreshNativeOverlay() {
        guard nativeShield?.status == "active",
              let target = nativeShield?.target,
              let windowId = target["window_id"] as? Int,
              let bounds = windowBounds(windowId: windowId) else {
            _ = dismissNative(reason: "target_disappeared")
            return
        }

        let message = nativeShield?.message ?? "Agent controlling this window"
        nativeOverlayWindow?.update(frame: bounds, message: message)
        nativeShield?.target["bounds"] = [
            "x": Double(bounds.origin.x),
            "y": Double(bounds.origin.y),
            "width": Double(bounds.width),
            "height": Double(bounds.height),
        ]
    }

    private func resolveNativeTarget(windowId: Int?, pid: Int?, appName: String?) -> (windowId: Int, pid: Int, appName: String)? {
        let windows = visibleWindows()

        if let windowId,
           let match = windows.first(where: { $0.windowId == windowId }) {
            return (match.windowId, match.pid, match.appName)
        }

        let filteredByPid = pid.map { value in
            windows.filter { $0.pid == value }
        } ?? []
        if let largest = largestWindow(in: filteredByPid) {
            return (largest.windowId, largest.pid, largest.appName)
        }

        if let appName, !appName.isEmpty {
            let filteredByName = windows.filter { $0.appName.localizedCaseInsensitiveContains(appName) }
            if let largest = largestWindow(in: filteredByName) {
                return (largest.windowId, largest.pid, largest.appName)
            }
        }

        return nil
    }

    private struct VisibleWindowInfo {
        let windowId: Int
        let pid: Int
        let appName: String
        let bounds: CGRect
    }

    private func visibleWindows() -> [VisibleWindowInfo] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let windowList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return []
        }

        return windowList.compactMap { info in
            let windowId = info[kCGWindowNumber as String] as? Int ?? 0
            let pid = Int(info[kCGWindowOwnerPID as String] as? Int32 ?? 0)
            let appName = info[kCGWindowOwnerName as String] as? String ?? ""
            let layer = info[kCGWindowLayer as String] as? Int ?? 0
            let alpha = info[kCGWindowAlpha as String] as? Double ?? 1
            guard layer == 0,
                  alpha > 0.01,
                  let boundsDict = info[kCGWindowBounds as String] as? [String: Any]
            else { return nil }

            let bounds = CGRect(
                x: boundsDict["X"] as? Double ?? 0,
                y: boundsDict["Y"] as? Double ?? 0,
                width: boundsDict["Width"] as? Double ?? 0,
                height: boundsDict["Height"] as? Double ?? 0
            )
            guard bounds.width >= 80, bounds.height >= 60 else { return nil }
            return VisibleWindowInfo(windowId: windowId, pid: pid, appName: appName, bounds: bounds)
        }
    }

    private func largestWindow(in windows: [VisibleWindowInfo]) -> VisibleWindowInfo? {
        windows.max(by: { ($0.bounds.width * $0.bounds.height) < ($1.bounds.width * $1.bounds.height) })
    }

    private func windowBounds(windowId: Int) -> CGRect? {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let windowList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }
        for info in windowList {
            let currentId = info[kCGWindowNumber as String] as? Int ?? 0
            if currentId == windowId,
               let boundsDict = info[kCGWindowBounds as String] as? [String: Any] {
                return CGRect(
                    x: boundsDict["X"] as? Double ?? 0,
                    y: boundsDict["Y"] as? Double ?? 0,
                    width: boundsDict["Width"] as? Double ?? 0,
                    height: boundsDict["Height"] as? Double ?? 0
                )
            }
        }
        return nil
    }
}
