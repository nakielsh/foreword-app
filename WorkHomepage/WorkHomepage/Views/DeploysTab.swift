//
//  DeploysTab.swift
//  WorkHomepage
//
//  Placeholder — lands in slice 04.
//

import SwiftUI

struct DeploysTab: View {
    var body: some View {
        VStack(spacing: 8) {
            Text("Deploys")
                .font(.title)
            Text("Coming soon")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("Deploys")
    }
}
