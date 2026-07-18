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

    /// First input with a video track supplies the video, first with audio the audio;
    /// subtitle tracks come from all inputs.
    private func pickTracks(_ assets: [AVURLAsset], paths: [String]) async throws
        -> (video: (Int, AVAssetTrack), audio: (Int, AVAssetTrack)?, subtitles: [(Int, AVAssetTrack)]) {
        var video: (Int, AVAssetTrack)?
        var audio: (Int, AVAssetTrack)?
        var subtitles: [(Int, AVAssetTrack)] = []
        for (i, asset) in assets.enumerated() {
            let (v, a, s) = try await mediaOp("loading input \(paths[i])") {
                (try await asset.loadTracks(withMediaType: .video),
                 try await asset.loadTracks(withMediaType: .audio),
                 try await asset.loadTracks(withMediaType: .subtitle))
            }
            if video == nil, let track = v.first { video = (i, track) }
            if audio == nil, let track = a.first { audio = (i, track) }
            subtitles.append(contentsOf: s.map { (i, $0) })
        }
        guard let video else { throw MediaError("no video track in inputs") }
        return (video, audio, subtitles)
    }

    /// Audio passes through untouched unless audioBps is set (re-encode to AAC).
    private func makeAudioFeed(track: AVAssetTrack, reader: AVAssetReader,
                               writer: AVAssetWriter, audioBps: Int?) async throws -> TrackFeed {
        let formats = try await mediaOp("reading audio format") {
            try await track.load(.formatDescriptions)
        }
        let out = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: audioBps == nil ? nil : [AVFormatIDKey: kAudioFormatLinearPCM])
        reader.add(out)
        let input = AVAssetWriterInput(
            mediaType: .audio,
            outputSettings: audioBps.map { [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVEncoderBitRateKey: $0,
                AVSampleRateKey: 44100,
                AVNumberOfChannelsKey: 2,
            ] },
            sourceFormatHint: audioBps == nil ? formats.first : nil)
        input.expectsMediaDataInRealTime = false
        writer.add(input)
        return TrackFeed(out: out, input: input, reader: reader, label: "audio")
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
        let picks = try await pickTracks(assets, paths: input)
        let (videoIndex, videoTrack) = picks.video
        let audioPick = picks.audio
        let subtitlePicks = picks.subtitles
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
            print("audio: \(audioPick == nil ? "none" : "\(input[audioPick!.0]) " + (audioBps.map { "aac @ \($0) b/s" } ?? "passthrough"))")
            print(hls ? "container: fragmented mp4 + HLS playlist, \(segmentDuration)s segments" : "container: \(fileType.rawValue)")
        }

        var passthroughFeeds: [TrackFeed] = []
        if let (audioIndex, audioTrack) = audioPick {
            passthroughFeeds.append(try await makeAudioFeed(
                track: audioTrack, reader: readerFor(audioIndex), writer: writer, audioBps: audioBps))
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
            passthroughFeeds.append(TrackFeed(out: subOut, input: subIn, reader: subReader, label: "subtitle #\(n)"))
            if verbose { print("subtitle track #\(track.trackID) (\(input[subIndex])): passthrough") }
        }
        var srtFeeds: [(samples: [CMSampleBuffer], in: AVAssetWriterInput, label: String)] = []
        for (n, path) in srt.enumerated() {
            srtFeeds.append(try makeSRTFeed(path: path, writer: writer, fileType: fileType,
                                            label: "srt #\(n)", verbose: verbose))
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
            for feed in passthroughFeeds {
                group.addTask { try await pump(feed, writer: writer) }
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

