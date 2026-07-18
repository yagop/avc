import ArgumentParser
import AVFoundation
import UniformTypeIdentifiers
import VideoToolbox

struct Encode: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Re-encode video with explicit settings.")

    @Option(name: .shortAndLong, help: "Input file (repeatable; video is taken from the first input that has it, audio likewise, subtitles from all).") var input: [String]
    @Option(name: .shortAndLong, help: "Output file (.mov/.mp4/.m4v), or directory with --hls.") var output: String
    @Option(help: "Video codec: hevc or h264.") var codec: String = "hevc"
    @Option(help: "Video bitrate, e.g. 8M, 8000k, 8000000.") var bitrate: String?
    @Option(help: "Constant quality 0.0-1.0 instead of a bitrate (Apple Silicon HEVC/H.264).") var quality: Double?
    @Option(help: "Output width (never upscaled past source).") var width: Int?
    @Option(help: "Output height (never upscaled past source).") var height: Int?
    @Option(help: "Max keyframe interval in frames.") var keyframeInterval: Int?
    @Option(help: "Peak bitrate cap (VBV over 1s window), e.g. 22M.") var maxBitrate: String?
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
        switch (bitrate, quality) {
        case (nil, nil): throw ValidationError("one of --bitrate or --quality is required")
        case (.some, .some): throw ValidationError("--bitrate and --quality are mutually exclusive")
        default: break
        }
        if let quality, !(0.0...1.0).contains(quality) {
            throw ValidationError("--quality must be between 0.0 and 1.0")
        }
        if quality != nil, maxBitrate != nil {
            throw ValidationError("--max-bitrate requires --bitrate (rate control), not --quality")
        }
        if quality != nil, multiPass {
            // VT multipass ignores AVVideoQualityKey and produces bloated output
            throw ValidationError("--multi-pass requires --bitrate; constant quality is single-pass by nature")
        }
        let videoBitrate = try bitrate.map(parseBitrate)
        // fMP4 segment output rejects passthrough audio, so HLS always re-encodes it
        let audioBps = try audioBitrate.map(parseBitrate) ?? (hls ? 128_000 : nil)
        if let width, width <= 0 { throw ValidationError("--width must be positive") }
        if let height, height <= 0 { throw ValidationError("--height must be positive") }
        if let start, start < 0 { throw ValidationError("--start must be >= 0") }
        if let duration, duration <= 0 { throw ValidationError("--duration must be positive") }
        if hls, segmentDuration <= 0 { throw ValidationError("--segment-duration must be positive") }
        // validate the output extension before anything touches the filesystem
        let fileType: AVFileType = hls ? .mp4 : try containerType(for: URL(fileURLWithPath: output))

        guard !input.isEmpty else { throw ValidationError("at least one -i input required") }
        // .srt inputs are parsed and synthesized into tx3g tracks, not opened as assets
        let srt = input.filter { $0.lowercased().hasSuffix(".srt") }
        if !srt.isEmpty && hls {
            throw ValidationError(".srt inputs cannot be combined with --hls (fMP4 segments do not carry tx3g)")
        }
        let assets = input.compactMap { path in
            path.lowercased().hasSuffix(".srt") ? nil : AVURLAsset(url: URL(fileURLWithPath: path))
        }
        let input = input.filter { !$0.lowercased().hasSuffix(".srt") }
        var videoPick: (index: Int, track: AVAssetTrack)?
        var audioPick: (index: Int, track: AVAssetTrack)?
        var subtitlePicks: [(index: Int, track: AVAssetTrack)] = []
        for (i, asset) in assets.enumerated() {
            let (v, a, s) = try await mediaOp("loading input \(input[i])") {
                (try await asset.loadTracks(withMediaType: .video),
                 try await asset.loadTracks(withMediaType: .audio),
                 try await asset.loadTracks(withMediaType: .subtitle))
            }
            if videoPick == nil, let track = v.first { videoPick = (i, track) }
            if audioPick == nil, let track = a.first { audioPick = (i, track) }
            subtitlePicks.append(contentsOf: s.map { (i, $0) })
        }
        guard let (videoIndex, videoTrack) = videoPick else {
            throw MediaError("no video track in inputs")
        }
        let asset = assets[videoIndex]
        let assetDuration = try await mediaOp("loading duration of \(input[videoIndex])") {
            try await asset.load(.duration)
        }

        // one reader per used input; all share the same trim range
        let timeRange: CMTimeRange? = (start != nil || duration != nil)
            ? CMTimeRange(start: CMTime(seconds: start ?? 0, preferredTimescale: 600),
                          duration: duration.map { CMTime(seconds: $0, preferredTimescale: 600) } ?? .positiveInfinity)
            : nil
        var readers: [Int: AVAssetReader] = [:]
        func readerFor(_ i: Int) throws -> AVAssetReader {
            if let existing = readers[i] { return existing }
            let r = try mediaOp("creating reader for \(input[i])") { try AVAssetReader(asset: assets[i]) }
            if let timeRange { r.timeRange = timeRange }
            readers[i] = r
            return r
        }
        if let start, start >= assetDuration.seconds {
            throw MediaError("--start \(start)s is beyond the end of \(input[videoIndex]) (\(fmt(assetDuration)))")
        }
        let reader = try readerFor(videoIndex)
        var readDuration = assetDuration
        if let timeRange {
            readDuration = min(timeRange.duration, assetDuration - timeRange.start)
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

        var compression: [String: Any] = [:]
        if let videoBitrate { compression[AVVideoAverageBitRateKey] = videoBitrate }
        if let quality { compression[AVVideoQualityKey] = quality }
        if let keyframeInterval { compression[AVVideoMaxKeyFrameIntervalKey] = keyframeInterval }
        if let maxBitrate {
            let bps = try parseBitrate(maxBitrate)
            guard bps >= videoBitrate! else {
                throw ValidationError("--max-bitrate (\(maxBitrate)) must be >= --bitrate (\(bitrate!))")
            }
            // undocumented but accepted by AVAssetWriter: [bytes, seconds] VBV window
            compression[kVTCompressionPropertyKey_DataRateLimits as String] = [bps / 8, 1]
        }
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

        // writer: plain file, or segment-emitting for HLS. All validation that can fail
        // has run; only now is an existing output deleted (--replace).
        let outURL: URL
        var segmentSink: SegmentSink?
        let writer: AVAssetWriter
        if hls {
            outURL = URL(fileURLWithPath: output, isDirectory: true)
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
            writer = try mediaOp("creating writer for \(output)") {
                try AVAssetWriter(outputURL: outURL, fileType: fileType)
            }
        }

        // multipass temp storage (*.sb-*) otherwise lands next to the output and is not cleaned up
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("avc-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
        if !hls {
            try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
            writer.directoryForTemporaryFiles = tempDir
        }
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let videoIn = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoIn.expectsMediaDataInRealTime = false
        if multiPass { videoIn.performsMultiPassEncodingIfSupported = true }
        writer.add(videoIn)
        if verbose {
            let rate = videoBitrate.map { "\($0) b/s" } ?? "quality \(quality!)"
            print("video: \(codec) \(Int(outSize.width))x\(Int(outSize.height)) @ \(rate)"
                + (keyframeInterval.map { " keyframe-interval \($0)" } ?? "")
                + " (source \(Int(sourceSize.width))x\(Int(sourceSize.height)))")
            if let props = color.avProperties {
                print("color: \(props[AVVideoColorPrimariesKey] ?? "?") / \(props[AVVideoTransferFunctionKey] ?? "?")"
                    + (color.isHDR ? " [HDR, 10-bit Main10]" : ""))
            }
            print("audio: \(audioPick == nil ? "none" : "\(input[audioPick!.index]) " + (audioBps.map { "aac @ \($0) b/s" } ?? "passthrough"))")
            print(hls ? "container: fragmented mp4 + HLS playlist, \(segmentDuration)s segments" : "container: \(fileType.rawValue)")
        }

        var passthroughPairs: [(out: AVAssetReaderTrackOutput, in: AVAssetWriterInput, reader: AVAssetReader, label: String)] = []
        if let (audioIndex, audioTrack) = audioPick {
            let audioReader = try readerFor(audioIndex)
            let audioFormats = try await mediaOp("reading audio format") {
                try await audioTrack.load(.formatDescriptions)
            }
            let audioOut = AVAssetReaderTrackOutput(
                track: audioTrack,
                outputSettings: audioBps == nil ? nil : [AVFormatIDKey: kAudioFormatLinearPCM])
            audioReader.add(audioOut)
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
            passthroughPairs.append((audioOut, audioIn, audioReader, "audio"))
        }
        for (n, (subIndex, track)) in subtitlePicks.enumerated() where !hls {
            let formats = try await mediaOp("reading subtitle format") { try await track.load(.formatDescriptions) }
            let subOut = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
            let subIn = AVAssetWriterInput(mediaType: .subtitle, outputSettings: nil, sourceFormatHint: formats.first)
            subIn.expectsMediaDataInRealTime = false
            guard writer.canAdd(subIn) else {
                let codec = formats.first.map { fourCC(CMFormatDescriptionGetMediaSubType($0)) } ?? "?"
                if verbose { print("subtitle track #\(track.trackID) (\(codec)): not writable to \(fileType.rawValue), dropped") }
                continue
            }
            let subReader = try readerFor(subIndex)
            subReader.add(subOut)
            writer.add(subIn)
            passthroughPairs.append((subOut, subIn, subReader, "subtitle #\(n)"))
            if verbose { print("subtitle track #\(track.trackID) (\(input[subIndex])): passthrough") }
        }
        var srtFeeds: [(samples: [CMSampleBuffer], in: AVAssetWriterInput, label: String)] = []
        for (n, path) in srt.enumerated() {
            let text = try mediaOp("reading \(path)") { try String(contentsOfFile: path, encoding: .utf8) }
            let cues = try parseSRT(text, file: path)
            let fd = try tx3gFormatDescription()
            let subIn = AVAssetWriterInput(mediaType: .subtitle, outputSettings: nil, sourceFormatHint: fd)
            subIn.expectsMediaDataInRealTime = false
            guard writer.canAdd(subIn) else {
                throw MediaError("cannot write subtitle track (tx3g) from \(path) into \(fileType.rawValue) container")
            }
            writer.add(subIn)
            if verbose { print("subtitles: \(path) \(cues.count) cues [srt -> tx3g]") }
            srtFeeds.append((try tx3gSamples(cues, format: fd), subIn, "srt #\(n)"))
        }

        for (i, r) in readers {
            guard r.startReading() else {
                throw MediaError("starting reader for \(input[i])", underlying: r.error)
            }
        }
        guard writer.startWriting() else {
            throw MediaError("starting writer", underlying: writer.error)
        }
        writer.startSession(atSourceTime: reader.timeRange.start)

        installSigintCleanup(writers: [writer], readers: Array(readers.values), url: outURL, tempDir: tempDir)

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
                    try await pump(from: pair.out, to: pair.in, reader: pair.reader, writer: writer, label: pair.label, progress: nil)
                }
            }
            for feed in srtFeeds {
                group.addTask {
                    try await pumpSamples(feed.samples, to: feed.in, writer: writer, label: feed.label)
                }
            }
            try await group.waitForAll()
        }
        FileHandle.standardError.write(Data("\r".utf8))

        await writer.finishWriting()
        teardownSigintCleanup()
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

/// Pump one track: copyNextSampleBuffer → append, on a serial queue via requestMediaDataWhenReady.
/// finishInput: false leaves the input open (multipass calls markCurrentPassAsFinished itself).
func pump(
    from trackOut: AVAssetReaderTrackOutput, to input: AVAssetWriterInput,
    reader: AVAssetReader, writer: AVAssetWriter, label: String,
    finishInput: Bool = true,
    progress: (@Sendable (Double) -> Void)?
) async throws {
    let queue = DispatchQueue(label: "avc.pump.\(label)")
    // safe: the callback only runs on `queue`, which we own (AVFoundation's intended pattern)
    nonisolated(unsafe) let input = input
    nonisolated(unsafe) let trackOut = trackOut
    nonisolated(unsafe) let reader = reader
    nonisolated(unsafe) let writer = writer
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
