import Testing
@testable import AutographeCore

/// These tests exist because of a bug that reached the screen: `⌥SPC b b` ran Xcode's
/// **Analyze** instead of **Build**. Accessibility reports `Product > Build` as the
/// character `"B"` with an empty modifier mask, and taking that capital literally meant
/// asking for Shift-b on a layout where the capital needs Shift — which is `⇧⌘B`, Analyze.
@Suite("Menu shortcut decoding")
struct MenuShortcutTests {

    @Test("a plain Command letter loses the display capital and gains no Shift")
    func plainCommandLetter() {
        let key = MenuShortcut.decode(character: "B", mask: 0)
        #expect(key == KeyEvent("b", [.command]))
        #expect(key.display == "⌘b")
    }

    @Test("Shift comes from the mask, never from the character's case")
    func shiftFromMask() {
        #expect(MenuShortcut.decode(character: "B", mask: 1) == KeyEvent("b", [.command, .shift]))
    }

    /// The pair that caused the bug: identical characters, different commands.
    @Test("Build and Analyze differ only by the mask")
    func buildVersusAnalyze() {
        let build = MenuShortcut.decode(character: "B", mask: 0)
        let analyze = MenuShortcut.decode(character: "B", mask: 1)
        #expect(build != analyze)
        #expect(build.modifiers == [.command])
        #expect(analyze.modifiers == [.command, .shift])
    }

    /// Punctuation is left alone: on AZERTY `Product > Stop` is reported as `;`, and
    /// `Jump to Previous Issue` as `%`, and both are the character actually wanted.
    @Test("punctuation is passed through untouched")
    func punctuationUnchanged() {
        #expect(MenuShortcut.decode(character: ";", mask: 0) == KeyEvent(";", [.command]))
        #expect(MenuShortcut.decode(character: "%", mask: 0) == KeyEvent("%", [.command]))
    }

    @Test("bit 8 means the shortcut has no Command at all")
    func noCommandBit() {
        let key = MenuShortcut.decode(character: "T", mask: 8 | 4)
        #expect(key == KeyEvent("t", [.control]))
        #expect(key.display == "⌃t")
    }

    @Test("every modifier at once")
    func allModifiers() {
        let key = MenuShortcut.decode(character: "K", mask: 1 | 2 | 4)
        #expect(key == KeyEvent("k", [.command, .shift, .option, .control]))
        #expect(key.display == "⌃⌥⇧⌘k")
    }

    /// Real rows from a real Xcode 26.6 menu bar on a French layout.
    @Test("decodes the shipped keymap's own commands", arguments: [
        (Character("B"), 0,     KeyEvent("b", [.command])),                      // Build
        (Character("B"), 1,     KeyEvent("b", [.command, .shift])),              // Analyze
        (Character("K"), 1,     KeyEvent("k", [.command, .shift])),              // Clean Build Folder
        (Character("D"), 1 | 4, KeyEvent("d", [.command, .shift, .control])),    // Build Documentation
        (Character(";"), 0,     KeyEvent(";", [.command])),                      // Stop, on AZERTY
        (Character("U"), 0,     KeyEvent("u", [.command])),                      // Test
        (Character("R"), 0,     KeyEvent("r", [.command])),                      // Run
    ])
    func realMenuRows(character: Character, mask: Int, expected: KeyEvent) {
        #expect(MenuShortcut.decode(character: character, mask: mask) == expected)
    }
}
