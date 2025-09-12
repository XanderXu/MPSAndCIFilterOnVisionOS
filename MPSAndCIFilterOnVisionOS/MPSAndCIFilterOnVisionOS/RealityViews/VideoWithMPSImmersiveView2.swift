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
@preconcurrency import AVFoundation
import MetalPerformanceShaders

struct VideoWithMPSImmersiveView2: View {
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
                // Get the actual video dimensions
                let videoTrack = try await asset.loadTracks(withMediaType: .video).first
                let audioTrack = try await asset.loadTracks(withMediaType: .audio).first
                let naturalSize = try await videoTrack?.load(.naturalSize) ?? CGSize(width: 1920, height: 1080)

                // Create a descriptor for the LowLevelTexture with actual video dimensions
                let textureDescriptor = createTextureDescriptor(
                    width: Int(naturalSize.width),
                    height: Int(naturalSize.height)
                )
                // Create the LowLevelTexture and populate it on the GPU.
                let llt = try LowLevelTexture(descriptor: textureDescriptor)
                model.lowLevelTexture = llt
                
                // Create an `AVSampleBufferVideoRenderer` instance to control playback of a movie.
                let videoRenderer = AVSampleBufferVideoRenderer()
                
                // Create an `AVSampleBufferAudioRenderer` instance to control audio of the playback.
                let audioRenderer = AVSampleBufferAudioRenderer()
                
                // Create a `AVSampleBufferRenderSynchronizer` instance to synchronize video and audio.
                let synchronizer = AVSampleBufferRenderSynchronizer()
                
                // Add both videoRenderer and audioRenderer to the synchronizer.
                synchronizer.addRenderer(videoRenderer)
                synchronizer.addRenderer(audioRenderer)
                
                // Create an entity for display.
                let videoMaterial = VideoMaterial(videoRenderer: videoRenderer)
                let sourceAssetReader = try AVAssetReader(asset: asset)
                let sourceAssetVideoTrack = videoTrack
                
                let sourceAssetReaderVideoTrackOutput = AVAssetReaderTrackOutput(track: sourceAssetVideoTrack!, outputSettings: [
                    kCVPixelBufferPixelFormatTypeKey as String: [kCVPixelFormatType_32BGRA],
//                    kCVPixelBufferWidthKey as String: Int(naturalSize.width),
//                    kCVPixelBufferHeightKey as String: Int(naturalSize.height),
                    kCVPixelBufferMetalCompatibilityKey as String: true
                ])
                sourceAssetReader.add(sourceAssetReaderVideoTrackOutput)

                sourceAssetReader.startReading()
                
                // Wait for the video renderer to be ready
                videoRenderer.requestMediaDataWhenReady(on: DispatchQueue.main) {
                    while videoRenderer.isReadyForMoreMediaData {
                        if sourceAssetReader.status == .reading {
                            if let sampleBuffer = sourceAssetReaderVideoTrackOutput.copyNextSampleBuffer() {
                                videoRenderer.enqueue(sampleBuffer)
                                
                                // 从 CMSampleBuffer 中获取 CVPixelBuffer，并添加调试信息
                                if let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) {
                                    print("成功获取到 CVPixelBuffer，尺寸: \(CVPixelBufferGetWidth(pixelBuffer))x\(CVPixelBufferGetHeight(pixelBuffer))")
                                    populateMPS(sourceBuffer: pixelBuffer, lowLevelTexture: llt, device: mtlDevice)
                                } else {
                                    print("警告: 无法从 CMSampleBuffer 获取 CVPixelBuffer")
                                    if let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer) {
                                        print("SampleBuffer 媒体类型: \(formatDescription.mediaType.rawValue)")
                                        print("SampleBuffer 子类型: \(formatDescription.mediaSubType.rawValue)")
                                    }
                                }
                            } else {
                                videoRenderer.stopRequestingMediaData()
                                // Mark reader as finished and restart if needed for looping
                                DispatchQueue.main.async {
                                    print("Video finished playing")
                                }
                                return
                            }
                        } else {
                            videoRenderer.stopRequestingMediaData()
                            return
                        }
                    }
                }
           
                if let sourceAssetAudioTrack = audioTrack {
                    let sourceAssetReaderAudioTrackOutput = AVAssetReaderTrackOutput(track: sourceAssetAudioTrack, outputSettings: nil)
                    sourceAssetReader.add(sourceAssetReaderAudioTrackOutput)
                    audioRenderer.requestMediaDataWhenReady(on: DispatchQueue.global()) {
                        while audioRenderer.isReadyForMoreMediaData {
                            if let sampleBuffer = sourceAssetReaderAudioTrackOutput.copyNextSampleBuffer() {
                                audioRenderer.enqueue(sampleBuffer)
                            } else {
                                audioRenderer.stopRequestingMediaData()
                                return
                            }
                        }
                    }
                }
           
                // Start the playback immediately.
                synchronizer.setRate(1, time: .zero)
//
                // Return an entity of a plane which uses the VideoMaterial.
                let modelEntity = ModelEntity(mesh: .generatePlane(width: 1, height: 1), materials: [videoMaterial])
                entity.addChild(modelEntity)
                modelEntity.position = SIMD3(x: 0, y: 1, z: -2)
                              
                
                // Create a TextureResource from the LowLevelTexture.
                let resource = try await TextureResource(from: llt)
                // Create a material that uses the texture.
                let material = UnlitMaterial(texture: resource)

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
    
    // MARK: - Texture Processing
    
    func populateMPS(sourceBuffer: CVPixelBuffer, lowLevelTexture: LowLevelTexture, device: MTLDevice) {
        // Set up the Metal command queue and compute command encoder,
        // or abort if that fails.
        guard let commandQueue = device.makeCommandQueue(),
              let commandBuffer = commandQueue.makeCommandBuffer() else {
            return
        }
        
        // Now sourceBuffer should already be in BGRA format, create Metal texture directly
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
        let blurRadius = model.blurRadius
        let blur = MPSImageGaussianBlur(device: device, sigma: blurRadius)

        // Check input and output texture compatibility
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
    
    
    
    // MARK: - Helper Methods
    
    /// 创建临时纹理描述符
    private func createTempTextureDescriptor(from texture: MTLTexture) -> MTLTextureDescriptor {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: texture.pixelFormat,
            width: texture.width,
            height: texture.height,
            mipmapped: false
        )
        descriptor.usage = [.shaderRead, .shaderWrite]
        return descriptor
    }
    
    /// 复制纹理的辅助方法
    private func copyTexture(from sourceTexture: MTLTexture, to destinationTexture: MTLTexture, commandBuffer: MTLCommandBuffer) {
        guard let blitEncoder = commandBuffer.makeBlitCommandEncoder() else {
            print("Failed to create blit encoder")
            return
        }
        blitEncoder.copy(from: sourceTexture, to: destinationTexture)
        blitEncoder.endEncoding()
    }
}
#Preview {
    VideoWithMPSImmersiveView()
}

