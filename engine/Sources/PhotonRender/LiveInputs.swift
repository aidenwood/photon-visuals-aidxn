// Live audio and MIDI capture.
//
// Thin platform plumbing on top of the tested analysis: `AudioAnalyser` and
// `MidiParser` hold the logic and are verified against synthetic signals, so
// what is left here is device wiring. That split is deliberate — the parts that
// can be tested without hardware are, and the parts that can't are kept small
// enough to read.
//
// **Both must fail soft.** A denied microphone permission or an absent
// controller is an ordinary Tuesday, not an error state: the engine keeps
// running and the operator simply gets no audio reactivity. Nothing here may
// ever take down a show.

import AVFoundation
import CoreMIDI
import Foundation

/// Captures system audio input and feeds the analyser.
public final class AudioInput: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let analyser: AudioAnalyser
    private var buffer: [Float] = []
    private var lastTime = CACurrentMediaTime()
    private var running = false

    /// Why capture isn't running, for an operator-facing status line.
    public private(set) var status: String = "stopped"

    public init(analyser: AudioAnalyser) {
        self.analyser = analyser
        buffer.reserveCapacity(AudioAnalyser.fftSize * 4)
    }

    /// Latest analysis. Safe to read from the render thread.
    public var snapshot: AudioSnapshot { analyser.snapshot }

    /// Starts capture. Returns false and sets `status` rather than throwing —
    /// no audio input must never be fatal.
    @discardableResult
    public func start() -> Bool {
        guard !running else { return true }

        // **Never trigger a permission prompt from here.** Requesting
        // microphone access blocks until the user answers — and from a
        // non-bundled binary it can block indefinitely. An engine that stalls
        // waiting on a dialog has failed in exactly the way this class exists
        // to prevent. Permission is the app's job to request, up front; we only
        // ever check what has already been decided.
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            break
        case .notDetermined:
            status = "microphone permission not granted yet"
            return false
        case .denied, .restricted:
            status = "microphone access denied"
            return false
        @unknown default:
            status = "microphone permission unknown"
            return false
        }

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            status = "no input device"
            return false
        }
        let sampleRate = Float(format.sampleRate)

        input.installTap(onBus: 0, bufferSize: UInt32(AudioAnalyser.fftSize), format: format)
        { [weak self] buf, _ in
            guard let self, let data = buf.floatChannelData else { return }
            // The audio callback thread is genuinely realtime: copy and leave.
            // All analysis happens below, off this thread.
            let n = Int(buf.frameLength)
            let channel = data[0]
            var mono = [Float](repeating: 0, count: n)
            for i in 0..<n { mono[i] = channel[i] }
            self.consume(mono, sampleRate: sampleRate)
        }

        do {
            try engine.start()
            running = true
            status = "running"
            return true
        } catch {
            input.removeTap(onBus: 0)
            status = "start failed: \(error.localizedDescription)"
            return false
        }
    }

    public func stop() {
        guard running else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        running = false
        status = "stopped"
    }

    private func consume(_ samples: [Float], sampleRate: Float) {
        buffer.append(contentsOf: samples)
        // Analyse whole windows only; keep the remainder for the next callback.
        while buffer.count >= AudioAnalyser.fftSize {
            let window = Array(buffer.prefix(AudioAnalyser.fftSize))
            buffer.removeFirst(AudioAnalyser.fftSize)
            let now = CACurrentMediaTime()
            let dt = Float(min(max(now - lastTime, 0), 0.5))
            lastTime = now
            analyser.process(samples: window, sampleRate: sampleRate, dt: dt)
        }
        // Don't let a stalled consumer grow this without bound.
        if buffer.count > AudioAnalyser.fftSize * 8 {
            buffer.removeFirst(buffer.count - AudioAnalyser.fftSize)
        }
    }
}

/// Receives MIDI from all sources and parses it.
public final class MidiInput: @unchecked Sendable {
    private var client = MIDIClientRef()
    private var port = MIDIPortRef()
    private var parser = MidiParser()
    private var clock = MidiClockTracker()
    private let lock = NSLock()
    private var pending: [MidiMessage] = []

    /// Tempo derived from MIDI clock, if a source is sending it.
    public var bpm: Double? { lock.withLock { clock.bpm } }

    /// Operator-facing status.
    public private(set) var status: String = "stopped"
    /// Connected source count.
    public private(set) var sourceCount: Int = 0

    public init() {}

    /// Opens every available MIDI source. Fails soft.
    @discardableResult
    public func start() -> Bool {
        var result = MIDIClientCreateWithBlock("Photon" as CFString, &client) { _ in }
        guard result == noErr else { status = "client failed (\(result))"; return false }

        result = MIDIInputPortCreateWithProtocol(
            client, "Photon In" as CFString, ._1_0, &port
        ) { [weak self] evtList, _ in
            self?.receive(evtList)
        }
        guard result == noErr else { status = "port failed (\(result))"; return false }

        let count = MIDIGetNumberOfSources()
        for i in 0..<count {
            MIDIPortConnectSource(port, MIDIGetSource(i), nil)
        }
        sourceCount = count
        status = count == 0 ? "no controllers found" : "listening to \(count) source(s)"
        return true
    }

    private func receive(_ list: UnsafePointer<MIDIEventList>) {
        var bytes: [UInt8] = []
        var packet = list.pointee.packet
        for _ in 0..<list.pointee.numPackets {
            // UMP words carry MIDI 1.0 messages in their lower bytes.
            withUnsafeBytes(of: packet.words) { raw in
                let words = raw.bindMemory(to: UInt32.self)
                for w in 0..<Int(packet.wordCount) where w < words.count {
                    let word = words[w]
                    bytes.append(UInt8((word >> 16) & 0xFF))
                    bytes.append(UInt8((word >> 8) & 0xFF))
                    bytes.append(UInt8(word & 0xFF))
                }
            }
            packet = MIDIEventPacketNext(&packet).pointee
        }
        guard !bytes.isEmpty else { return }

        let now = CACurrentMediaTime()
        lock.withLock {
            for m in parser.parse(bytes) {
                if case .clock = m { clock.tick(at: now) }
                if case .stop = m { clock.reset() }
                pending.append(m)
            }
            // Bound the queue: a controller sending clock at 48 Hz will fill
            // this if nobody drains it, and dropping old control messages is
            // far better than growing without limit during a show.
            if pending.count > 512 { pending.removeFirst(pending.count - 512) }
        }
    }

    /// Drains messages received since the last call.
    public func drain() -> [MidiMessage] {
        lock.withLock {
            let out = pending
            pending.removeAll(keepingCapacity: true)
            return out
        }
    }

    public func stop() {
        if port != 0 { MIDIPortDispose(port); port = 0 }
        if client != 0 { MIDIClientDispose(client); client = 0 }
        status = "stopped"
        sourceCount = 0
    }
}
