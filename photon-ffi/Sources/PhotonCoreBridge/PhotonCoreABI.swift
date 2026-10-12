import PhotonFFI

public struct PhotonCoreABIInfo: Sendable {
    public let version: UInt32
    public let layerStride: Int
    public let frameStride: Int
}

public struct PhotonCoreABIError: Error, CustomStringConvertible, Sendable {
    public let description: String
}

/// Reject the backend before passing structs across an incompatible boundary.
/// A caller can show a local startup failure while retaining the editor.
public enum PhotonCoreABI {
    public static func validate() throws -> PhotonCoreABIInfo {
        let version = photon_abi_version()
        let layer = Int(photon_layer_stride())
        let frame = Int(photon_frame_stride())
        guard version == 1,
              layer == MemoryLayout<PhotonLayer>.stride,
              frame == MemoryLayout<PhotonFrame>.stride else {
            throw PhotonCoreABIError(description:
                "Core ABI mismatch: version \(version), layer \(layer)/\(MemoryLayout<PhotonLayer>.stride), frame \(frame)/\(MemoryLayout<PhotonFrame>.stride).")
        }
        return PhotonCoreABIInfo(version: version, layerStride: layer, frameStride: frame)
    }
}
