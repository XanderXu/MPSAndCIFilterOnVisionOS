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
    let ciContext = CIContext(options: [.cacheIntermediates: false, .workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!])
    var body: some View {
        RealityView { content in
            
            let entity = Entity()
            entity.name = "GameRoot"
            model.rootEntity = entity
            content.add(entity)
            
            do {
                // Create a video composition with CIFilter
                let playerItem = AVPlayerItem(asset: asset)
                let composition = try await AVMutableVideoComposition.videoComposition(with: asset) { request in
                    populateCIFilter(request: request)
                }
                playerItem.videoComposition = composition
                
                // Create a material that uses the VideoMaterial
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
        
    }
    private func populateCIFilter(request: AVAsynchronousCIImageFilteringRequest) {
        let source = request.sourceImage
        
        ciFilter?.setValue(source, forKey: kCIInputImageKey)
        ciFilter?.setValue(model.blurRadius, forKey: kCIInputRadiusKey)

        if let output = ciFilter?.outputImage {
            request.finish(with: output, context: ciContext)
        } else {
            request.finish(with: FilterError.failedToProduceOutputImage)
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
