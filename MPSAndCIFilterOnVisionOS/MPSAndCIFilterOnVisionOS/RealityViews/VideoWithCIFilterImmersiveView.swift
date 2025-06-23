//
//  VideoWithCIFilterImmersiveView.swift
//  MPSAndCIFilterOnVisionOS
//
//  Created by 许M4 on 2025/6/19.
//

import SwiftUI
import RealityKit
import MetalKit
import AVFoundation

struct VideoWithCIFilterImmersiveView: View {
    @Environment(AppModel.self) private var model
    let asset = AVURLAsset(url: Bundle.main.url(forResource: "HDRMovie", withExtension: "mov")!)
    let ciFilter = CIFilter(name: "CIGaussianBlur")
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
                
                
                let playerItem = AVPlayerItem(asset: avComposition)
                playerItem.videoComposition = nil
                let composition = try await AVMutableVideoComposition.videoComposition(with: avComposition) { request in
                    let source = request.sourceImage.clampedToExtent()
                    
                    ciFilter?.setValue(source, forKey: kCIInputImageKey)
//                    ciFilter?.setValue(model.blurRadius, forKey: kCIInputRadiusKey)
                    ciFilter?.setValue(100.0, forKey: kCIInputRadiusKey)

                    if let output = ciFilter?.outputImage?.cropped(to: request.sourceImage.extent) {
                        request.finish(with: output, context: nil)
                    } else {
                        request.finish(with: FilterError.failedToProduceOutputImage)
                    }
                }
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


enum FilterError: Int, Error, LocalizedError {
    case failedToProduceOutputImage = -1_000_001
    
    var errorDescription: String? {
        switch self {
        case .failedToProduceOutputImage:
            return "CIFilter does not produce an output image"
        }
    }
}
#Preview {
    VideoWithCIFilterImmersiveView()
}
