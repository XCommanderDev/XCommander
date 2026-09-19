//
//  MenuBarController.swift
//  XCommander
//
//  Created by Wassim Mansouri on 16/09/2026.
//

import AppKit
import XCommanderCore

@MainActor
final class MenuBarController {
    private let item: NSStatusItem
    private let statusEntry = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private(set) var status: XCommanderStatus = .idle
    
    var onOpenAccessibilitySettings: (() -> Void)?
    private let permissionsEntry = NSMenuItem(title: "Open Accessibility Settings", action: nil, keyEquivalent: "")
    
    init() {
        item = NSStatusBar.system.statusItem(
            withLength: NSStatusItem.variableLength
        )
        let menu = NSMenu()
        let quit = NSMenuItem(
            title: "Quit",
            action: #selector(NSApp.terminate(_:)),
            keyEquivalent: "q"
        )

        menu.addItem(quit)
        statusEntry.isEnabled = false
        menu.addItem(statusEntry)
        
        permissionsEntry.action = #selector(openSettings)
        permissionsEntry.target = self
        menu.addItem(permissionsEntry)
        
        item.menu = menu
        item.button?.image = NSImage(
            systemSymbolName: "keyboard",
            accessibilityDescription: "XCommander"
        )
        apply(.idle)
    }
    
    @objc private func openSettings() { onOpenAccessibilitySettings?() }
    
    func apply(_ status: XCommanderStatus) {
        self.status = status
        item.button?.image = NSImage(systemSymbolName: status.menuBarSymbol, accessibilityDescription: status.explanation)
        item.button?.toolTip = status.explanation
        statusEntry.title = status.explanation
    }
}
