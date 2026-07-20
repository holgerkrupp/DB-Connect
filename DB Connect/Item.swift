//
//  Item.swift
//  DB Connect
//
//  Created by Holger Krupp on 20.07.26.
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
