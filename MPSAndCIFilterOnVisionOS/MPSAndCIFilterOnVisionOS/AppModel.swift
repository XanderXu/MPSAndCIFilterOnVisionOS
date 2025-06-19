//
//  AppModel.swift
//  MPSAndCIFilterOnVisionOS
//
//  Created by 许M4 on 2025/6/18.
//

import SwiftUI
import RealityKit
/// Maintains app-wide state
@MainActor
@Observable
class AppModel {
    var rootEntity: Entity?
    var turnOnImmersiveSpace = false
    var blurRadius: Float = 8
    var inTexture: MTLTexture?
    var lowLevelTexture: LowLevelTexture?
    
    func clear() {
        rootEntity?.children.removeAll()
        inTexture = nil
        lowLevelTexture = nil
    }
    
    /// Resets game state information.
    func reset() {
        debugPrint(#function)
        
        blurRadius = 8
        clear()
    }
}


/// A description of the modules that the app can present.
enum Module: String, Identifiable, CaseIterable, Equatable {
    case imageWithMPS
    case imageWithCIFilter
    case videoWithCIFilter
    
    var id: Self { self }
    var name: LocalizedStringKey {
        LocalizedStringKey(rawValue)
    }

    var immersiveId: String {
        self.rawValue + "ID"
    }

}
