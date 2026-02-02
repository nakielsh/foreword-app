//
//  MyPRsTab.swift
//  WorkHomepage
//
//  Placeholder — lands in slice 02.
//

import SwiftUI

struct MyPRsTab: View {
    var body: some View {
        VStack(spacing: 8) {
            Text("My PRs")
                .font(.title)
            Text("Coming soon")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("My PRs")
    }
}
