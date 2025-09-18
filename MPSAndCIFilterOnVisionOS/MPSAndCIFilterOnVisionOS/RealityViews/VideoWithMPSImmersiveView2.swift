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
    @State private var videoProcessingManager = VideoProcessingManager()
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

                // 创建 LowLevelTexture 用于 MPS 处理
                let textureDescriptor = createTextureDescriptor(
                    width: Int(naturalSize.width),
                    height: Int(naturalSize.height)
                )
                let llt = try LowLevelTexture(descriptor: textureDescriptor)
                model.lowLevelTexture = llt
                
                // Setup texture update callback
                videoProcessingManager.onTextureUpdated = {
                    textureUpdateTrigger += 1
                }
                
                // 使用 VideoProcessingManager 设置视频播放（已封装所有渲染器逻辑）
                let videoMaterial = try videoProcessingManager.setupVideoPlayback(
                    asset: asset,
                    videoTrack: videoTrack!,
                    audioTrack: audioTrack,
                    lowLevelTexture: llt,
                    device: mtlDevice,
                    blurRadius: model.blurRadius
                )

                // 创建显示平面：使用 VideoMaterial 显示视频
                let modelEntity = ModelEntity(mesh: .generatePlane(width: 1, height: 1), materials: [videoMaterial])
                entity.addChild(modelEntity)
                modelEntity.position = SIMD3(x: 0, y: 1, z: -2)
                              
                // 创建显示平面：使用 TextureResource 显示 MPS 处理后的结果
                let resource = try await TextureResource(from: llt)
                let material = UnlitMaterial(texture: resource)
                let modelEntity2 = ModelEntity(mesh: .generatePlane(width: 1, height: 1), materials: [material])
                entity.addChild(modelEntity2)
                modelEntity2.position = SIMD3(x: 1.2, y: 1, z: -2)
               
            } catch {
                print(error)
            }
        } update: { content in
            print("update")
        }
        .onChange(of: model.blurRadius) { oldValue, newValue in
            guard model.lowLevelTexture != nil else {
                return
            }
            // 模糊半径变化时的处理逻辑可以在这里添加
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

