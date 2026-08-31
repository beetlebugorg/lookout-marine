//  ViewState.swift
//  Whether there is a camera pose to reopen on.
//
//  The pose itself is the ENGINE's: lookout_set_store hands it the shell's
//  store, and it restores the pose at attach, writes it down as the mariner
//  moves, and writes it at close. What is left here is the one question the
//  shell still has to ask, because the answer decides whether it asks the core
//  for an opening view instead.
//
//  The opening view when nothing is saved is NOT decided here either: that
//  policy lives in the core, behind lookout_default_view, so every host agrees.

import Foundation

enum ViewState {
    /// True when a pose has been saved. Half a pose is no pose, which is the
    /// same rule the engine reads it by.
    static func hasSaved() -> Bool {
        let s = Store.shared
        let g = Store.Group.view
        return s.has(g, "lon") && s.has(g, "lat") && s.has(g, "zoom")
    }
}
