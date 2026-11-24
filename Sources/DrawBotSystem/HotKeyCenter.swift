import Carbon.HIToolbox
import Foundation

/// System-wide hotkeys via Carbon RegisterEventHotKey (needs no permissions).
/// Handlers are invoked on the main thread. Must be used from the main thread.
///
/// Notes:
/// * Modifiers may be empty (e.g. plain Esc, kVK_Escape = 53): RegisterEventHotKey accepts 0.
///   While registered, that key is swallowed system-wide (other apps don't receive it), so
///   register a bare key only for as long as you need it (e.g. while drawing).
/// * Since macOS 15 the system refuses combos whose only modifiers are ⌥ or ⌥⇧; `register`
///   then returns false.
public final class HotKeyCenter {
    public static let shared = HotKeyCenter()

    public struct Modifiers: OptionSet, Sendable {
        public let rawValue: UInt32
        public init(rawValue: UInt32) { self.rawValue = rawValue }
        public static let command = Modifiers(rawValue: UInt32(cmdKey))
        public static let option = Modifiers(rawValue: UInt32(optionKey))
        public static let control = Modifiers(rawValue: UInt32(controlKey))
        public static let shift = Modifiers(rawValue: UInt32(shiftKey))
    }

    /// 'DRBT'
    static let signature: OSType = 0x4452_4254

    private struct Entry {
        let ref: EventHotKeyRef
        let handler: () -> Void
    }

    private var entries: [UInt32: Entry] = [:]
    private var eventHandlerRef: EventHandlerRef?

    private init() {}

    /// Registers (or replaces) hotkey `id`. `keyCode` is a kVK_* virtual key code.
    /// Returns false if the system refused (e.g. another app owns that combo).
    @discardableResult
    public func register(id: UInt32, keyCode: UInt32, modifiers: Modifiers, handler: @escaping () -> Void) -> Bool {
        assert(Thread.isMainThread, "HotKeyCenter must be used from the main thread")
        unregister(id: id)
        guard installHandlerIfNeeded() else { return false }
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: HotKeyCenter.signature, id: id)
        let status = RegisterEventHotKey(keyCode, modifiers.rawValue, hotKeyID,
                                         GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else { return false }
        entries[id] = Entry(ref: ref, handler: handler)
        return true
    }

    public func unregister(id: UInt32) {
        assert(Thread.isMainThread, "HotKeyCenter must be used from the main thread")
        if let entry = entries.removeValue(forKey: id) {
            UnregisterEventHotKey(entry.ref)
        }
    }

    public func unregisterAll() {
        assert(Thread.isMainThread, "HotKeyCenter must be used from the main thread")
        for entry in entries.values { UnregisterEventHotKey(entry.ref) }
        entries.removeAll()
    }

    /// True if hotkey `id` is currently registered.
    public func isRegistered(id: UInt32) -> Bool { entries[id] != nil }

    // MARK: Private

    private func installHandlerIfNeeded() -> Bool {
        if eventHandlerRef != nil { return true }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        var handlerRef: EventHandlerRef?
        // `shared` lives forever, so an unretained pointer is safe.
        let userData = Unmanaged.passUnretained(self).toOpaque()
        let status = InstallEventHandler(GetApplicationEventTarget(), hotKeyEventCallback, 1, &spec,
                                         userData, &handlerRef)
        guard status == noErr, let handlerRef else { return false }
        eventHandlerRef = handlerRef
        return true
    }

    fileprivate func dispatch(id: UInt32) {
        // Look the handler up at fire time (it may have been unregistered in the meantime).
        // Copy the closure out first: handlers commonly unregister themselves.
        if Thread.isMainThread {
            let handler = entries[id]?.handler
            handler?()
        } else {
            DispatchQueue.main.async { [self] in
                let handler = entries[id]?.handler
                handler?()
            }
        }
    }
}

/// C-compatible Carbon callback: no captured context; `userData` is the unretained HotKeyCenter.
private func hotKeyEventCallback(_ nextHandler: EventHandlerCallRef?, _ event: EventRef?,
                                 _ userData: UnsafeMutableRawPointer?) -> OSStatus {
    guard let event, let userData else { return OSStatus(eventNotHandledErr) }
    var hotKeyID = EventHotKeyID()
    let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                   nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
    guard status == noErr, hotKeyID.signature == HotKeyCenter.signature else {
        return OSStatus(eventNotHandledErr)
    }
    let center = Unmanaged<HotKeyCenter>.fromOpaque(userData).takeUnretainedValue()
    center.dispatch(id: hotKeyID.id)
    return noErr
}
