import ArgumentParser
import AVFoundation
import UniformTypeIdentifiers
import VideoToolbox

struct Encode: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Re-encode video with explicit settings.")

    @Option(name: .shortAndLong, help: "Input file.") var input: String
    @Option(name: .shortAndLong, help: "Output file (.mov/.mp4/.m4v), or directory with --hls.") var output: String
    @Option(help: "Video codec: hevc or h264.") var codec: String = "hevc"
    @Option(help: "Video bitrate, e.g. 8M, 8000k, 8000000.") var bitrate: String
    @Option(help: "Output width (never upscaled past source).") var width: Int?
    @Option(help: "Output height (never upscaled past source).") var height: Int?
    @Option(help: "Max keyframe interval in frames.") var keyframeInterval: Int?
    @Option(help: "Re-encode audio to AAC at this bitrate (default: passthrough).") var audioBitrate: String?
    @Option(help: "Start time in seconds.") var start: Double?
    @Option(help: "Duration in seconds.") var duration: Double?
    @Flag(help: "Multipass encoding when the encoder supports it (falls back to single pass).") var multiPass = false
    @Flag(help: "Write fragmented MP4 segments + HLS playlist into the output directory.") var hls = false
    @Option(help: "HLS segment duration in seconds.") var segmentDuration: Double = 6
    @Flag(help: "Overwrite existing output file.") var replace = false
    @Flag(help: "Print chosen writer settings and mapping decisions.") var verbose = false

    func run() async throws {
        try await exitOnMediaError { try await encode() }
    }

    func encode() async throws {
        let videoCodec: AVVideoCodecType
        switch codec {
        case "hevc": videoCodec = .hevc
        case "h264": videoCodec = .h264
        default: throw ValidationError("unsupported codec '\(codec)' (use hevc or h264)")
        }
        if hls && multiPass {
            throw ValidationError("--multi-pass cannot be combined with --hls")
        }
        let videoBitrate = try parseBitrate(bitrate)
        // fMP4 segment output rejects passthrough audio, so HLS always re-encodes it
        let audioBps = try audioBitrate.map(parseBitrate) ?? (hls ? 128_000 : nil)

        let asset = AVURLAsset(url: URL(fileURLWithPath: input))
        let (assetDuration, videoTracks, audioTracks, subtitleTracks) = try await mediaOp("loading input \(input)") {
            (try await asset.load(.duration),
             try await asset.loadTracks(withMediaType: .video),
             try await asset.loadTracks(withMediaType: .audio),
             try await asset.loadTracks(withMediaType: .subtitle))
        }
        guard let videoTrack = videoTracks.first else {
            throw MediaError("no video track in \(input)")
        }

        let reader = try mediaOp("creating reader for \(input)") { try AVAssetReader(asset: asset) }
        var readDuration = assetDuration
        if start != nil || duration != nil {
            let s = CMTime(seconds: start ?? 0, preferredTimescale: 600)
            let d = duration.map { CMTime(seconds: $0, preferredTimescale: 600) } ?? .positiveInfinity
            reader.timeRange = CMTimeRange(start: s, duration: d)
            readDuration = min(d, assetDuration - s)
        }

        let (sourceSize, videoFormats) = try await mediaOp("reading video format") {
            (try await videoTrack.load(.naturalSize), try await videoTrack.load(.formatDescriptions))
        }
        let outSize = clampSize(sourceSize, width: width, height: height)
        let color = colorInfo(videoFormats.first)
        if color.isHDR && videoCodec != .hevc {
            throw ValidationError("source is HDR (\(color.transfer ?? "?")); h264 cannot carry it, use --codec hevc")
        }

        let pixelFormat = color.isHDR
            ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
            : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        let videoReaderSettings = [kCVPixelBufferPixelFormatTypeKey as String: pixelFormat]
        let videoOut = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: videoReaderSettings)
        reader.add(videoOut)

        var compression: [String: Any] = [AVVideoAverageBitRateKey: videoBitrate]
        if let keyframeInterval { compression[AVVideoMaxKeyFrameIntervalKey] = keyframeInterval }
        if color.isHDR {
            compression[AVVideoProfileLevelKey] = kVTProfileLevel_HEVC_Main10_AutoLevel as String
        }
        var videoSettings: [String: Any] = [
            AVVideoCodecKey: videoCodec,
            AVVideoWidthKey: Int(outSize.width),
            AVVideoHeightKey: Int(outSize.height),
            AVVideoCompressionPropertiesKey: compression,
        ]
        if let props = color.avProperties { videoSettings[AVVideoColorPropertiesKey] = props }

        // writer: plain file, or segment-emitting for HLS
        let outURL: URL
        let fileType: AVFileType
        var segmentSink: SegmentSink?
        let writer: AVAssetWriter
        if hls {
            outURL = URL(fileURLWithPath: output, isDirectory: true)
            fileType = .mp4
            try prepareHLSDir(outURL, replace: replace)
            writer = AVAssetWriter(contentType: UTType(AVFileType.mp4.rawValue)!)
            writer.outputFileTypeProfile = .mpeg4AppleHLS
            writer.preferredOutputSegmentInterval = CMTime(seconds: segmentDuration, preferredTimescale: 600)
            writer.initialSegmentStartTime = reader.timeRange.start
            let sink = SegmentSink(directory: outURL, targetDuration: segmentDuration)
            writer.delegate = sink
            segmentSink = sink
        } else {
            outURL = try prepareOutput(output, replace: replace)
            fileType = try containerType(for: outURL)
            writer = try mediaOp("creating writer for \(output)") {
                try AVAssetWriter(outputURL: outURL, fileType: fileType)
            }
        }

        let videoIn = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoIn.expectsMediaDataInRealTime = false
        if multiPass { videoIn.performsMultiPassEncodingIfSupported = true }
        writer.add(videoIn)
        if verbose {
            print("video: \(codec) \(Int(outSize.width))x\(Int(outSize.height)) @ \(videoBitrate) b/s"
                + (keyframeInterval.map { " keyframe-interval \($0)" } ?? "")
                + " (source \(Int(sourceSize.width))x\(Int(sourceSize.height)))")
            if let props = color.avProperties {
                print("color: \(props[AVVideoColorPrimariesKey] ?? "?") / \(props[AVVideoTransferFunctionKey] ?? "?")"
                    + (color.isHDR ? " [HDR, 10-bit Main10]" : ""))
            }
            print("audio: \(audioTracks.isEmpty ? "none" : audioBps.map { "aac @ \($0) b/s" } ?? "passthrough")")
            print(hls ? "container: fragmented mp4 + HLS playlist, \(segmentDuration)s segments" : "container: \(fileType.rawValue)")
        }

        var passthroughPairs: [(out: AVAssetReaderTrackOutput, in: AVAssetWriterInput, label: String)] = []
        if let audioTrack = audioTracks.first {
            let audioFormats = try await mediaOp("reading audio format") {
                try await audioTrack.load(.formatDescriptions)
            }
            let audioOut = AVAssetReaderTrackOutput(
                track: audioTrack,
                outputSettings: audioBps == nil ? nil : [AVFormatIDKey: kAudioFormatLinearPCM])
            reader.add(audioOut)
            let audioIn = AVAssetWriterInput(
                mediaType: .audio,
                outputSettings: audioBps.map { [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVEncoderBitRateKey: $0,
                    AVSampleRateKey: 44100,
                    AVNumberOfChannelsKey: 2,
                ] },
                sourceFormatHint: audioBps == nil ? audioFormats.first : nil)
            audioIn.expectsMediaDataInRealTime = false
            writer.add(audioIn)
            passthroughPairs.append((audioOut, audioIn, "audio"))
        }
        for (n, track) in subtitleTracks.enumerated() where !hls {
            let formats = try await mediaOp("reading subtitle format") { try await track.load(.formatDescriptions) }
            let subOut = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
            let subIn = AVAssetWriterInput(mediaType: .subtitle, outputSettings: nil, sourceFormatHint: formats.first)
            subIn.expectsMediaDataInRealTime = false
            guard writer.canAdd(subIn) else {
                let codec = formats.first.map { fourCC(CMFormatDescriptionGetMediaSubType($0)) } ?? "?"
                if verbose { print("subtitle track #\(track.trackID) (\(codec)): not writable to \(fileType.rawValue), dropped") }
                continue
            }
            reader.add(subOut)
            writer.add(subIn)
            passthroughPairs.append((subOut, subIn, "subtitle #\(n)"))
            if verbose { print("subtitle track #\(track.trackID): passthrough") }
        }

        guard reader.startReading() else {
            throw MediaError("starting reader", underlying: reader.error)
        }
        guard writer.startWriting() else {
            throw MediaError("starting writer", underlying: writer.error)
        }
        writer.startSession(atSourceTime: reader.timeRange.start)

        installSigintCleanup(writers: [writer], readers: [reader], url: outURL)

        let total = readDuration.seconds
        let timeRangeStart = reader.timeRange.start
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { [videoReaderSettings] in
                if videoIn.canPerformMultiplePasses {
                    try await pumpMultiPass(
                        firstPassOut: videoOut, input: videoIn, firstReader: reader,
                        asset: asset, track: videoTrack, readerSettings: videoReaderSettings,
                        writer: writer, total: total, rangeStart: timeRangeStart)
                } else {
                    try await pump(from: videoOut, to: videoIn, reader: reader, writer: writer, label: "video") { pts in
                        printProgress(pts, start: timeRangeStart.seconds, total: total)
                    }
                }
            }
            for pair in passthroughPairs {
                group.addTask {
                    try await pump(from: pair.out, to: pair.in, reader: reader, writer: writer, label: pair.label, progress: nil)
                }
            }
            try await group.waitForAll()
        }
        FileHandle.standardError.write(Data("\r".utf8))

        await writer.finishWriting()
        if writer.status != .completed {
            throw MediaError("finalizing \(output)", underlying: writer.error)
        }
        try segmentSink?.writePlaylist()
        print("wrote \(output)")
    }
}

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

/// Pump one track: copyNextSampleBuffer → append, on a serial queue via requestMediaDataWhenReady.
/// finishInput: false leaves the input open (multipass calls markCurrentPassAsFinished itself).
func pump(
    from trackOut: AVAssetReaderTrackOutput, to input: AVAssetWriterInput,
    reader: AVAssetReader, writer: AVAssetWriter, label: String,
    finishInput: Bool = true,
    progress: (@Sendable (Double) -> Void)?
) async throws {
    let queue = DispatchQueue(label: "avc.pump.\(label)")
    try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
        nonisolated(unsafe) var lastPTS = CMTime.invalid
        nonisolated(unsafe) var done = false
        input.requestMediaDataWhenReady(on: queue) {
            guard !done else { return }
            while input.isReadyForMoreMediaData {
                guard let sample = trackOut.copyNextSampleBuffer() else {
                    done = true
                    if finishInput { input.markAsFinished() }
                    if reader.status == .failed {
                        cont.resume(throwing: MediaError(
                            "reading \(label) sample after \(fmt(lastPTS))", underlying: reader.error))
                    } else {
                        cont.resume()
                    }
                    return
                }
                lastPTS = CMSampleBufferGetPresentationTimeStamp(sample)
                if !input.append(sample) {
                    done = true
                    input.markAsFinished()
                    reader.cancelReading()
                    cont.resume(throwing: MediaError(
                        "appending \(label) sample at \(fmt(lastPTS))", underlying: writer.error))
                    return
                }
                progress?(lastPTS.seconds)
            }
        }
    }
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

/// Receives fMP4 segment data from AVAssetWriter, writes init.mp4 / segN.m4s, builds index.m3u8.
final class SegmentSink: NSObject, AVAssetWriterDelegate {
    let directory: URL
    let targetDuration: Double
    private var segmentIndex = 0
    private var entries: [(file: String, duration: Double)] = []

    init(directory: URL, targetDuration: Double) {
        self.directory = directory
        self.targetDuration = targetDuration
    }

    func assetWriter(
        _ writer: AVAssetWriter, didOutputSegmentData segmentData: Data,
        segmentType: AVAssetSegmentType, segmentReport: AVAssetSegmentReport?
    ) {
        let name: String
        switch segmentType {
        case .initialization:
            name = "init.mp4"
        case .separable:
            name = "seg\(segmentIndex).m4s"
            let duration = segmentReport?.trackReports.map(\.duration.seconds).max() ?? targetDuration
            entries.append((name, duration))
            segmentIndex += 1
        @unknown default:
            return
        }
        try? segmentData.write(to: directory.appendingPathComponent(name))
    }

    func writePlaylist() throws {
        var lines = [
            "#EXTM3U",
            "#EXT-X-VERSION:7",
            "#EXT-X-TARGETDURATION:\(Int(entries.map(\.duration).max().map { $0.rounded(.up) } ?? targetDuration))",
            "#EXT-X-MEDIA-SEQUENCE:0",
            "#EXT-X-PLAYLIST-TYPE:VOD",
            "#EXT-X-MAP:URI=\"init.mp4\"",
        ]
        for entry in entries {
            lines.append(String(format: "#EXTINF:%.5f,", entry.duration))
            lines.append(entry.file)
        }
        lines.append("#EXT-X-ENDLIST")
        try lines.joined(separator: "\n").appending("\n")
            .write(to: directory.appendingPathComponent("index.m3u8"), atomically: true, encoding: .utf8)
    }
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
    return Int(value * Double(multiplier))
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
    if FileManager.default.fileExists(atPath: url.path) {
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

func installSigintCleanup(writers: [AVAssetWriter], readers: [AVAssetReader], url: URL) {
    signal(SIGINT, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
    source.setEventHandler {
        readers.forEach { $0.cancelReading() }
        writers.forEach { $0.cancelWriting() }
        try? FileManager.default.removeItem(at: url)
        FileHandle.standardError.write(Data("\ninterrupted: cancelled writing, removed partial \(url.path)\n".utf8))
        Foundation.exit(2)
    }
    source.resume()
    sigintSource = source
}

nonisolated(unsafe) var sigintSource: DispatchSourceSignal?
