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
                
                // Create a descriptor for the LowLevelTexture.
                let textureDescriptor = createTextureDescriptor(width: 3840, height: 2160)
                // Create the LowLevelTexture and populate it on the GPU.
                let llt = try LowLevelTexture(descriptor: textureDescriptor)
                model.lowLevelTexture = llt
                SampleCustomCompositor.mtlDevice = mtlDevice
                SampleCustomCompositor.llt = llt
                
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
                modelEntity2.position = SIMD3(x: 2, y: 1, z: -2)
                
            } catch {
                print(error)
            }
            
            
        }
        .onChange(of: model.blurRadius) { oldValue, newValue in
            guard model.inTexture != nil && model.lowLevelTexture != nil else {
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
        desc.pixelFormat = .bgra8Unorm
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
    var sourcePixelBufferAttributes: [String: Any]? = [String(kCVPixelBufferPixelFormatTypeKey): [kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange]]
    var requiredPixelBufferAttributesForRenderContext: [String: Any] =
        [String(kCVPixelBufferPixelFormatTypeKey): [kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange]]
    
    var supportsWideColorSourceFrames = true
    
    var supportsHDRSourceFrames = true
    
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
        
        if sourceCount == 1 {
            let sourceID = requiredTrackIDs[0]
            let sourceBuffer = request.sourceFrame(byTrackID: sourceID.value(of: Int32.self)!)!
            let mtlDevice = MTLCreateSystemDefaultDevice()!
            
            var mtlTextureCache: CVMetalTextureCache? = nil
            CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, mtlDevice, nil, &mtlTextureCache)
            
            let width = CVPixelBufferGetWidth(sourceBuffer)
            let height = CVPixelBufferGetHeight(sourceBuffer)
            var cvTexture: CVMetalTexture? = nil
            CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, mtlTextureCache!, sourceBuffer, nil, MTLPixelFormat.bgra8Unorm, width, height, 0, &cvTexture)
            
            let texture = CVMetalTextureGetTexture(cvTexture!)
            Task{ @MainActor in
                populateMPS(inTexture: texture!, lowLevelTexture: Self.llt!, device: mtlDevice)
            }
        }
        
        request.finish(withComposedVideoFrame: outputPixelBuffer)
    }
    
    
    @MainActor func populateMPS(inTexture: MTLTexture, lowLevelTexture: LowLevelTexture, device: MTLDevice) {
        // Set up the Metal command queue and compute command encoder,
        // or abort if that fails.
        guard let commandQueue = device.makeCommandQueue(),
              let commandBuffer = commandQueue.makeCommandBuffer() else {
            return
        }
        
        // Create a MPS filter.
        let blur = MPSImageGaussianBlur(device: device, sigma: 40)
        // set input output
        let outTexture = lowLevelTexture.replace(using: commandBuffer)
        blur.encode(commandBuffer: commandBuffer, sourceTexture: inTexture, destinationTexture: outTexture)
        
        // The usual Metal enqueue process.
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
    }
}
