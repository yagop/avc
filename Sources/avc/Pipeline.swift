// Shared machinery: pump loops, sample building, output preparation, SIGINT lifecycle.
import ArgumentParser
import AVFoundation
import Foundation

func printProgress(_ pts: Double, start: Double, total: Double, pass: Int = 0) {
    guard total > 0 else { return }
    let pct = min(100, (pts - start) / total * 100)
    let prefix = pass > 0 ? "pass \(pass) " : ""
    FileHandle.standardError.write(Data(String(format: "\r\(prefix)%3.0f%%", pct).utf8))
}

/// Multipass driver: pump the first pass from the shared reader, then re-read the
/// time ranges the encoder requests with fresh readers until it is satisfied.
func pumpMultiPass(
    firstPassOut: AVAssetReaderTrackOutput, input: AVAssetWriterInput, firstReader: AVAssetReader,
    asset: AVAsset, track: AVAssetTrack, readerSettings: [String: Any],
    writer: AVAssetWriter, total: Double, rangeStart: CMTime
) async throws {
    let passQueue = DispatchQueue(label: "avc.pass")
    // safe: the callback only runs on `passQueue`, which we own
    nonisolated(unsafe) let input = input
    let passes = AsyncStream<[CMTimeRange]> { cont in
        input.respondToEachPassDescription(on: passQueue) {
            if let desc = input.currentPassDescription {
                cont.yield(desc.sourceTimeRanges.map(\.timeRangeValue))
            } else {
                cont.finish()
            }
        }
    }
    var passNumber = 0
    for await ranges in passes {
        passNumber += 1
        if passNumber == 1 {
            try await pump(from: firstPassOut, to: input, reader: firstReader, writer: writer,
                           label: "video pass 1", finishInput: false) { pts in
                printProgress(pts, start: rangeStart.seconds, total: total, pass: 1)
            }
        } else {
            for range in ranges {
                let reader = try mediaOp("creating reader for pass \(passNumber)") { try AVAssetReader(asset: asset) }
                reader.timeRange = range
                let out = AVAssetReaderTrackOutput(track: track, outputSettings: readerSettings)
                reader.add(out)
                guard reader.startReading() else {
                    throw MediaError("starting reader for pass \(passNumber)", underlying: reader.error)
                }
                let pass = passNumber
                try await pump(from: out, to: input, reader: reader, writer: writer,
                               label: "video pass \(pass)", finishInput: false) { pts in
                    printProgress(pts, start: rangeStart.seconds, total: total, pass: pass)
                }
            }
        }
        input.markCurrentPassAsFinished()
    }
    input.markAsFinished()
}

/// A demuxed track routed to a writer input, with the reader that owns its output.
struct TrackFeed {
    let out: AVAssetReaderTrackOutput
    let input: AVAssetWriterInput
    let reader: AVAssetReader
    let label: String
}

/// Core pump loop shared by every feed variant: pull samples from `next` and append
/// them to `input` on a serial queue via requestMediaDataWhenReady. `next` returns nil
/// at end of stream and throws to abort (e.g. a failed reader). finishInput: false
/// leaves the input open (multipass calls markCurrentPassAsFinished itself).
func pumpCore(
    to input: AVAssetWriterInput, writer: AVAssetWriter, label: String,
    finishInput: Bool = true,
    progress: (@Sendable (Double) -> Void)? = nil,
    next: @escaping @Sendable () throws -> CMSampleBuffer?
) async throws {
    let queue = DispatchQueue(label: "avc.pump.\(label)")
    // safe: the callback only runs on `queue`, which we own (AVFoundation's intended pattern)
    nonisolated(unsafe) let input = input
    nonisolated(unsafe) let writer = writer
    try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
        nonisolated(unsafe) var done = false
        input.requestMediaDataWhenReady(on: queue) {
            guard !done else { return }
            while input.isReadyForMoreMediaData {
                let sample: CMSampleBuffer?
                do { sample = try next() } catch {
                    done = true
                    if finishInput { input.markAsFinished() }
                    cont.resume(throwing: error)
                    return
                }
                guard let sample else {
                    done = true
                    if finishInput { input.markAsFinished() }
                    cont.resume()
                    return
                }
                let pts = CMSampleBufferGetPresentationTimeStamp(sample)
                if !input.append(sample) {
                    done = true
                    input.markAsFinished()
                    cont.resume(throwing: MediaError(
                        "appending \(label) sample at \(fmt(pts))", underlying: writer.error))
                    return
                }
                progress?(pts.seconds)
            }
        }
    }
}

/// Pump one demuxed track: copyNextSampleBuffer → append.
func pump(
    from trackOut: AVAssetReaderTrackOutput, to input: AVAssetWriterInput,
    reader: AVAssetReader, writer: AVAssetWriter, label: String,
    finishInput: Bool = true,
    progress: (@Sendable (Double) -> Void)?
) async throws {
    nonisolated(unsafe) let trackOut = trackOut
    nonisolated(unsafe) let reader = reader
    nonisolated(unsafe) var lastPTS = CMTime.invalid
    try await pumpCore(to: input, writer: writer, label: label,
                       finishInput: finishInput, progress: progress) {
        if let sample = trackOut.copyNextSampleBuffer() {
            lastPTS = CMSampleBufferGetPresentationTimeStamp(sample)
            return sample
        }
        if reader.status == .failed {
            throw MediaError("reading \(label) sample after \(fmt(lastPTS))", underlying: reader.error)
        }
        return nil
    }
}

func pump(_ feed: TrackFeed, writer: AVAssetWriter) async throws {
    try await pump(from: feed.out, to: feed.input, reader: feed.reader,
                   writer: writer, label: feed.label, progress: nil)
}

/// Source color description; isHDR when the transfer function is PQ or HLG.
func colorInfo(_ fd: CMFormatDescription?) -> (avProperties: [String: String]?, transfer: String?, isHDR: Bool) {
    guard let fd else { return (nil, nil, false) }
    func ext(_ key: CFString) -> String? {
        CMFormatDescriptionGetExtension(fd, extensionKey: key) as? String
    }
    let primaries = ext(kCMFormatDescriptionExtension_ColorPrimaries)
    let transfer = ext(kCMFormatDescriptionExtension_TransferFunction)
    let matrix = ext(kCMFormatDescriptionExtension_YCbCrMatrix)
    guard let primaries, let transfer, let matrix else { return (nil, transfer, false) }
    let hdr = transfer == (kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ as String)
        || transfer == (kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG as String)
    // CM extension values are the same strings AVVideoSettings expects
    return ([
        AVVideoColorPrimariesKey: primaries,
        AVVideoTransferFunctionKey: transfer,
        AVVideoYCbCrMatrixKey: matrix,
    ], transfer, hdr)
}

/// Feed pre-built samples into a writer input (same contract as pump, but from an array).
func pumpSamples(_ samples: [CMSampleBuffer], to input: AVAssetWriterInput, writer: AVAssetWriter, label: String) async throws {
    // safe: the closure only runs on the pump's serial queue
    nonisolated(unsafe) let samples = samples
    try await pumpSamples(count: samples.count, make: { samples[$0] }, to: input, writer: writer, label: label)
}

/// Feed lazily-built samples: `make` runs one sample at a time on the pump queue,
/// so peak memory stays at one sample regardless of stream size.
func pumpSamples(count: Int, make: @escaping @Sendable (Int) throws -> CMSampleBuffer,
                 to input: AVAssetWriterInput, writer: AVAssetWriter, label: String) async throws {
    nonisolated(unsafe) var index = 0
    try await pumpCore(to: input, writer: writer, label: label) {
        guard index < count else { return nil }
        defer { index += 1 }
        return try make(index)
    }
}

func makeSampleBuffer(_ payload: Data, format: CMFormatDescription, timing: CMSampleTimingInfo,
                      sync: Bool, what: String) throws -> CMSampleBuffer {
    var block: CMBlockBuffer?
    var status = CMBlockBufferCreateWithMemoryBlock(
        allocator: nil, memoryBlock: nil, blockLength: payload.count, blockAllocator: nil,
        customBlockSource: nil, offsetToData: 0, dataLength: payload.count,
        flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block)
    if status == noErr {
        status = payload.withUnsafeBytes {
            CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block!, offsetIntoDestination: 0, dataLength: payload.count)
        }
    }
    var timing = timing
    var size = payload.count
    var sample: CMSampleBuffer?
    if status == noErr {
        status = CMSampleBufferCreateReady(
            allocator: nil, dataBuffer: block!, formatDescription: format,
            sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample)
    }
    guard status == noErr, let sample else {
        throw MediaError("creating \(what)", underlying: NSError(domain: NSOSStatusErrorDomain, code: Int(status)))
    }
    if !sync, let atts = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true) as? [CFMutableDictionary], let d = atts.first {
        CFDictionarySetValue(d, Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque(), Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
    }
    return sample
}


func parseBitrate(_ s: String) throws -> Int {
    let lower = s.lowercased()
    let multiplier: Int
    let digits: Substring
    if lower.hasSuffix("m") { multiplier = 1_000_000; digits = lower.dropLast() }
    else if lower.hasSuffix("k") { multiplier = 1_000; digits = lower.dropLast() }
    else { multiplier = 1; digits = lower[...] }
    guard let value = Double(digits), value > 0 else {
        throw ValidationError("invalid bitrate '\(s)' (use e.g. 8M, 8000k, 8000000)")
    }
    let bps = value * Double(multiplier)
    guard bps >= 1000, bps <= 2_000_000_000 else {
        throw ValidationError("bitrate '\(s)' out of range (1k to 2G bits/s)")
    }
    return Int(bps)
}

func containerType(for url: URL) throws -> AVFileType {
    switch url.pathExtension.lowercased() {
    case "mov": return .mov
    case "mp4", "m4v": return .mp4
    default:
        throw ValidationError("unknown output extension '.\(url.pathExtension)' (supported: .mov, .mp4, .m4v)")
    }
}

func prepareOutput(_ path: String, replace: Bool) throws -> URL {
    let url = URL(fileURLWithPath: path)
    var isDir: ObjCBool = false
    if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) {
        guard !isDir.boolValue else {
            throw ValidationError("output \(path) is a directory")
        }
        guard replace else {
            throw ValidationError("output \(path) exists; pass --replace to overwrite")
        }
        try FileManager.default.removeItem(at: url)
    }
    return url
}

func prepareHLSDir(_ url: URL, replace: Bool) throws {
    var isDir: ObjCBool = false
    if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) {
        guard replace else {
            throw ValidationError("output \(url.path) exists; pass --replace to overwrite")
        }
        try FileManager.default.removeItem(at: url)
    }
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
}

/// Clamp requested dimensions to source (never upscale), preserving aspect when one dimension given.
func clampSize(_ source: CGSize, width: Int?, height: Int?) -> CGSize {
    var w = Double(width ?? Int(source.width))
    var h = Double(height ?? Int(source.height))
    if width != nil && height == nil { h = (source.height * w / source.width).rounded() }
    if height != nil && width == nil { w = (source.width * h / source.height).rounded() }
    if w > source.width || h > source.height {
        let scale = min(source.width / w, source.height / h)
        w = (w * scale).rounded(); h = (h * scale).rounded()
    }
    // even dimensions required by most encoders
    return CGSize(width: w - w.truncatingRemainder(dividingBy: 2), height: h - h.truncatingRemainder(dividingBy: 2))
}

func installSigintCleanup(writers: [AVAssetWriter], readers: [AVAssetReader], url: URL, tempDir: URL? = nil) {
    signal(SIGINT, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
    source.setEventHandler {
        readers.forEach { $0.cancelReading() }
        writers.forEach { $0.cancelWriting() }
        try? FileManager.default.removeItem(at: url)
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
        FileHandle.standardError.write(Data("\ninterrupted: cancelled writing, removed partial \(url.path)\n".utf8))
        Foundation.exit(2)
    }
    source.resume()
    sigintSource = source
}

nonisolated(unsafe) var sigintSource: DispatchSourceSignal?

/// After finishWriting succeeds the output is complete; a late Ctrl-C must not delete it.
func teardownSigintCleanup() {
    sigintSource?.cancel()
    sigintSource = nil
    signal(SIGINT, SIG_DFL)
}
