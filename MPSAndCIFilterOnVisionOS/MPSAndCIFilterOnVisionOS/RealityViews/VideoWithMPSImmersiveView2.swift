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
                let sourceAssetAudioTrack = audioTrack
                
                let sourceAssetReaderVideoTrackOutput = AVAssetReaderTrackOutput(track: sourceAssetVideoTrack!, outputSettings: nil)
//                let sourceAssetReaderAudioTrackOutput = AVAssetReaderTrackOutput(track: sourceAssetAudioTrack!, outputSettings: nil)
                sourceAssetReader.add(sourceAssetReaderVideoTrackOutput)
//                sourceAssetReader.add(sourceAssetReaderAudioTrackOutput)
           
                sourceAssetReader.startReading()
                
                // Wait for the video renderer to be ready
                videoRenderer.requestMediaDataWhenReady(on: DispatchQueue.global()) {
                    while videoRenderer.isReadyForMoreMediaData {
                        if sourceAssetReader.status == .reading {
                            if let sampleBuffer = sourceAssetReaderVideoTrackOutput.copyNextSampleBuffer() {
                                videoRenderer.enqueue(sampleBuffer)
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
           
//                audioRenderer.requestMediaDataWhenReady(on: DispatchQueue.global()) {
//                    while audioRenderer.isReadyForMoreMediaData {
//                        if let sampleBuffer = sourceAssetReaderAudioTrackOutput.copyNextSampleBuffer() {
//                            audioRenderer.enqueue(sampleBuffer)
//                        } else {
//                            audioRenderer.stopRequestingMediaData()
//                            return
//                        }
//                    }
//                }
           
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
}
#Preview {
    VideoWithMPSImmersiveView()
}

