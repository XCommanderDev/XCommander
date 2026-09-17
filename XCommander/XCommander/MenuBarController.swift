//
//  MenuBarController.swift
//  XCommander
//
//  Created by Wassim Mansouri on 16/09/2026.
//

import AppKit

@MainActor
final class MenuBarController {
    private let item: NSStatusItem
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
        item.menu = menu
        item.button?.image = NSImage(
            systemSymbolName: "keyboard",
            accessibilityDescription: "XCommander"
        )

    }
}
