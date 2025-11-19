//
//  VideoWithMPSImmersiveView.swift
//  MPSAndCIFilterOnVisionOS
//
//  Created by 许M4 on 2025/6/23.
//

import SwiftUI
import RealityKit
import MetalKit
@preconcurrency import AVFoundation
import MetalPerformanceShaders

struct VideoWithMPSImmersiveView2: View {
    @Environment(AppModel.self) private var model
    private let videoProcessingManager = VideoProcessingManager()
    @State private var textureUpdateTrigger = 0
    
    let asset = AVURLAsset(url: Bundle.main.url(forResource: "HDRMovie", withExtension: "mov")!)
    let mtlDevice = MTLCreateSystemDefaultDevice()!
    
    var body: some View {
        RealityView { content in
            
            let entity = Entity()
            entity.name = "GameRoot"
            model.rootEntity = entity
            content.add(entity)
            
            do {
                // Get the actual video dimensions
                let videoTrack = try await asset.loadTracks(withMediaType: .video).first
                let audioTrack = try await asset.loadTracks(withMediaType: .audio).first
                let naturalSize = try await videoTrack?.load(.naturalSize) ?? CGSize(width: 1920, height: 1080)

                // Create LowLevelTexture for MPS
                let textureDescriptor = createTextureDescriptor(
                    width: Int(naturalSize.width),
                    height: Int(naturalSize.height)
                )
                let llt = try LowLevelTexture(descriptor: textureDescriptor)
                
                
                // VideoProcessingManager setup
                try videoProcessingManager.setupVideoPlayback(
                    asset: asset,
                    videoTrack: videoTrack!,
                    audioTrack: audioTrack,
                    lowLevelTexture: llt,
                    device: mtlDevice,
                    blurRadius: model.blurRadius
                )
                
                              
                // Use TextureResource to display MPS output
                let resource = try await TextureResource(from: llt)
                let material = UnlitMaterial(texture: resource)
                let modelEntity2 = ModelEntity(mesh: .generatePlane(width: 1, height: 1), materials: [material])
                entity.addChild(modelEntity2)
                modelEntity2.position = SIMD3(x: 0, y: 1, z: -2)
                
                let videoMaterial = VideoMaterial(videoRenderer: videoProcessingManager.videoRenderer)
                let modelEntity = ModelEntity(mesh: .generatePlane(width: 1, height: 1), materials: [videoMaterial])
                entity.addChild(modelEntity)
                modelEntity.position = SIMD3(x: 1.2, y: 1, z: -2)
               
                // Setup texture update callback
                videoProcessingManager.onTextureUpdated = {
                    textureUpdateTrigger += 1                    
                }
            } catch {
                print(error)
            }
        } update: { content in
            print("update")
        }
        .onChange(of: model.blurRadius) { oldValue, newValue in
            videoProcessingManager.blurRadius = model.blurRadius
        }
        .onDisappear {
            videoProcessingManager.stopPlayback()
        }
    }
    
    func createTextureDescriptor(width: Int, height: Int) -> LowLevelTexture.Descriptor {
        var desc = LowLevelTexture.Descriptor()

        desc.textureType = .type2D
        desc.arrayLength = 1

        desc.width = width
        desc.height = height
        desc.depth = 1

        desc.mipmapLevelCount = 1
        desc.pixelFormat = .bgra8Unorm // Ensure compatibility with MPS input format
        desc.textureUsage = [.shaderRead, .shaderWrite]
        desc.swizzle = .init(red: .red, green: .green, blue: .blue, alpha: .alpha)

        return desc
    }
}

#Preview {
    VideoWithMPSImmersiveView2()
}

