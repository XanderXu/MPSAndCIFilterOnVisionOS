//
//  VideoProcessingManager.swift
//  MPSAndCIFilterOnVisionOS
//
//  Created by AI Assistant on 2025/9/12.
//

import Foundation
import AVFoundation
import MetalKit
import RealityKit
import MetalPerformanceShaders

/// 视频处理管理器，负责视频播放和 MPS 特效处理
@MainActor
class VideoProcessingManager {
    
    // MARK: - Properties
    
    private var videoRenderer: AVSampleBufferVideoRenderer?
    private var audioRenderer: AVSampleBufferAudioRenderer?
    private var synchronizer: AVSampleBufferRenderSynchronizer?
    private var device: MTLDevice?
    var blurRadius: Float = 10.0
    
    init() {
        // 初始化时不创建设备，等待 setup 时传入
    }
    
    // MARK: - Public Methods
    
    /// 设置视频播放
    /// - Parameters:
    ///   - asset: 视频资源
    ///   - videoTrack: 视频轨道
    ///   - audioTrack: 音频轨道（可选）
    ///   - naturalSize: 视频自然尺寸
    ///   - lowLevelTexture: 低级纹理用于 MPS 处理
    ///   - device: Metal 设备
    /// - Returns: VideoMaterial 用于显示
    func setupVideoPlayback(
        asset: AVURLAsset,
        videoTrack: AVAssetTrack,
        audioTrack: AVAssetTrack?,
        lowLevelTexture: LowLevelTexture,
        device: MTLDevice,
        blurRadius: Float
    )  throws -> VideoMaterial {
        
        // 存储设备和模糊半径
        self.device = device
        self.blurRadius = blurRadius
        
        // 创建视频和音频渲染器
        let videoRenderer = AVSampleBufferVideoRenderer()
        let audioRenderer = AVSampleBufferAudioRenderer()
        
        // 创建同步器
        let synchronizer = AVSampleBufferRenderSynchronizer()
        
        // 将渲染器添加到同步器
        synchronizer.addRenderer(videoRenderer)
        synchronizer.addRenderer(audioRenderer)
        
        // 存储引用
        self.videoRenderer = videoRenderer
        self.audioRenderer = audioRenderer
        self.synchronizer = synchronizer
        
        let reader = try AVAssetReader(asset: asset)
        let trackOutput = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferMetalCompatibilityKey as String: true
        ])
        reader.add(trackOutput)
        
        reader.startReading()
        
        // 创建 VideoMaterial
        let videoMaterial = VideoMaterial(videoRenderer: videoRenderer)
        
        // 开始视频帧处理
        videoRenderer.requestMediaDataWhenReady(on: DispatchQueue.global()) {
            while videoRenderer.isReadyForMoreMediaData {
                let isReading = reader.status == .reading
                guard isReading else {
                    videoRenderer.stopRequestingMediaData()
                    print("视频读取完成或遇到错误")
                    
                    break
                }
                
                if let sampleBuffer = trackOutput.copyNextSampleBuffer() {
                    videoRenderer.enqueue(sampleBuffer)
                    
                    // 从 CMSampleBuffer 中获取 CVPixelBuffer，在后台线程异步处理MPS
                    if let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) {
                        let width = CVPixelBufferGetWidth(pixelBuffer)
                        let height = CVPixelBufferGetHeight(pixelBuffer)
                        print("成功获取到 CVPixelBuffer，尺寸: \(width)x\(height)")
                        Task {@MainActor in
                            self.processMPSEffect(pixelBuffer: pixelBuffer, lowLevelTexture: lowLevelTexture)
                            
                        }
                        
                    } else {
                        print("警告: 无法从 CMSampleBuffer 获取 CVPixelBuffer")
                        if let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer) {
                            print("SampleBuffer 媒体类型: \(formatDescription.mediaType.rawValue)")
                            print("SampleBuffer 子类型: \(formatDescription.mediaSubType.rawValue)")
                        }
                    }
                } else {
                    videoRenderer.stopRequestingMediaData()
                    print("视频播放完成")
                    
                    
                    break
                }
            }
        }
        
        // 设置音频处理（如果有音频轨道）
        if let audioTrack = audioTrack {
            setupAudioProcessing(audioTrack: audioTrack)
        }
        
        // 开始播放
        synchronizer.setRate(1, time: .zero)
        
        return videoMaterial
    }
    
    /// 停止视频播放
    func stopPlayback() async {
        synchronizer?.setRate(0, time: .zero)
        videoRenderer?.stopRequestingMediaData()
        audioRenderer?.stopRequestingMediaData()
    }
    
    /// 暂停播放
    func pausePlayback() {
        synchronizer?.setRate(0, time: synchronizer?.currentTime() ?? .zero)
    }
    
    /// 恢复播放
    func resumePlayback() {
        synchronizer?.setRate(1, time: synchronizer?.currentTime() ?? .zero)
    }
    
    
    /// 处理 MPS 特效
    @MainActor
    private func processMPSEffect(
        pixelBuffer: CVPixelBuffer,
        lowLevelTexture: LowLevelTexture
    )  {
        
        guard let device = device,
              let commandQueue = device.makeCommandQueue(),
              let commandBuffer = commandQueue.makeCommandBuffer() else {
            print("Failed to create Metal command queue or buffer")
            return
        }
        
        // 创建 Metal 纹理缓存
        var mtlTextureCache: CVMetalTextureCache? = nil
        let cacheResult = CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &mtlTextureCache)
        guard cacheResult == kCVReturnSuccess, let textureCache = mtlTextureCache else {
            print("Failed to create Metal texture cache")
            return
        }
        
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        
        // 从 CVPixelBuffer 创建 Metal 纹理
        var cvTexture: CVMetalTexture?
        let result = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault,
            textureCache,
            pixelBuffer,
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
            print("CVPixelBuffer format: \(CVPixelBufferGetPixelFormatType(pixelBuffer))")
            print("Expected BGRA format: \(kCVPixelFormatType_32BGRA)")
            return
        }
        
        // 创建 MPS 高斯模糊滤镜
        let blur = MPSImageGaussianBlur(device: device, sigma: blurRadius)
        
        // 检查输入输出纹理兼容性
        guard bgraTexture.width <= lowLevelTexture.descriptor.width,
              bgraTexture.height <= lowLevelTexture.descriptor.height else {
            print("Texture size mismatch: input(\(bgraTexture.width)x\(bgraTexture.height)) vs output(\(lowLevelTexture.descriptor.width)x\(lowLevelTexture.descriptor.height))")
            return
        }
        
        // 应用 MPS 滤镜
        let outTexture = lowLevelTexture.replace(using: commandBuffer)
        blur.encode(commandBuffer: commandBuffer, sourceTexture: bgraTexture, destinationTexture: outTexture)
        
        // 使用异步提交，避免阻塞操作
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
    }
    
    // MARK: - Audio Processing
    
    /// 设置音频处理
    /// - Parameter audioTrack: 音频轨道
    private func setupAudioProcessing(audioTrack: AVAssetTrack) {
        guard let audioRenderer = audioRenderer else { return }
        
        // 注意：音频处理需要单独的 reader，这里先预留接口
        audioRenderer.requestMediaDataWhenReady(on: DispatchQueue.global()) {
            // 音频处理逻辑可以后续添加
            print("音频处理逻辑待实现")
        }
    }
    
    // MARK: - Deinitializer
    
}
