import Carbon
import CoreGraphics
import CompanionCore

/// Translates between characters and virtual keycodes using the layout that is actually
/// installed, rather than assuming ANSI.
///
/// This is not a nicety. Xcode reports its shortcuts as characters in the current layout:
/// on French AZERTY `Product > Stop` comes back as `;`, and the navigators come back as
/// `'`, `(`, `§` instead of `4`, `5`, `6`. A hardcoded table would fire the wrong command,
/// or nothing at all. Virtual keycodes are physical positions, so the map has to be built
/// by asking the layout what each position produces.
///
/// `@MainActor` because the map is cached, and every caller reaches it from the main run
/// loop: the event tap's source is attached there, so the tap callback is main-thread too.
/// Saying so is what lets the cache be a plain dictionary under Swift 6.
@MainActor
enum KeyboardLayout {

    struct Resolution {
        var keyCode: CGKeyCode
        /// True when the character is only reachable with Shift held. `⌘%` on AZERTY is
        /// really Command-Shift on the `ù` key, and posting it without Shift does nothing.
        var needsShift: Bool
    }

    private static var cache: [Character: Resolution] = [:]
    private static var cachedLayoutName: String?

    /// Rebuild the map if the user has switched layouts since we last looked.
    static func refreshIfNeeded() {
        let name = currentLayoutName()
        guard name != cachedLayoutName else { return }
        cachedLayoutName = name
        cache = buildMap()
    }

    static func resolve(_ character: Character) -> Resolution? {
        refreshIfNeeded()
        if let hit = cache[character] { return hit }
        // AX reports shortcut characters upper-cased, so `⌘B` arrives as "B". Fall back to
        // the lower-case form before giving up.
        if let lower = character.lowercased().first, let hit = cache[lower] { return hit }
        return nil
    }

    static func currentLayoutName() -> String {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let ptr = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else {
            return "unknown"
        }
        return Unmanaged<CFString>.fromOpaque(ptr).takeUnretainedValue() as String
    }

    private static func buildMap() -> [Character: Resolution] {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let dataPtr = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else {
            return [:]
        }
        let data = Unmanaged<CFData>.fromOpaque(dataPtr).takeUnretainedValue() as Data

        var map: [Character: Resolution] = [:]
        // Unshifted first so it wins: if a character is reachable both ways, the simpler
        // press is the right one to post.
        for shift in [false, true] {
            for code in CGKeyCode(0)...CGKeyCode(127) {
                guard let c = character(forKeyCode: code, shift: shift, layoutData: data),
                      !c.isWhitespace, map[c] == nil else { continue }
                map[c] = Resolution(keyCode: code, needsShift: shift)
            }
        }
        return map
    }

    private static func character(forKeyCode code: CGKeyCode, shift: Bool,
                                  layoutData: Data) -> Character? {
        var deadKeyState: UInt32 = 0
        var length = 0
        var chars = [UniChar](repeating: 0, count: 4)
        // UCKeyTranslate wants the modifier byte from an old Carbon event record, which is
        // the key modifier field shifted right by 8.
        let modifierKeyState: UInt32 = shift ? UInt32(shiftKey >> 8) : 0

        let status = layoutData.withUnsafeBytes { raw -> OSStatus in
            guard let base = raw.baseAddress else { return -1 }
            let layout = base.assumingMemoryBound(to: UCKeyboardLayout.self)
            return UCKeyTranslate(layout,
                                  UInt16(code),
                                  UInt16(kUCKeyActionDown),
                                  modifierKeyState,
                                  UInt32(LMGetKbdType()),
                                  OptionBits(kUCKeyTranslateNoDeadKeysBit),
                                  &deadKeyState,
                                  chars.count,
                                  &length,
                                  &chars)
        }
        guard status == noErr, length > 0 else { return nil }
        let s = String(utf16CodeUnits: chars, count: length)
        return s.count == 1 ? s.first : nil
    }

    /// Virtual keycodes for the keys that have no character, and so no layout dependence.
    static func keyCode(for special: SpecialKey) -> CGKeyCode {
        switch special {
        case .escape:   0x35
        case .space:    0x31
        case .tab:      0x30
        case .return:   0x24
        case .delete:   0x33
        case .left:     0x7B
        case .right:    0x7C
        case .down:     0x7D
        case .up:       0x7E
        case .home:     0x73
        case .end:      0x77
        case .pageUp:   0x74
        case .pageDown: 0x79
        }
    }

    static func special(forKeyCode code: CGKeyCode) -> SpecialKey? {
        SpecialKey.allCases.first { keyCode(for: $0) == code }
    }

    /// The character a keycode produces right now, used to turn a tap event into a `KeyEvent`.
    static func character(forKeyCode code: CGKeyCode) -> Character? {
        refreshIfNeeded()
        return cache.first { $0.value.keyCode == code && !$0.value.needsShift }?.key
    }
}
