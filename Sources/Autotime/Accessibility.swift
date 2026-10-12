import AppKit
import ApplicationServices

struct AXElement {
    let ref: AXUIElement

    static func application(_ pid: pid_t) -> AXElement {
        let el = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(el, 0.35)
        return AXElement(ref: el)
    }

    func value(_ attribute: String) -> AnyObject? {
        var v: AnyObject?
        guard AXUIElementCopyAttributeValue(ref, attribute as CFString, &v) == .success else { return nil }
        return v
    }

    func string(_ attribute: String) -> String? {
        value(attribute) as? String
    }

    func element(_ attribute: String) -> AXElement? {
        guard let v = value(attribute), CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        return AXElement(ref: v as! AXUIElement)
    }

    func url(_ attribute: String) -> URL? {
        let v = value(attribute)
        if let u = v as? URL { return u }
        if let s = v as? String { return URL(string: s) }
        return nil
    }

    var role: String? { string(kAXRoleAttribute) }
    var title: String? { string(kAXTitleAttribute) }
    var document: String? { string(kAXDocumentAttribute) }
    var identifier: String? { string(kAXIdentifierAttribute) }
    var children: [AXElement] {
        (value(kAXChildrenAttribute) as? [AXUIElement])?.map(AXElement.init) ?? []
    }
    var parent: AXElement? { element(kAXParentAttribute) }

    func child(identifier: String) -> AXElement? {
        children.first { $0.identifier == identifier }
    }

    func prefix(_ length: Int) -> String? {
        guard let count = value(kAXNumberOfCharactersAttribute) as? Int else { return string(kAXValueAttribute) }
        var range = CFRange(location: 0, length: min(length, count))
        guard let param = AXValueCreate(.cfRange, &range) else { return nil }
        var v: AnyObject?
        guard AXUIElementCopyParameterizedAttributeValue(ref, kAXStringForRangeParameterizedAttribute as CFString, param, &v) == .success else { return nil }
        return v as? String
    }

    func set(_ attribute: String, _ value: CFTypeRef) {
        AXUIElementSetAttributeValue(ref, attribute as CFString, value)
    }

    func findFirst(maxNodes: Int = 600, maxDepth: Int = 14, where match: (AXElement) -> Bool) -> AXElement? {
        var queue: [(AXElement, Int)] = [(self, 0)]
        var index = 0
        while index < queue.count && index < maxNodes {
            let (el, depth) = queue[index]
            index += 1
            if match(el) { return el }
            if depth < maxDepth {
                queue.append(contentsOf: el.children.map { ($0, depth + 1) })
            }
        }
        return nil
    }

    static func == (a: AXElement, b: AXElement) -> Bool { CFEqual(a.ref, b.ref) }
}

enum AccessibilityPermission {
    static var isTrusted: Bool { AXIsProcessTrusted() }

    static func prompt() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    static func openSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
}
