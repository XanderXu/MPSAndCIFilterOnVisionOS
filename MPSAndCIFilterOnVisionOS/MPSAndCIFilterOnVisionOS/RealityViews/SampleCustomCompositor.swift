//
//  SampleCustomCompositor.swift
//  MPSAndCIFilterOnVisionOS
//
//  Created by 许M4 on 2025/6/25.
//

import Foundation
import AVFoundation
import MetalPerformanceShaders
import RealityKit

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
        String(kCVPixelBufferMetalCompatibilityKey): true // Critical!
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
        let blurRadius = Self.blurRadius
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
}
