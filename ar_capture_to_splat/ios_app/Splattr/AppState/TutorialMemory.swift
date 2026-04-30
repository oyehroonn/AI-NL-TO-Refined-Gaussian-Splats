//
//  TutorialMemory.swift
//  Per-mode "tutorial completed" flags persisted in UserDefaults.
//  Drives the "Skip tutorial" button: visible only after the user has
//  completed THIS mode's tutorial at least once.
//

import Foundation

enum TutorialMemory {

    private static let key = "splattr.tutorial_completed_modes_v1"

    static func hasCompleted(_ mode: CaptureMode) -> Bool {
        completedSet().contains(mode.scanModeID)
    }

    static func markCompleted(_ mode: CaptureMode) {
        var s = completedSet()
        s.insert(mode.scanModeID)
        UserDefaults.standard.set(Array(s), forKey: key)
    }

    static func reset() {
        UserDefaults.standard.removeObject(forKey: key)
    }

    private static func completedSet() -> Set<String> {
        let arr = UserDefaults.standard.stringArray(forKey: key) ?? []
        return Set(arr)
    }
}
