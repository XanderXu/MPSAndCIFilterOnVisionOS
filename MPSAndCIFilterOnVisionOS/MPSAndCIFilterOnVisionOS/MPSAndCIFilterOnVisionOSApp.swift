//
//  MPSAndCIFilterOnVisionOSApp.swift
//  MPSAndCIFilterOnVisionOS
//
//  Created by 许M4 on 2025/6/18.
//

import SwiftUI

@main
struct MPSAndCIFilterOnVisionOSApp: App {

    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(model)
        }

        .windowResizability(.contentSize)
        .defaultSize(width: 1, height: 0.6, depth: 0.1, in: .meters)

        ImmersiveSpace(id: Module.imageWithMPS.immersiveId) {
            ImageWithMPSImmersiveView()
                .environment(model)
        }
        .immersionStyle(selection: .constant(.mixed), in: .mixed)
        
        ImmersiveSpace(id: Module.imageWithCIFilter.immersiveId) {
            ImageWithCIFilterImmersiveView()
                .environment(model)
        }
        .immersionStyle(selection: .constant(.mixed), in: .mixed)
        
        ImmersiveSpace(id: Module.videoWithCIFilter.immersiveId) {
            VideoWithCIFilterImmersiveView()
                .environment(model)
        }
        .immersionStyle(selection: .constant(.mixed), in: .mixed)
        
        ImmersiveSpace(id: Module.videoWithMPS.immersiveId) {
            VideoWithMPSImmersiveView()
                .environment(model)
        }
        .immersionStyle(selection: .constant(.mixed), in: .mixed)
        
     }
}
