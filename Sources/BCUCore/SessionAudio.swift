import AppKit
import AVFoundation
import CoreAudio

/// Sound from apps that only the agent is using (every window on an agent
/// display) is muted on the speakers and recorded to a file that exists for
/// as long as the session's display does. Apps the user also has windows in
/// play normally.
///
/// Uses a Core Audio process tap: the apps' audio processes (helpers
/// included, matched by bundle ID) are mixed to stereo, muted, and read
/// through a private aggregate device.
public final class SessionAudio {
    /// Where this session's audio goes.
    public let url: URL
    /// The file has been created.
    public private(set) var recording = false
    /// Apps currently routed to the file. Any thread.
    public var routedApps: [String] {
        get { stateLock.lock(); defer { stateLock.unlock() }; return _routedApps }
        set { stateLock.lock(); _routedApps = newValue; stateLock.unlock() }
    }
    private var _routedApps: [String] = []
    private let stateLock = NSLock()

    private let queue = DispatchQueue(label: "bcu.audio")
    /// The recorder's callback. Separate from `queue`, because stopping the
    /// device from `queue` waits for the callback to return.
    private let ioQueue = DispatchQueue(label: "bcu.audio.io", qos: .userInteractive)
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var tapDescription: AnyObject?
    private var processes: [AudioObjectID] = []
    private var file: AVAudioFile?
    private var fileFormat: AVAudioFormat?
    private var converter: AVAudioConverter?
    private var failedAt: Date?
    private var outputListeners: [AudioObjectID: AudioObjectPropertyListenerBlock] = [:]

    public init(name: String) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("bcu-audio", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // ADTS AAC: self-contained frames, so the file is readable while it is written.
        url = dir.appendingPathComponent("\(name).aac")
    }

    /// Route these apps' audio to the file (empty stops the tap).
    public func route(_ apps: [NSRunningApplication]) {
        queue.async { self.apply(apps) }
    }

    /// Stop and delete the file.
    public func end() {
        queue.sync {
            self.teardownTap()
            self.file = nil
            self.converter = nil
            self.fileFormat = nil
            if self.recording {
                try? FileManager.default.removeItem(at: self.url)
                self.recording = false
                Log.info("audio: removed \(self.url.lastPathComponent)")
            }
            self.routedApps = []
        }
    }

    // MARK: Tap

    /// The tap (which mutes the apps) stays up while they have audio
    /// processes. The recorder (an aggregate device reading the tap, which
    /// lights the menu bar's recording indicator) runs only while one of
    /// them is actually playing.
    private func apply(_ apps: [NSRunningApplication]) {
        guard #available(macOS 14.2, *) else { return }
        let wanted = Self.audioProcesses(of: apps)
        let names = apps.compactMap(\.localizedName).sorted()
        defer { updateRecorder() }
        if wanted.isEmpty {
            if tapID != kAudioObjectUnknown {
                teardownTap()
                Log.info("audio: stopped routing")
            }
            routedApps = []
            return
        }
        if wanted == processes, tapID != kAudioObjectUnknown { return }
        if tapID != kAudioObjectUnknown {
            // Same tap, new process list.
            let d = CATapDescription(stereoMixdownOfProcesses: wanted)
            configure(d)
            if let old = tapDescription as? CATapDescription { d.uuid = old.uuid }
            var ref: CATapDescription? = d
            var addr = Self.address(kAudioTapPropertyDescription)
            let err = AudioObjectSetPropertyData(tapID, &addr, 0, nil, UInt32(MemoryLayout<CATapDescription?>.size), &ref)
            if err == noErr {
                tapDescription = d
                setProcesses(wanted)
                routedApps = names
                Log.info("audio: now muting \(names.joined(separator: ", "))")
                return
            }
            teardownTap()
        }
        // Don't retry a refused tap (no permission) every second.
        if let failedAt, Date().timeIntervalSince(failedAt) < 30 { return }
        let d = CATapDescription(stereoMixdownOfProcesses: wanted)
        configure(d)
        var tap = AudioObjectID(kAudioObjectUnknown)
        let err = AudioHardwareCreateProcessTap(d, &tap)
        guard err == noErr else {
            failedAt = Date()
            Log.info("audio: couldn't tap app audio (\(err)); allow System Audio Recording for Background Computer Use")
            return
        }
        tapID = tap
        tapDescription = d
        setProcesses(wanted)
        routedApps = names
        failedAt = nil
        Log.info("audio: muted \(names.joined(separator: ", ")) on the speakers")
    }

    @available(macOS 14.2, *)
    private func configure(_ d: CATapDescription) {
        d.name = "Background Computer Use agent audio"
        d.isPrivate = true
        d.muteBehavior = .muted
    }

    /// Watch each process for starting and stopping output.
    private func setProcesses(_ ids: [AudioObjectID]) {
        for (id, block) in outputListeners where !ids.contains(id) {
            var addr = Self.address(kAudioProcessPropertyIsRunningOutput)
            AudioObjectRemovePropertyListenerBlock(id, &addr, queue, block)
            outputListeners[id] = nil
        }
        for id in ids where outputListeners[id] == nil {
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.updateRecorder() }
            var addr = Self.address(kAudioProcessPropertyIsRunningOutput)
            if AudioObjectAddPropertyListenerBlock(id, &addr, queue, block) == noErr { outputListeners[id] = block }
        }
        processes = ids
    }

    private var playing: Bool {
        processes.contains { id in
            var running: UInt32 = 0
            var size = UInt32(MemoryLayout<UInt32>.size)
            var addr = Self.address(kAudioProcessPropertyIsRunningOutput)
            return AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &running) == noErr && running != 0
        }
    }

    /// On `queue`.
    private func updateRecorder() {
        let want = tapID != kAudioObjectUnknown && playing
        if want, aggregateID == kAudioObjectUnknown {
            do {
                try startRecorder()
                Log.info("audio: recording \(routedApps.joined(separator: ", ")) to \(url.path)")
            } catch {
                stopRecorder()
                Log.info("audio: \(error)")
            }
        } else if !want, aggregateID != kAudioObjectUnknown {
            stopRecorder()
            Log.info("audio: recording paused, nothing playing")
        }
    }

    private func startRecorder() throws {
        guard let d = tapDescription, #available(macOS 14.2, *), let uuid = (d as? CATapDescription)?.uuid else { return }
        guard let output = Self.defaultOutputUID() else { throw ToolError("no audio output device") }
        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Background Computer Use agent audio",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: output,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: output]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true, kAudioSubTapUIDKey: uuid.uuidString]],
        ]
        var agg = AudioObjectID(kAudioObjectUnknown)
        var err = AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &agg)
        guard err == noErr else { throw ToolError("couldn't create the audio device (\(err))") }
        aggregateID = agg

        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var formatAddr = Self.address(kAudioTapPropertyFormat)
        err = AudioObjectGetPropertyData(tapID, &formatAddr, 0, nil, &size, &asbd)
        guard err == noErr, let format = AVAudioFormat(streamDescription: &asbd) else { throw ToolError("couldn't read the tap format (\(err))") }
        try openFile(for: format)

        var proc: AudioDeviceIOProcID?
        err = AudioDeviceCreateIOProcIDWithBlock(&proc, agg, ioQueue) { [weak self] _, input, _, _, _ in
            guard let self,
                  let buffer = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: input, deallocator: nil) else { return }
            self.write(buffer)
        }
        guard err == noErr, let proc else { throw ToolError("couldn't read the tap (\(err))") }
        procID = proc
        err = AudioDeviceStart(agg, proc)
        guard err == noErr else { throw ToolError("couldn't start reading the tap (\(err))") }
    }

    private func stopRecorder() {
        if aggregateID != kAudioObjectUnknown {
            if let procID {
                AudioDeviceStop(aggregateID, procID)
                AudioDeviceDestroyIOProcID(aggregateID, procID)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        procID = nil
        aggregateID = AudioObjectID(kAudioObjectUnknown)
    }

    private func teardownTap() {
        stopRecorder()
        setProcesses([])
        if tapID != kAudioObjectUnknown, #available(macOS 14.2, *) {
            AudioHardwareDestroyProcessTap(tapID)
        }
        tapID = AudioObjectID(kAudioObjectUnknown)
        tapDescription = nil
    }

    // MARK: File

    /// One AAC file per session. Later taps with another sample rate are
    /// converted to the first one's.
    private func openFile(for format: AVAudioFormat) throws {
        if let fileFormat {
            converter = fileFormat == format ? nil : AVAudioConverter(from: format, to: fileFormat)
            return
        }
        try? FileManager.default.removeItem(at: url)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: format.channelCount,
            AVEncoderBitRateKey: 128_000,
        ]
        file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: format.commonFormat, interleaved: format.isInterleaved)
        fileFormat = format
        converter = nil
        recording = true
    }

    /// On `ioQueue`.
    private func write(_ buffer: AVAudioPCMBuffer) {
        guard let file else { return }
        do {
            if let converter, let out = AVAudioPCMBuffer(pcmFormat: converter.outputFormat,
                                                          frameCapacity: AVAudioFrameCount(Double(buffer.frameLength) * converter.outputFormat.sampleRate / converter.inputFormat.sampleRate) + 16) {
                var fed = false
                var error: NSError?
                converter.convert(to: out, error: &error) { _, status in
                    if fed { status.pointee = .noDataNow; return nil }
                    fed = true
                    status.pointee = .haveData
                    return buffer
                }
                if out.frameLength > 0 { try file.write(from: out) }
            } else {
                try file.write(from: buffer)
            }
        } catch {
            Log.info("audio: write failed: \(error)")
            self.file = nil
        }
    }

    // MARK: Core Audio lookups

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    }

    /// Every Core Audio process object belonging to these apps: the apps
    /// themselves and helpers whose bundle ID extends theirs.
    static func audioProcesses(of apps: [NSRunningApplication]) -> [AudioObjectID] {
        guard !apps.isEmpty else { return [] }
        let pids = Set(apps.map(\.processIdentifier))
        let bundles = apps.compactMap(\.bundleIdentifier)
        var size: UInt32 = 0
        var addr = address(kAudioHardwarePropertyProcessObjectList)
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.filter { id in
            var pid: pid_t = 0
            var psize = UInt32(MemoryLayout<pid_t>.size)
            var paddr = address(kAudioProcessPropertyPID)
            if AudioObjectGetPropertyData(id, &paddr, 0, nil, &psize, &pid) == noErr, pids.contains(pid) { return true }
            var bundle: CFString = "" as CFString
            var bsize = UInt32(MemoryLayout<CFString>.size)
            var baddr = address(kAudioProcessPropertyBundleID)
            guard AudioObjectGetPropertyData(id, &baddr, 0, nil, &bsize, &bundle) == noErr else { return false }
            let b = bundle as String
            return bundles.contains { b == $0 || b.hasPrefix($0 + ".") }
        }.sorted()
    }

    private static func defaultOutputUID() -> String? {
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var addr = address(kAudioHardwarePropertyDefaultSystemOutputDevice)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &device) == noErr else { return nil }
        var uid: CFString = "" as CFString
        var usize = UInt32(MemoryLayout<CFString>.size)
        var uaddr = address(kAudioDevicePropertyDeviceUID)
        guard AudioObjectGetPropertyData(device, &uaddr, 0, nil, &usize, &uid) == noErr else { return nil }
        return uid as String
    }
}
