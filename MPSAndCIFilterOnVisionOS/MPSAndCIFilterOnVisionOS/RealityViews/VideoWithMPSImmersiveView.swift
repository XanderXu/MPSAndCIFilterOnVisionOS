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
    
    var body: some View {
        RealityView { content in
            
            let entity = Entity()
            entity.name = "GameRoot"
            model.rootEntity = entity
            content.add(entity)
            
            
            do {
                let avComposition = AVMutableComposition()
                let duration = try await asset.load(.duration)
                let timeRange = CMTimeRange(start: .zero, duration: duration)
                let videoTrack = avComposition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
                if let sourceTrack = try await asset.loadTracks(withMediaType: .video).first {
                    try? videoTrack?.insertTimeRange(timeRange, of: sourceTrack, at: .zero)
                }
                
                let videoTracks = avComposition.tracks(withMediaType: .video)
                
                guard !videoTracks.isEmpty, let videoTrack = videoTracks.first else {
                    fatalError("The specified asset has no video tracks.")
                }
                
                let assetSize = videoTrack.naturalSize
//                let timeRange = videoTrack.timeRange
                
                var instructionLayers = [AVMutableVideoCompositionLayerInstruction]()
                let layerInstruction = AVMutableVideoCompositionLayerInstruction(assetTrack: videoTrack)
                instructionLayers.append(layerInstruction)
                
                let compositionInstruction = AVMutableVideoCompositionInstruction()
                compositionInstruction.timeRange = timeRange
                compositionInstruction.layerInstructions = instructionLayers
                
                let composition = try await AVMutableVideoComposition.videoComposition(withPropertiesOf: avComposition, prototypeInstruction: compositionInstruction)
                
                composition.customVideoCompositorClass = SampleCustomCompositor.self
                
                let playerItem = AVPlayerItem(asset: avComposition)
                playerItem.videoComposition = composition
                
                let player = AVPlayer(playerItem: playerItem)
                let videoMaterial = VideoMaterial(avPlayer: player)
                let modelEntity = ModelEntity(mesh: .generatePlane(width: 1, height: 1), materials: [videoMaterial])
                entity.addChild(modelEntity)
                modelEntity.position = SIMD3(x: 0, y: 1, z: -2)
                player.play()
            } catch {
                print(error)
            }
            
            
        }
        .onChange(of: model.blurRadius) { oldValue, newValue in
            guard model.inTexture != nil && model.lowLevelTexture != nil else {
                return
            }
        }
        
        
    }
}
#Preview {
    VideoWithMPSImmersiveView()
}


import Foundation
import AVKit
import AVFoundation
import CoreImage

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
    private let coreImageContext = CIContext(options: [CIContextOption.cacheIntermediates: false])
    let ciFilter = CIFilter(name: "CIGaussianBlur")!
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
            
        
            let sourceCIImage = CIImage(cvPixelBuffer: sourceBuffer)
            ciFilter.setValue(sourceCIImage, forKey: kCIInputImageKey)
            ciFilter.setValue(100.0, forKey: kCIInputRadiusKey)
            if let outputImage = ciFilter.outputImage {
                let renderDestination = CIRenderDestination(pixelBuffer: outputPixelBuffer)
                do {
                    try coreImageContext.startTask(toRender: outputImage, to: renderDestination)
                } catch {
                    print("Error starting request: \(error)")
                }
            }
        }
        
        request.finish(withComposedVideoFrame: outputPixelBuffer)
    }
}
