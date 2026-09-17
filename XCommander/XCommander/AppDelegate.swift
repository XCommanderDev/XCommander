//
//  AppDelegate.swift
//  XCommander
//
//  Created by Wassim Mansouri on 16/09/2026.
//

import Cocoa
import XCommanderCore

@main
class AppDelegate: NSObject, NSApplicationDelegate {

    private var menuBar: MenuBarController!

    func applicationDidFinishLaunching(_ aNotification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        menuBar = MenuBarController()
    }
}

