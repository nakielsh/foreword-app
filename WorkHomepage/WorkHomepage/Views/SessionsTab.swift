//
//  SessionsTab.swift
//  WorkHomepage
//
//  Placeholder — lands in slice 03.
//

import SwiftUI

struct SessionsTab: View {
    var body: some View {
        VStack(spacing: 8) {
            Text("Sessions")
                .font(.title)
            Text("Coming soon")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("Sessions")
    }
}
