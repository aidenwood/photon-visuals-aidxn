import Metal
guard let d = MTLCreateSystemDefaultDevice() else { exit(1) }
print("device                     : \(d.name)")
print("supportsBCTextureCompression: \(d.supportsBCTextureCompression)")
for f in [MTLGPUFamily.apple7, .apple8, .apple9, .mac2] {
    print("family \(f.rawValue)                  : \(d.supportsFamily(f))")
}
print("argumentBuffersSupport     : \(d.argumentBuffersSupport.rawValue)")
print("maxThreadgroupMemory       : \(d.maxThreadgroupMemoryLength) B")
print("hasUnifiedMemory           : \(d.hasUnifiedMemory)")
print("recommendedMaxWorkingSet   : \(d.recommendedMaxWorkingSetSize/1024/1024) MB")
