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
//    var sourcePixelBufferAttributes: [String: Any]? = [String(kCVPixelBufferPixelFormatTypeKey): [kCVPixelFormatType_32BGRA]]
    var requiredPixelBufferAttributesForRenderContext: [String: Any] = {
        return [
            String(kCVPixelBufferPixelFormatTypeKey):[kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange],
//            String(kCVPixelBufferPixelFormatTypeKey):[kCVPixelFormatType_32BGRA],
            String(kCVPixelBufferMetalCompatibilityKey): true
        ]
    }()
    
    var supportsWideColorSourceFrames = true
    
    var supportsHDRSourceFrames = true
    
    func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {
        print("renderContextChanged")
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
            
            // 处理 YUV 格式的视频帧
            if CVPixelBufferGetPlaneCount(sourceBuffer) == 2 {
                // 对于 YUV 格式，我们需要创建一个 BGRA 纹理来进行处理
                let width = CVPixelBufferGetWidth(sourceBuffer)
                let height = CVPixelBufferGetHeight(sourceBuffer)

                // 创建一个临时的 BGRA 纹理
                let textureDescriptor = MTLTextureDescriptor.texture2DDescriptor(
                    pixelFormat: .bgra8Unorm,
                    width: width,
                    height: height,
                    mipmapped: false
                )
                textureDescriptor.usage = [.shaderRead, .shaderWrite, .renderTarget]

                guard let tempTexture = mtlDevice.makeTexture(descriptor: textureDescriptor) else {
                    print("Failed to create temporary texture")
                    return
                }

                // 使用 CIFilter 将 YUV 转换为 BGRA
                let ciImage = CIImage(cvPixelBuffer: sourceBuffer)
                let ciContext = CIContext(mtlDevice: mtlDevice)

                guard let commandQueue = mtlDevice.makeCommandQueue(),
                      let commandBuffer = commandQueue.makeCommandBuffer() else {
                    print("Failed to create command buffer for YUV conversion")
                    return
                }

                let destination = CIRenderDestination(mtlTexture: tempTexture, commandBuffer: commandBuffer)
                do {
                    try ciContext.startTask(toRender: ciImage, to: destination)
                    commandBuffer.commit()
                    commandBuffer.waitUntilCompleted()

                    // 现在使用转换后的 BGRA 纹理进行 MPS 处理
                    Task { @MainActor in
                        populateMPS(inTexture: tempTexture, lowLevelTexture: Self.llt!, device: mtlDevice)
                    }
                } catch {
                    print("Failed to convert YUV to BGRA: \(error)")
                }
            } else {
                // 处理 BGRA 格式
                let width = CVPixelBufferGetWidth(sourceBuffer)
                let height = CVPixelBufferGetHeight(sourceBuffer)

                var cvTexture: CVMetalTexture? = nil
                let result = CVMetalTextureCacheCreateTextureFromImage(
                    kCFAllocatorDefault,
                    mtlTextureCache!,
                    sourceBuffer,
                    nil,
                    MTLPixelFormat.bgra8Unorm,
                    width,
                    height,
                    0,
                    &cvTexture
                )

                guard result == kCVReturnSuccess,
                      let cvTexture = cvTexture,
                      let texture = CVMetalTextureGetTexture(cvTexture) else {
                    print("Failed to create Metal texture from pixel buffer")
                    return
                }

                Task { @MainActor in
                    populateMPS(inTexture: texture, lowLevelTexture: Self.llt!, device: mtlDevice)
                }
            }
            
            request.finish(withComposedVideoFrame: sourceBuffer)
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

        // Create a MPS filter with dynamic blur radius
        let blurRadius = max(0.1, Self.blurRadius) // 确保模糊半径至少为 0.1
        let blur = MPSImageGaussianBlur(device: device, sigma: blurRadius)

        // 检查输入和输出纹理的兼容性
        guard inTexture.width <= lowLevelTexture.descriptor.width,
              inTexture.height <= lowLevelTexture.descriptor.height else {
            print("Texture size mismatch: input(\(inTexture.width)x\(inTexture.height)) vs output(\(lowLevelTexture.descriptor.width)x\(lowLevelTexture.descriptor.height))")
            return
        }

        // set input output
        let outTexture = lowLevelTexture.replace(using: commandBuffer)
        blur.encode(commandBuffer: commandBuffer, sourceTexture: inTexture, destinationTexture: outTexture)

        // The usual Metal enqueue process.
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
    }
}
