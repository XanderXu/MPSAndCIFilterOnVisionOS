//
//  DetailView.swift
//  MPSAndCIFilterOnVisionOS
//
//  Created by 许M4 on 2025/6/18.
//

import SwiftUI

struct DetailView: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        @Bindable var model = model
        VStack {
            VStack(alignment: .center, spacing: 10) {
                Toggle("Turn on Immersive Space", isOn: $model.turnOnImmersiveSpace)
                    .toggleStyle(ButtonToggleStyle())
                    .font(.system(size: 16, weight: .bold))
                    .padding(.bottom, 40)
                
            }
            Text("Blur Radius: \(model.blurRadius.formatted())")
            Slider(value: $model.blurRadius, in: 1...20, step: 1) {
                Text("Blur Radius: \(model.blurRadius)")
            }
            .frame(width: 400)
        }
    }
}

#Preview {
    DetailView()
}
