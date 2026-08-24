//
//  ousageApp.swift
//  ousage
//
//  Created by Oli Fitzgerald on 23/8/26.
//

import SwiftUI

@main
struct ousageApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}
