// Scratch UI driver for verification runs: resize the Autotime window, click elements by text, dump texts, print window id.
import AppKit
import ApplicationServices

let args = Array(CommandLine.arguments.dropFirst())
guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: "dev.autotime.Autotime").first else {
    print("Autotime not running"); exit(1)
}
let pid = app.processIdentifier
let axApp = AXUIElementCreateApplication(pid)

func attr(_ e: AXUIElement, _ name: String) -> AnyObject? {
    var v: AnyObject?
    AXUIElementCopyAttributeValue(e, name as CFString, &v)
    return v
}
func str(_ e: AXUIElement, _ name: String) -> String { (attr(e, name) as? String) ?? "" }
func kids(_ e: AXUIElement) -> [AXUIElement] { (attr(e, kAXChildrenAttribute) as? [AXUIElement]) ?? [] }
func point(_ e: AXUIElement) -> CGPoint? {
    guard let v = attr(e, kAXPositionAttribute) else { return nil }
    var p = CGPoint.zero; AXValueGetValue(v as! AXValue, .cgPoint, &p); return p
}
func size(_ e: AXUIElement) -> CGSize? {
    guard let v = attr(e, kAXSizeAttribute) else { return nil }
    var s = CGSize.zero; AXValueGetValue(v as! AXValue, .cgSize, &s); return s
}
func window() -> AXUIElement? {
    let wins = (attr(axApp, kAXWindowsAttribute) as? [AXUIElement]) ?? []
    return wins.max { (size($0)?.width ?? 0) * (size($0)?.height ?? 0) < (size($1)?.width ?? 0) * (size($1)?.height ?? 0) }
}
func walk(_ e: AXUIElement, depth: Int = 0, _ visit: (AXUIElement, Int) -> Void) {
    visit(e, depth)
    guard depth < 60 else { return }
    for k in kids(e) { walk(k, depth: depth + 1, visit) }
}
func click(_ p: CGPoint) {
    let src = CGEventSource(stateID: .hidSystemState)
    for type in [CGEventType.leftMouseDown, .leftMouseUp] {
        CGEvent(mouseEventSource: src, mouseType: type, mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
        usleep(60_000)
    }
}

print("trusted=\(AXIsProcessTrusted())")
app.activate()
usleep(300_000)

switch args.first {
case "size":
    guard let w = window() else { print("no window"); exit(1) }
    var p = CGPoint(x: 20, y: 40)
    var s = CGSize(width: Double(args[1])!, height: Double(args[2])!)
    AXUIElementSetAttributeValue(w, kAXPositionAttribute as CFString, AXValueCreate(.cgPoint, &p)!)
    AXUIElementSetAttributeValue(w, kAXSizeAttribute as CFString, AXValueCreate(.cgSize, &s)!)
    usleep(500_000)
    print("size=\(size(w).map { "\($0)" } ?? "?")")
case "click":
    // click <text> [role]: press or click the first element whose title/value/description equals text.
    guard let w = window() else { print("no window"); exit(1) }
    let target = args[1]
    let role = args.count > 2 ? args[2] : nil
    var found: AXUIElement?
    walk(w) { e, _ in
        guard found == nil else { return }
        let r = str(e, kAXRoleAttribute)
        if let role, r != role { return }
        if [str(e, kAXTitleAttribute), str(e, kAXValueAttribute), str(e, kAXDescriptionAttribute)].contains(target) { found = e }
    }
    guard let e = found, let p = point(e), let s = size(e) else { print("not found: \(target)"); exit(1) }
    if str(e, kAXRoleAttribute) == "AXRadioButton" || str(e, kAXRoleAttribute) == "AXButton" {
        AXUIElementPerformAction(e, kAXPressAction as CFString)
    } else {
        click(CGPoint(x: p.x + s.width / 2, y: p.y + s.height / 2))
    }
    print("clicked \(target) [\(str(e, kAXRoleAttribute))] at \(p)")
case "texts":
    guard let w = window() else { print("no window"); exit(1) }
    walk(w) { e, d in
        let r = str(e, kAXRoleAttribute)
        let v = [str(e, kAXTitleAttribute), str(e, kAXValueAttribute), str(e, kAXDescriptionAttribute)].filter { !$0.isEmpty }
        if !v.isEmpty, ["AXStaticText", "AXButton", "AXRadioButton", "AXCell", "AXRow"].contains(r) {
            print(String(repeating: " ", count: min(d, 30)) + r + " " + v.joined(separator: " | "))
        }
    }
case "winid":
    let info = (CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]]) ?? []
    let mine = info.filter { ($0[kCGWindowOwnerPID as String] as? Int32) == pid && ($0[kCGWindowLayer as String] as? Int) == 0 }
    let best = mine.max {
        let a = $0[kCGWindowBounds as String] as? [String: Double] ?? [:], b = $1[kCGWindowBounds as String] as? [String: Double] ?? [:]
        return (a["Width"] ?? 0) * (a["Height"] ?? 0) < (b["Width"] ?? 0) * (b["Height"] ?? 0)
    }
    print(best?[kCGWindowNumber as String] as? Int ?? 0)
default:
    print("usage: size W H | click TEXT [ROLE] | texts | winid")
}
