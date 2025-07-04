//
//  ContentView.swift
//  MPSAndCIFilterOnVisionOS
//
//  Created by 许M4 on 2025/6/18.
//

import SwiftUI
import RealityKit

struct ContentView: View {

    @State private var selectedModule: Module = .imageWithCIFilter
    
    @Environment(AppModel.self) private var model
    @Environment(\.openImmersiveSpace) var openImmersiveSpace
    @Environment(\.dismissImmersiveSpace) var dismissImmersiveSpace
    
    var body: some View {
        NavigationSplitView {
            List(Module.allCases) { module in
                Button(action: {
                    selectedModule = module
                }, label: {
                    Text(module.name)
                })
                .listRowBackground(
                    RoundedRectangle(cornerRadius: 8)
                        .background(Color.clear)
                        .foregroundColor((module == selectedModule) ? Color.teal.opacity(0.3) : .clear)
                )
                
            }
            .navigationTitle("MPS and CIFilter Demo")
        } detail: {
            DetailView()
                .navigationTitle(selectedModule.name)
            
        }
        .frame(minWidth: 800, minHeight: 500)
        .onChange(of: selectedModule) { _, newValue in
            Task {
                if model.turnOnImmersiveSpace {
                    model.turnOnImmersiveSpace = false
                }
            }
        }
        .onChange(of: model.turnOnImmersiveSpace) { _, newValue in
            Task {
                if newValue {
                    await openImmersiveSpace(id: selectedModule.immersiveId)
                } else {
                    await dismissImmersiveSpace()
                    model.reset()
                }
            }
        }
    }
}

#Preview(windowStyle: .automatic) {
    ContentView()
        .environment(AppModel())
}
