//
//  Item.swift
//  WorkHomepage
//
//  Created by Hubert Nakielski Ala on 09/05/2026.
//

import Foundation
import SwiftData

@Model
final class Item {
    var timestamp: Date
    
    init(timestamp: Date) {
        self.timestamp = timestamp
    }
}
