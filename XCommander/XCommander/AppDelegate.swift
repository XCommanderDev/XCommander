//
//  AppDelegate.swift
//  XCommander
//
//  Created by Wassim Mansouri on 16/09/2026.
//

import AppKit
import XCommanderCore
import ApplicationServices
import os

@main
class AppDelegate: NSObject, NSApplicationDelegate {

    private var menuBar: MenuBarController!
    private var hasAccessibility = false
    private var accessibilityPollTimer: Timer?
    private var xcodeIsFrontmost = false
    
    private let log = Logger(subsystem: "com.wassimans.XCommander", category: "app")

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        menuBar = MenuBarController()
        menuBar.onOpenAccessibilitySettings = { Self.openAccessibilitySettings() }
        requestAccessibilityThenStart()
    }
    
    private func requestAccessibilityThenStart() {
        hasAccessibility = AXIsProcessTrusted()
        if hasAccessibility { start(); return }
        // Prompts once. The constant kAXTrustedCheckOptionPrompt is imported as a mutable
        // global, which Swift6 won't let me touch, so use its documented value.
        let options = ["AXTrustedCheckOptionPrompt": true]
        _ = AXIsProcessTrustedWithOptions(options as CFDictionary)
        updateStatus()
        
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, AXIsProcessTrusted() else { return }
                self.accessibilityPollTimer?.invalidate()
                self.accessibilityPollTimer = nil
                self.hasAccessibility = true
                self.start()
            }
        }
        
        accessibilityPollTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }
    
    private func start() {
        updateStatus()
    }
    
    private func updateStatus() {
        menuBar.apply(XCommanderStatus.derive(hasAccessibility: hasAccessibility, secureInputActive: false, xcodeFrontmost: xcodeIsFrontmost))
    }
    
    private static func openAccessibilitySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }
}

