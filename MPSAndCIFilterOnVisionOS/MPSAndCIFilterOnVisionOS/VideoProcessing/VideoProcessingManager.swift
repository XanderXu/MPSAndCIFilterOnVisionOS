//
//  VideoProcessingManager.swift
//  MPSAndCIFilterOnVisionOS
//
//  Created by AI Assistant on 2025/9/12.
//

import Foundation
@preconcurrency import AVFoundation
import MetalKit
import RealityKit
import MetalPerformanceShaders

/// Video processing manager for video playback and MPS effects
final class VideoProcessingManager {
    
    // MARK: - Properties
    
    private(set) var videoRenderer: AVSampleBufferVideoRenderer!
    private(set) var audioRenderer: AVSampleBufferAudioRenderer!
    private var synchronizer: AVSampleBufferRenderSynchronizer!
    private var lowLevelTexture: LowLevelTexture?
    private var reader: AVAssetReader?
    private var trackOutput: AVAssetReaderTrackOutput?
    private var device: MTLDevice?
    
    var blurRadius: Float = 10.0
    var onTextureUpdated: (() -> Void)?
    
    init() {
        videoRenderer = AVSampleBufferVideoRenderer()
        audioRenderer = AVSampleBufferAudioRenderer()
        synchronizer = AVSampleBufferRenderSynchronizer()
    }
    
    // MARK: - Public Methods
    
    /// Setup video playback with MPS effects
    func setupVideoPlayback(
        asset: AVURLAsset,
        videoTrack: AVAssetTrack,
        audioTrack: AVAssetTrack?,
        lowLevelTexture: LowLevelTexture,
        device: MTLDevice,
        blurRadius: Float
    ) throws {
        
        self.device = device
        self.blurRadius = blurRadius
        self.lowLevelTexture = lowLevelTexture
        
        synchronizer.addRenderer(videoRenderer)
        synchronizer.addRenderer(audioRenderer)
        
        try setupReader(asset: asset, videoTrack: videoTrack)
        
        
        videoRenderer?.requestMediaDataWhenReady(on: DispatchQueue.global()) { [weak self] in
            self?.processVideoFrames()
        }
        
        if let audioTrack = audioTrack {
            setupAudioProcessing(audioTrack: audioTrack)
        }
        
        synchronizer?.setRate(1, time: .zero)
    }
    
    // MARK: - Private Methods
    
    private func setupReader(asset: AVURLAsset, videoTrack: AVAssetTrack) throws {
        let reader = try AVAssetReader(asset: asset)
        //Can't convert HDR to non-HDR
        let trackOutput = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferMetalCompatibilityKey as String: true
        ])
        
        reader.add(trackOutput)
        reader.startReading()
        
        self.reader = reader
        self.trackOutput = trackOutput
    }
    
    private func processVideoFrames() {
        while videoRenderer?.isReadyForMoreMediaData ?? false {
            guard reader?.status == .reading else {
                videoRenderer?.stopRequestingMediaData()
                print("Video reading completed or error occurred")
                break
            }
            
            guard let sampleBuffer = trackOutput?.copyNextSampleBuffer() else {
                videoRenderer?.stopRequestingMediaData()
                print("Video playback completed")
                break
            }
            
            videoRenderer?.enqueue(sampleBuffer)
            
            if let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) {
                guard let lowLevelTexture = self.lowLevelTexture else { return }
                Task {@MainActor in
                    self.populateMPS(sourceBuffer: pixelBuffer, lowLevelTexture: lowLevelTexture, device: device!)
                }
            } else {
                print("Warning: Unable to get CVPixelBuffer from CMSampleBuffer")
                if let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer) {
                    print("SampleBuffer media type: \(formatDescription.mediaType.rawValue)")
                    print("SampleBuffer subtype: \(formatDescription.mediaSubType.rawValue)")
                }
            }
        }
    }
    func stopPlayback() {
        synchronizer?.setRate(0, time: .zero)
        videoRenderer?.stopRequestingMediaData()
        audioRenderer?.stopRequestingMediaData()
    }
    
    func pausePlayback() {
        synchronizer?.setRate(0, time: synchronizer?.currentTime() ?? .zero)
    }
    
    func resumePlayback() {
        synchronizer?.setRate(1, time: synchronizer?.currentTime() ?? .zero)
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
        let blurRadius = blurRadius
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
        self.onTextureUpdated?()
    }
    
    private func setupAudioProcessing(audioTrack: AVAssetTrack) {
        guard let audioRenderer = audioRenderer else { return }
        
        audioRenderer.requestMediaDataWhenReady(on: DispatchQueue.global()) {
            print("Audio processing logic to be implemented")
        }
    }
}
