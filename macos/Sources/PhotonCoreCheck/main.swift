import PhotonCoreBridge

// Link/layout validation only; no timing or performance benchmark.
let info = try PhotonCoreABI.validate()
try checkFrameRoundTrip()
print("Core ABI \(info.version) verified: layer \(info.layerStride) bytes, frame \(info.frameStride) bytes.")
print("Packed frame field round-trip passed.")
try checkControlRoundTrip()
print("Control mapping round-trip passed.")
try checkSession()
print("Owned-handle session passed.")
try checkAudioReactivity()
print("Audio reactivity passed.")
