//
//  DefaultKeymapTests.swift
//  XCommanderCore
//
//  Created by Wassim Mansouri on 17/09/2026.
//

import Testing
@testable import XCommanderCore

@Suite("Shipped keymap")
struct DefaultKeymapTests {
    @Test("status is derived, and permission outranks everything")
    func status() {
        #expect(XCommanderStatus.derive(hasAccessibility: false, secureInputActive: true, xcodeFrontmost: true) == .needsAccessibility)
        #expect(XCommanderStatus.derive(hasAccessibility: true, secureInputActive: true, xcodeFrontmost: true) == .pausedBySecureInput)
        #expect(XCommanderStatus.derive(hasAccessibility: true, secureInputActive: false, xcodeFrontmost: false) == .idle)
        #expect(XCommanderStatus.derive(hasAccessibility: true, secureInputActive: false, xcodeFrontmost: true) == .armed)
    }
}
