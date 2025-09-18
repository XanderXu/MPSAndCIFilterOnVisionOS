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
    
    private var videoRenderer: AVSampleBufferVideoRenderer?
    private var audioRenderer: AVSampleBufferAudioRenderer?
    private var synchronizer: AVSampleBufferRenderSynchronizer?
    private var lowLevelTexture: LowLevelTexture?
    private var reader: AVAssetReader?
    private var trackOutput: AVAssetReaderTrackOutput?
    private var device: MTLDevice?
    
    var blurRadius: Float = 10.0
    
    init() {}
    
    // MARK: - Public Methods
    
    /// Setup video playback with MPS effects
    func setupVideoPlayback(
        asset: AVURLAsset,
        videoTrack: AVAssetTrack,
        audioTrack: AVAssetTrack?,
        lowLevelTexture: LowLevelTexture,
        device: MTLDevice,
        blurRadius: Float
    ) throws -> VideoMaterial {
        
        self.device = device
        self.blurRadius = blurRadius
        self.lowLevelTexture = lowLevelTexture
        
        setupRenderers()
        try setupReader(asset: asset, videoTrack: videoTrack)
        
        
        videoRenderer?.requestMediaDataWhenReady(on: DispatchQueue.main) { [weak self] in
            self?.processVideoFrames()
        }
        
        if let audioTrack = audioTrack {
            setupAudioProcessing(audioTrack: audioTrack)
        }
        
        synchronizer?.setRate(1, time: .zero)
        
        let videoMaterial = VideoMaterial(videoRenderer: videoRenderer!)
        return videoMaterial
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
                Task { @MainActor [weak self] in
                    guard let self = self, let lowLevelTexture = self.lowLevelTexture else { return }
                    self.processMPSEffect(pixelBuffer: pixelBuffer, lowLevelTexture: lowLevelTexture)
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
    
    // MARK: - Private Methods
    
    private func setupRenderers() {
        let videoRenderer = AVSampleBufferVideoRenderer()
        let audioRenderer = AVSampleBufferAudioRenderer()
        let synchronizer = AVSampleBufferRenderSynchronizer()
        
        synchronizer.addRenderer(videoRenderer)
        synchronizer.addRenderer(audioRenderer)
        
        self.videoRenderer = videoRenderer
        self.audioRenderer = audioRenderer
        self.synchronizer = synchronizer
    }
    
    private func setupReader(asset: AVURLAsset, videoTrack: AVAssetTrack) throws {
        let reader = try AVAssetReader(asset: asset)
        let trackOutput = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferMetalCompatibilityKey as String: true
        ])
        
        reader.add(trackOutput)
        reader.startReading()
        
        self.reader = reader
        self.trackOutput = trackOutput
    }
    
    @MainActor
    private func processMPSEffect(pixelBuffer: CVPixelBuffer, lowLevelTexture: LowLevelTexture) {
        guard let device = device,
              let commandQueue = device.makeCommandQueue(),
              let commandBuffer = commandQueue.makeCommandBuffer() else {
            print("Failed to create Metal command queue or buffer")
            return
        }
        
        // Create Metal texture cache
        var mtlTextureCache: CVMetalTextureCache?
        let cacheResult = CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &mtlTextureCache)
        guard cacheResult == kCVReturnSuccess, let textureCache = mtlTextureCache else {
            print("Failed to create Metal texture cache")
            return
        }
        
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        
        // Create Metal texture from CVPixelBuffer
        var cvTexture: CVMetalTexture?
        let result = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, textureCache, pixelBuffer, nil,
            .bgra8Unorm, width, height, 0, &cvTexture
        )
        
        guard result == kCVReturnSuccess,
              let cvTexture = cvTexture,
              let bgraTexture = CVMetalTextureGetTexture(cvTexture) else {
            print("Failed to create Metal texture from BGRA pixel buffer")
            return
        }
        
        // Validate texture sizes
        guard bgraTexture.width <= lowLevelTexture.descriptor.width,
              bgraTexture.height <= lowLevelTexture.descriptor.height else {
            print("Texture size mismatch: input(\(bgraTexture.width)x\(bgraTexture.height)) vs output(\(lowLevelTexture.descriptor.width)x\(lowLevelTexture.descriptor.height))")
            return
        }
        
        // Apply MPS blur effect
        let blur = MPSImageGaussianBlur(device: device, sigma: blurRadius)
        let outTexture = lowLevelTexture.replace(using: commandBuffer)
        blur.encode(commandBuffer: commandBuffer, sourceTexture: bgraTexture, destinationTexture: outTexture)
        
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
    }
    
    private func setupAudioProcessing(audioTrack: AVAssetTrack) {
        guard let audioRenderer = audioRenderer else { return }
        
        audioRenderer.requestMediaDataWhenReady(on: DispatchQueue.global()) {
            print("Audio processing logic to be implemented")
        }
    }
}
