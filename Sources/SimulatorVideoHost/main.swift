//
//  main.swift
//  SimulatorVideoHost
//
//  Created by Василий Маслов on 07.10.2026.
import Foundation
import CoreImage
import CoreVideo
@preconcurrency import CoreMedia
import VideoToolbox
import IOSurface
@preconcurrency import Network
import ObjectiveC
import Darwin

/// VideoToolbox has finished writing before callback delivery; the retained sample is read-only afterwards.
private struct EncodedSample: @unchecked Sendable { let value: CMSampleBuffer }

/// Disposable process boundary for Xcode's private display API. Never boots devices or injects events.
final class VideoHost: @unchecked Sendable {
    private let queue = DispatchQueue(label: "Mimic.SimulatorVideo")
    private let output = DispatchQueue(label: "Mimic.SimulatorVideo.output")
    /// Source cadence has headroom above 40 displayed FPS; retain the prior bitrate per frame.
    private let framesPerSecond: Int32 = 48
    private let deviceID: UUID
    private let developer: String
    private var display: NSObject?
    private var encoder: VTCompressionSession?
    private let context = CIContext(options: [.cacheIntermediates: false])
    private var timer: DispatchSourceTimer?
    private var listener: NWListener?
    private var clients: [UUID: Peer] = [:]
    private var grants: [String: Date] = [:]
    private var sequence: UInt64 = 0
    private var width = 0, height = 0
    private var requestedWidth = 1280, requestedHeight = 1280
    private var orientation = "portrait"
    private var forceKeyframe = true
    private var submitted = 0
    private var pendingOutput = false
    private var enabled = true
    private var input = Data()
    private var source: DispatchSourceRead?
    private var signals: [DispatchSourceSignal] = []
    private struct Peer { let connection: NWConnection; var authorized = false; var token = ""; var sending = false; var needsKeyframe = true }
    init(deviceID: UUID, developer: String) { self.deviceID = deviceID; self.developer = developer }

    // MARK: - Private display discovery

    private func attach() throws {
        enum Failure: Error { case unavailable, device, display }
        guard dlopen("/Library/Developer/PrivateFrameworks/CoreSimulator.framework/CoreSimulator", RTLD_NOW) != nil,
              let cls = NSClassFromString("SimServiceContext") as? NSObject.Type,
              let proto = NSProtocolFromString("SimDisplayIOSurfaceRenderable") else { throw Failure.unavailable }
        let selector = NSSelectorFromString("sharedServiceContextForDeveloperDir:error:")
        typealias Context = @convention(c) (AnyObject, Selector, NSString, AutoreleasingUnsafeMutablePointer<NSError?>) -> AnyObject?
        guard cls.responds(to: selector), let imp = cls.method(for: selector) else { throw Failure.unavailable }
        var error: NSError?
        let fn = unsafeBitCast(imp, to: Context.self)
        guard let service = fn(cls, selector, developer as NSString, &error) as? NSObject else { throw Failure.unavailable }
        let setSelector = NSSelectorFromString("defaultDeviceSetWithError:")
        typealias DeviceSet = @convention(c) (AnyObject, Selector, AutoreleasingUnsafeMutablePointer<NSError?>) -> AnyObject?
        guard service.responds(to: setSelector), let setIMP = service.method(for: setSelector) else { throw Failure.unavailable }
        let getSet = unsafeBitCast(setIMP, to: DeviceSet.self)
        guard let set = getSet(service, setSelector, &error) as? NSObject,
              let devices = set.value(forKey: "devices") as? [NSObject],
              let device = devices.first(where: { ($0.value(forKey: "UDID") as? UUID) == deviceID }),
              (device.value(forKey: "state") as? NSNumber)?.intValue == 3,
              let io = device.value(forKey: "io") as? NSObject,
              let ports = io.value(forKey: "ioPorts") as? [NSObject] else { throw Failure.device }
        var area = 0
        for port in ports {
            guard let candidate = port.perform(NSSelectorFromString("descriptor"))?.takeUnretainedValue() as? NSObject,
                  candidate.conforms(to: proto), let surface = surface(candidate) else { continue }
            let size = IOSurfaceGetWidth(surface) * IOSurfaceGetHeight(surface)
            if size > area { area = size; display = candidate }
        }
        guard display != nil else { throw Failure.display }
    }
    private func surface(_ display: NSObject) -> IOSurface? {
        guard let object = display.perform(NSSelectorFromString("framebufferSurface"))?.takeUnretainedValue(), CFGetTypeID(object) == IOSurfaceGetTypeID() else { return nil }
        return unsafeDowncast(object, to: IOSurfaceRef.self) as IOSurface
    }

    // MARK: - Encoding and bounded delivery

    private func configure(width: Int, height: Int) throws {
        enum Failure: Error { case encoder }
        if let encoder { VTCompressionSessionInvalidate(encoder) }
        self.encoder = nil; self.width = width; self.height = height; forceKeyframe = true
        let status = VTCompressionSessionCreate(allocator: nil, width: Int32(width), height: Int32(height), codecType: kCMVideoCodecType_H264, encoderSpecification: nil, imageBufferAttributes: [kCVPixelBufferIOSurfacePropertiesKey: [:], kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey: width, kCVPixelBufferHeightKey: height] as CFDictionary, compressedDataAllocator: nil, outputCallback: { ref, _, status, flags, sample in
            guard let ref else { return }
            let host = Unmanaged<VideoHost>.fromOpaque(ref).takeUnretainedValue()
            guard status == noErr, !flags.contains(.frameDropped), let sample else { host.queue.async { host.submitted = max(0, host.submitted - 1); host.forceKeyframe = true }; return }
            let result = EncodedSample(value: sample)
            host.queue.async { host.encoded(result.value) }
        }, refcon: Unmanaged.passUnretained(self).toOpaque(), compressionSessionOut: &encoder)
        guard status == noErr, let encoder else { throw Failure.encoder }
        let properties: [CFString: Any] = [kVTCompressionPropertyKey_RealTime: true, kVTCompressionPropertyKey_AllowFrameReordering: false, kVTCompressionPropertyKey_ProfileLevel: kVTProfileLevel_H264_Baseline_AutoLevel, kVTCompressionPropertyKey_AverageBitRate: 4_000_000, kVTCompressionPropertyKey_ExpectedFrameRate: framesPerSecond, kVTCompressionPropertyKey_MaxKeyFrameInterval: framesPerSecond]
        for (key, value) in properties { guard VTSessionSetProperty(encoder, key: key, value: value as CFTypeRef) == noErr else { throw Failure.encoder } }
        guard VTCompressionSessionPrepareToEncodeFrames(encoder) == noErr else { throw Failure.encoder }
    }
    private func tick() {
        guard enabled, submitted < 2, let display, let surface = surface(display) else { return }
        let micros = Int64(DispatchTime.now().uptimeNanoseconds / 1000)
        var image = CIImage(ioSurface: surface)
        switch orientation {
        case "landscapeLeft": image = image.oriented(.left)
        case "landscapeRight": image = image.oriented(.right)
        case "portraitUpsideDown": image = image.oriented(.down)
        default: break
        }
        image = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
        let scale = min(1, max(Double(requestedWidth) / image.extent.width, Double(requestedHeight) / image.extent.height))
        let w = max(2, Int(image.extent.width * scale) / 2 * 2), h = max(2, Int(image.extent.height * scale) / 2 * 2)
        do { if encoder == nil || w != width || h != height { guard submitted == 0 else { return }; try configure(width: w, height: h) } }
        catch { diagnostic(["error": "encoderUnavailable"]); stop(); return }
        guard let encoder, let pool = VTCompressionSessionGetPixelBufferPool(encoder) else { return }
        var buffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) == kCVReturnSuccess, let buffer else { return }
        image = image.transformed(by: CGAffineTransform(scaleX: Double(w) / image.extent.width, y: Double(h) / image.extent.height))
        context.render(image, to: buffer, bounds: CGRect(x: 0, y: 0, width: w, height: h), colorSpace: CGColorSpaceCreateDeviceRGB())
        submitted += 1
        let status = VTCompressionSessionEncodeFrame(encoder, imageBuffer: buffer, presentationTimeStamp: CMTime(value: micros, timescale: 1_000_000), duration: CMTime(value: 1, timescale: framesPerSecond), frameProperties: forceKeyframe ? [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary : nil, sourceFrameRefcon: nil, infoFlagsOut: nil)
        if status != noErr { submitted -= 1; diagnostic(["error": "encoderUnavailable"]) }
        forceKeyframe = false
    }
    private func encoded(_ sample: CMSampleBuffer) {
        submitted = max(0, submitted - 1)
        guard enabled, let format = CMSampleBufferGetFormatDescription(sample), let block = CMSampleBufferGetDataBuffer(sample) else { return }
        let dimensions = CMVideoFormatDescriptionGetDimensions(format)
        guard dimensions.width == width, dimensions.height == height else { return }
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]]
        let keyframe = attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool != true
        var config = Data()
        if keyframe {
            var parameterSets: [Data] = []
            for index in 0..<2 {
                var bytes: UnsafePointer<UInt8>?, size = 0, count = 0, length: Int32 = 0
                guard CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: index, parameterSetPointerOut: &bytes, parameterSetSizeOut: &size, parameterSetCountOut: &count, nalUnitHeaderLengthOut: &length) == noErr, let bytes else { return }
                parameterSets.append(Data(bytes: bytes, count: size))
            }
            let sps = parameterSets[0], pps = parameterSets[1]
            guard sps.count > 3, sps.count < 65536, pps.count < 65536 else { return }
            config.append(contentsOf: [1,sps[1],sps[2],sps[3],255,225]); config.appendBE(UInt16(sps.count)); config.append(sps); config.append(1); config.appendBE(UInt16(pps.count)); config.append(pps)
        }
        let length = CMBlockBufferGetDataLength(block)
        guard length > 0, length <= 450_000 else { forceKeyframe = true; return }
        var encoded = Data(count: length)
        let copied = encoded.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: $0.baseAddress!) }
        guard copied == noErr else { return }
        sequence += 1
        var packet = Data([keyframe ? 1 : 0]); packet.appendBE(sequence); packet.appendBE(UInt64(CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample)) * 1_000_000)); packet.appendBE(UInt32(width)); packet.appendBE(UInt32(height)); packet.appendBE(UInt16(config.count)); packet.append(config); packet.append(encoded)
        // One output write at a time. A slow reader cannot accumulate encoded frames in this process.
        if !pendingOutput {
            pendingOutput = true
            let packet = packet
            output.async {
                var record = Data(); record.appendBE(UInt32(packet.count)); record.append(packet)
                do { try FileHandle.standardOutput.write(contentsOf: record) } catch { self.queue.async { self.stop() } }
                self.queue.async { self.pendingOutput = false }
            }
        } else { forceKeyframe = true }
        for id in Array(clients.keys) {
            guard var peer = clients[id], peer.authorized else { continue }
            guard grants[peer.token].map({ $0 > Date() }) == true else { remove(id); continue }
            if peer.sending { peer.needsKeyframe = true; clients[id] = peer; forceKeyframe = true; continue }
            if peer.needsKeyframe && !keyframe { forceKeyframe = true; continue }
            peer.sending = true; peer.needsKeyframe = false; clients[id] = peer
            let metadata = NWProtocolWebSocket.Metadata(opcode: .binary)
            peer.connection.send(content: packet, contentContext: .init(identifier: "frame", metadata: [metadata]), isComplete: true, completion: .contentProcessed { error in
                self.queue.async { if error != nil { self.remove(id) } else { self.clients[id]?.sending = false } }
            })
        }
    }

    // MARK: - Loopback access and lifecycle

    func run() {
        queue.async {
            do {
                guard let version = Bundle(url: URL(fileURLWithPath: self.developer).deletingLastPathComponent().deletingLastPathComponent())?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String, Int(version.split(separator: ".")[0]) ?? 0 >= 27 else { throw NSError(domain: "Xcode", code: 27) }
                try self.attach()
                let options = NWProtocolWebSocket.Options(); options.autoReplyPing = true
                let parameters = NWParameters.tcp; parameters.defaultProtocolStack.applicationProtocols.insert(options, at: 0); parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
                let listener = try NWListener(using: parameters)
                self.listener = listener
                listener.newConnectionHandler = { self.accept($0) }
                listener.stateUpdateHandler = { state in if case .ready = state, let port = listener.port { self.diagnostic(["ready": true, "port": port.rawValue, "protocol": 1]) } }
                listener.start(queue: self.queue)
                let timer = DispatchSource.makeTimerSource(queue: self.queue); self.timer = timer
                timer.schedule(deadline: .now(), repeating: .nanoseconds(1_000_000_000 / Int(self.framesPerSecond)), leeway: .milliseconds(1)); timer.setEventHandler { self.tick() }; timer.resume()
                let input = DispatchSource.makeReadSource(fileDescriptor: STDIN_FILENO, queue: self.queue); self.source = input
                input.setEventHandler { self.readInput() }; input.resume()
                for number in [SIGTERM, SIGINT] { signal(number, SIG_IGN); let signal = DispatchSource.makeSignalSource(signal: number, queue: self.queue); signal.setEventHandler { self.stop() }; signal.resume(); self.signals.append(signal) }
            } catch { self.diagnostic(["error": "framebufferUnavailable"]); exit(2) }
        }
        dispatchMain()
    }
    private func accept(_ connection: NWConnection) {
        guard clients.count < 8 else { connection.cancel(); return }
        let id = UUID(); clients[id] = Peer(connection: connection)
        connection.stateUpdateHandler = { state in if case .failed = state { self.remove(id) }; if case .cancelled = state { self.clients[id] = nil } }
        connection.start(queue: queue); receive(id)
        queue.asyncAfter(deadline: .now() + 5) { if self.clients[id]?.authorized == false { self.remove(id) } }
    }
    private func receive(_ id: UUID) {
        guard let connection = clients[id]?.connection else { return }
        connection.receiveMessage { data, _, _, error in
            guard error == nil, let data, data.count <= 4096 else { self.remove(id); return }
            if let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                if let token = value["token"] as? String, self.grants[token].map({ $0 > Date() }) == true { self.clients[id]?.authorized = true; self.clients[id]?.token = token; self.forceKeyframe = true }
                else if self.clients[id]?.authorized == true, value["ping"] != nil {
                    let result: [String: Any] = ["pong": value["ping"]!, "serverMicros": DispatchTime.now().uptimeNanoseconds / 1000]
                    let payload = try? JSONSerialization.data(withJSONObject: result)
                    connection.send(content: payload, contentContext: .init(identifier: "clock", metadata: [NWProtocolWebSocket.Metadata(opcode: .text)]), isComplete: true, completion: .idempotent)
                } else { self.remove(id); return }
            } else { self.remove(id); return }
            self.receive(id)
        }
    }
    private func remove(_ id: UUID) { clients.removeValue(forKey: id)?.connection.cancel() }
    private func readInput() {
        let data = FileHandle.standardInput.availableData
        guard !data.isEmpty, input.count + data.count <= 65536 else { stop(); return }
        input.append(data)
        while let newline = input.firstIndex(of: 10) {
            let line = input.prefix(upTo: newline); input.removeSubrange(...newline)
            guard let value = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
            if let token = value["grant"] as? String, token.utf8.count <= 128 { grants[token] = Date().addingTimeInterval(75) }
            if let token = value["revoke"] as? String { grants[token] = nil; for (id, peer) in clients where peer.token == token { remove(id) } }
            if let visible = value["enabled"] as? Bool { enabled = visible; forceKeyframe = true }
            if let width = value["width"] as? Int, let height = value["height"] as? Int, (2...4096).contains(width), (2...4096).contains(height) { requestedWidth = width; requestedHeight = height; forceKeyframe = true }
            if value["keyframe"] as? Bool == true { forceKeyframe = true }
            if let orientation = value["orientation"] as? String, ["portrait", "landscapeLeft", "landscapeRight", "portraitUpsideDown"].contains(orientation) { self.orientation = orientation; forceKeyframe = true }
            grants = grants.filter { $0.value > Date() }
        }
    }
    private func diagnostic(_ value: [String: Any]) { if let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) { FileHandle.standardError.write(data + Data([10])) } }
    private func stop() { timer?.cancel(); listener?.cancel(); for peer in clients.values { peer.connection.cancel() }; if let encoder { VTCompressionSessionInvalidate(encoder) }; exit(0) }
}
private extension Data {
    mutating func appendBE<T: FixedWidthInteger>(_ value: T) { var bytes = value.bigEndian; Swift.withUnsafeBytes(of: &bytes) { append(contentsOf: $0) } }
}
let arguments = CommandLine.arguments
guard arguments.count == 3, let id = UUID(uuidString: arguments[1]) else { exit(64) }
VideoHost(deviceID: id, developer: arguments[2]).run()
