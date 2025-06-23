//
//  ImageWithMPSImmersiveView.swift
//  MPSAndCIFilterOnVisionOS
//
//  Created by 许M4 on 2025/6/18.
//

import SwiftUI
import RealityKit
import MetalPerformanceShaders
import MetalKit

struct ImageWithMPSImmersiveView: View {
    @Environment(AppModel.self) private var model
    let mtlDevice = MTLCreateSystemDefaultDevice()!
    var body: some View {
        RealityView { content in
            
            let entity = Entity()
            entity.name = "GameRoot"
            model.rootEntity = entity
            content.add(entity)
            
            do {
                let textureLoader = MTKTextureLoader(device: mtlDevice)
                let inTexture = try textureLoader.newTexture(name: "Shop_L", scaleFactor: 1, bundle: nil)
                
                // Create a descriptor for the LowLevelTexture.
                let textureDescriptor = createTextureDescriptor(width: inTexture.width, height: inTexture.height)
                // Create the LowLevelTexture and populate it on the GPU.
                let llt = try LowLevelTexture(descriptor: textureDescriptor)
                
                populateMPS(inTexture: inTexture, lowLevelTexture: llt, device: mtlDevice)

                // Create a TextureResource from the LowLevelTexture.
                let resource = try TextureResource(from: llt)
                // Create a material that uses the texture.
                var material = UnlitMaterial(texture: resource)
                material.opacityThreshold = 0.5

                // Return an entity of a plane which uses the generated texture.
                let modelEntity = ModelEntity(mesh: .generatePlane(width: 1, height: 1), materials: [material])
                entity.addChild(modelEntity)
                modelEntity.position = SIMD3(x: 0, y: 1, z: -2)
                
                model.inTexture = inTexture
                model.lowLevelTexture = llt
            } catch {
                print(error)
            }

        }
        .onChange(of: model.blurRadius) { oldValue, newValue in
            guard model.inTexture != nil && model.lowLevelTexture != nil else {
                return
            }
            populateMPS(inTexture: model.inTexture!, lowLevelTexture: model.lowLevelTexture!, device: mtlDevice)
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
    
    
    
    func populateMPS(inTexture: MTLTexture, lowLevelTexture: LowLevelTexture, device: MTLDevice) {
        // Set up the Metal command queue and compute command encoder,
        // or abort if that fails.
        guard let commandQueue = device.makeCommandQueue(),
              let commandBuffer = commandQueue.makeCommandBuffer() else {
            return
        }
        
        // Create a MPS filter.
        let blur = MPSImageGaussianBlur(device: device, sigma: model.blurRadius)
        // set input output
        let outTexture = lowLevelTexture.replace(using: commandBuffer)
        blur.encode(commandBuffer: commandBuffer, sourceTexture: inTexture, destinationTexture: outTexture)
        
        // The usual Metal enqueue process.
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
    }
}

#Preview {
    ImageWithMPSImmersiveView()
}
