# MPSAndCIFilterOnVisionOS
MPSAndCIFilterOnVisionOS 用来演示如何在 visionOS 上使用 **MetalPerformanceShaders(缩写：MPS)** 和 **CIFilter** 实现特殊视觉效果，不仅能实现 ShaderGraph 中 **SurfaceShader** 的类似效果，还能更高效的实现 **GaussianBlur**、 **Histogram** 等效果。

MPSAndCIFilterOnVisionOS demonstrates how to use **MetalPerformanceShaders (MPS)** and **CIFilter** on visionOS to achieve special visual effects. It not only replicates effects similar to **SurfaceShader** in ShaderGraph, but also enables more efficient implementations of effects such as **GaussianBlur** and **Histogram**.

使用流程 Process：
* Image: **MPS/CIFilter** -> **LowLevelTexture** -> **TextureResource** -> **UnlitMaterial**
* Video(CIFilter): [**CIFilter** + **AVMutableVideoComposition** + **AVPlayerItem**] -> **VideoMaterial**
* Video(MPS): [**MPS** + **AVMutableVideoComposition** + **AVPlayerItem**] -> **LowLevelTexture** -> **TextureResource** -> **UnlitMaterial**
