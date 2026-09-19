//
//  XCommanderStatus.swift
//  XCommanderCore
//
//  Created by Wassim Mansouri on 17/09/2026.
//

import Foundation

public enum XCommanderStatus: Hashable, Sendable {
    case needsAccessibility
    case pausedBySecureInput
    /// Running but Xcode is not frontmost
    case idle
    /// Xcode is frontmost
    case armed
    
    public static func derive(hasAccessibility: Bool, secureInputActive: Bool, xcodeFrontmost: Bool) -> XCommanderStatus {
        if !hasAccessibility { return .needsAccessibility }
        if secureInputActive { return .pausedBySecureInput }
        return xcodeFrontmost ? .armed : idle
    }
    
    public var menuBarSymbol: String {
        switch self {
        case .needsAccessibility: "exclamationmark.triangle"
        case .pausedBySecureInput: "lock.fill"
        case .idle: "keyboard"
        case .armed: "keyboard.fill"
        }
    }
    
    public var explanation: String {
        switch self {
        case .needsAccessibility: "Accessibility permission is needed to see the leader key"
        case .pausedBySecureInput: "Paused - another app has secure input enabled."
        case .idle: "Waiting for Xcode."
        case .armed: "Ready."
        }
    }
}
