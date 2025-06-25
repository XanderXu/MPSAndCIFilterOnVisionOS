//
//  VideoWithMPSImmersiveView.swift
//  MPSAndCIFilterOnVisionOS
//
//  Created by 许M4 on 2025/6/23.
//

import SwiftUI
import SwiftUI
import RealityKit
import MetalKit
import AVFoundation

struct VideoWithMPSImmersiveView: View {
    @Environment(AppModel.self) private var model
    let asset = AVURLAsset(url: Bundle.main.url(forResource: "HDRMovie", withExtension: "mov")!)
    let mtlDevice = MTLCreateSystemDefaultDevice()!
    var body: some View {
        RealityView { content in
            
            let entity = Entity()
            entity.name = "GameRoot"
            model.rootEntity = entity
            content.add(entity)
            
            
            do {
                // 获取视频的实际尺寸
                let videoTrack = try await asset.loadTracks(withMediaType: .video).first
                let naturalSize = try await videoTrack?.load(.naturalSize) ?? CGSize(width: 1920, height: 1080)

                // Create a descriptor for the LowLevelTexture with actual video dimensions
                let textureDescriptor = createTextureDescriptor(
                    width: Int(naturalSize.width),
                    height: Int(naturalSize.height)
                )
                // Create the LowLevelTexture and populate it on the GPU.
                let llt = try LowLevelTexture(descriptor: textureDescriptor)
                model.lowLevelTexture = llt
                SampleCustomCompositor.mtlDevice = mtlDevice
                SampleCustomCompositor.llt = llt
                SampleCustomCompositor.blurRadius = model.blurRadius
                
                let composition = try await AVMutableVideoComposition.videoComposition(withPropertiesOf: asset)
                composition.customVideoCompositorClass = SampleCustomCompositor.self
                
                let playerItem = AVPlayerItem(asset: asset)
                playerItem.videoComposition = composition
                
                let player = AVPlayer(playerItem: playerItem)
                let videoMaterial = VideoMaterial(avPlayer: player)
                let modelEntity = ModelEntity(mesh: .generatePlane(width: 1, height: 1), materials: [videoMaterial])
                entity.addChild(modelEntity)
                modelEntity.position = SIMD3(x: 0, y: 1, z: -2)
                player.play()
                model.player = player
                
                
                // Create a TextureResource from the LowLevelTexture.
                let resource = try await TextureResource(from: llt)
                // Create a material that uses the texture.
                var material = UnlitMaterial(texture: resource)
//                material.opacityThreshold = 0.5

                // Return an entity of a plane which uses the generated texture.
                let modelEntity2 = ModelEntity(mesh: .generatePlane(width: 1, height: 1), materials: [material])
                entity.addChild(modelEntity2)
                modelEntity2.position = SIMD3(x: 1.2, y: 1, z: -2)
                
            } catch {
                print(error)
            }
            
            
        }
        .onChange(of: model.blurRadius) { oldValue, newValue in
            guard model.lowLevelTexture != nil else {
                return
            }
            SampleCustomCompositor.blurRadius = model.blurRadius
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
        desc.pixelFormat = .bgra8Unorm // 确保与 MPS 输入格式匹配
        desc.textureUsage = [.shaderRead, .shaderWrite]
        desc.swizzle = .init(red: .red, green: .green, blue: .blue, alpha: .alpha)

        return desc
    }
}
#Preview {
    VideoWithMPSImmersiveView()
}


import Foundation
import AVKit
import AVFoundation
import MetalPerformanceShaders

enum CustomCompositorError: Int, Error, LocalizedError {
    case ciFilterFailedToProduceOutputImage = -1_000_001
    case notSupportingMoreThanOneSources
    
    var errorDescription: String? {
        switch self {
        case .ciFilterFailedToProduceOutputImage:
            return "CIFilter does not produce an output image."
        case .notSupportingMoreThanOneSources:
            return "This custom compositor does not support blending of more than one source."
        }
    }
}

class SampleCustomCompositor: NSObject, AVVideoCompositing {
    static var blurRadius: Float = 0
    static var llt: LowLevelTexture?
    static var mtlDevice: MTLDevice?

    var sourcePixelBufferAttributes: [String: any Sendable]? = [
        String(kCVPixelBufferPixelFormatTypeKey): [kCVPixelFormatType_32BGRA],
        String(kCVPixelBufferMetalCompatibilityKey): true // 关键！
    ]
    var requiredPixelBufferAttributesForRenderContext: [String: any Sendable] = [
        String(kCVPixelBufferPixelFormatTypeKey):[kCVPixelFormatType_32BGRA],
        String(kCVPixelBufferMetalCompatibilityKey): true
    ]
    
    
    var supportsWideColorSourceFrames = false
    var supportsHDRSourceFrames = false
    
    func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {
        return
    }
    
    func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        
        guard let outputPixelBuffer = request.renderContext.newPixelBuffer() else {
            print("No valid pixel buffer found. Returning.")
            request.finish(with: CustomCompositorError.ciFilterFailedToProduceOutputImage)
            return
        }
        
        guard let requiredTrackIDs = request.videoCompositionInstruction.requiredSourceTrackIDs, !requiredTrackIDs.isEmpty else {
            print("No valid track IDs found in composition instruction.")
            return
        }
        
        let sourceCount = requiredTrackIDs.count
        
        if sourceCount > 1 {
            request.finish(with: CustomCompositorError.notSupportingMoreThanOneSources)
            return
        }
        
        if sourceCount == 1, SampleCustomCompositor.llt != nil, SampleCustomCompositor.mtlDevice != nil {
            let sourceID = requiredTrackIDs[0]
            let sourceBuffer = request.sourceFrame(byTrackID: sourceID.value(of: Int32.self)!)!
            
            Task {@MainActor in
                populateMPS(sourceBuffer: sourceBuffer, lowLevelTexture: SampleCustomCompositor.llt!, device: SampleCustomCompositor.mtlDevice!)
            }
            
            request.finish(withComposedVideoFrame: sourceBuffer)
        }
        
        request.finish(withComposedVideoFrame: outputPixelBuffer)
    }
    
    
    @MainActor func populateMPS(sourceBuffer: CVPixelBuffer, lowLevelTexture: LowLevelTexture, device: MTLDevice) {
        // Set up the Metal command queue and compute command encoder,
        // or abort if that fails.
        guard let commandQueue = device.makeCommandQueue(),
              let commandBuffer = commandQueue.makeCommandBuffer() else {
            return
        }
        
        // 现在 sourceBuffer 应该已经是 BGRA 格式，直接创建 Metal 纹理
        var mtlTextureCache: CVMetalTextureCache? = nil
        CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &mtlTextureCache)

        let width = CVPixelBufferGetWidth(sourceBuffer)
        let height = CVPixelBufferGetHeight(sourceBuffer)

        var cvTexture: CVMetalTexture?
        let result = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault,
            mtlTextureCache!,
            sourceBuffer,
            nil,
            .bgra8Unorm,
            width,
            height,
            0,
            &cvTexture
        )

        guard result == kCVReturnSuccess,
              let cvTexture = cvTexture,
              let bgraTexture = CVMetalTextureGetTexture(cvTexture) else {
            print("Failed to create Metal texture from BGRA pixel buffer")
            print("CVPixelBuffer format: \(CVPixelBufferGetPixelFormatType(sourceBuffer))")
            print("Expected BGRA format: \(kCVPixelFormatType_32BGRA)")
            return
        }
        // Create a MPS filter with dynamic blur radius
        let blurRadius = Self.blurRadius
        let blur = MPSImageGaussianBlur(device: device, sigma: blurRadius)

        // 检查输入和输出纹理的兼容性
        guard bgraTexture.width <= lowLevelTexture.descriptor.width,
              bgraTexture.height <= lowLevelTexture.descriptor.height else {
            print("Texture size mismatch: input(\(bgraTexture.width)x\(bgraTexture.height)) vs output(\(lowLevelTexture.descriptor.width)x\(lowLevelTexture.descriptor.height))")
            return
        }

        // set input output
        let outTexture = lowLevelTexture.replace(using: commandBuffer)
        blur.encode(commandBuffer: commandBuffer, sourceTexture: bgraTexture, destinationTexture: outTexture)

        // The usual Metal enqueue process.
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
    }
}
