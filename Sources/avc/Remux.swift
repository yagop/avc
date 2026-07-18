import ArgumentParser
import AVFoundation
import Foundation

struct Remux: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Combine tracks from multiple inputs without re-encoding.")

    @Option(name: .shortAndLong, help: "Input file (repeatable).") var input: [String]
    @Option(name: .shortAndLong, help: "Output file (.mov/.mp4/.m4v).") var output: String
    @Option(help: "Track mapping INDEX:v or INDEX:a (index = position of -i, 0-based). Default: first video + first audio found.")
    var map: [String] = []
    @Option(help: "mkvextract timestamps_v2 file for a raw .h264/.h265 input (one PTS in ms per frame).")
    var timestamps: String?
    @Flag(help: "Overwrite existing output file.") var replace = false
    @Flag(help: "Print per-track mapping decisions.") var verbose = false

    func run() async throws {
        try await exitOnMediaError { try await remux() }
    }

    func remux() async throws {
        guard !input.isEmpty else { throw ValidationError("at least one -i input required") }
        let fileType = try containerType(for: URL(fileURLWithPath: output))

        // parse --map into (inputIndex, mediaType)
        var wanted: [(index: Int, type: AVMediaType)] = []
        for m in map {
            let parts = m.split(separator: ":")
            guard parts.count == 2, let idx = Int(parts[0]), idx >= 0, idx < input.count,
                  let type: AVMediaType = parts[1] == "v" ? .video : parts[1] == "a" ? .audio : parts[1] == "s" ? .subtitle : nil
            else {
                throw ValidationError("invalid --map '\(m)' (use INDEX:v, INDEX:a or INDEX:s, index < \(input.count))")
            }
            wanted.append((idx, type))
        }

        // .srt and raw .h264/.h265 inputs are synthesized, not opened as assets
        let isSRT = input.map { $0.lowercased().hasSuffix(".srt") }
        let isRaw = input.map(isRawVideoPath)
        let rawPaths = input.indices.filter { isRaw[$0] }.map { input[$0] }
        guard rawPaths.count <= 1 else {
            throw ValidationError("at most one raw video input is supported")
        }
        if let raw = rawPaths.first, timestamps == nil {
            throw ValidationError("""
            raw stream \(raw) needs frame timing; extract it from the source container:
              mkvextract source.mkv timestamps_v2 TRACKID:ts.txt
            then pass --timestamps ts.txt
            """)
        }
        let assets = input.enumerated().map { i, path in
            isSRT[i] || isRaw[i] ? nil : AVURLAsset(url: URL(fileURLWithPath: path))
        }
        var selected: [(inputIndex: Int, track: AVAssetTrack)] = []
        var srtInputs: [Int] = []
        var rawInputs: [Int] = []
        if wanted.isEmpty {
            srtInputs = isSRT.indices.filter { isSRT[$0] }
            rawInputs = isRaw.indices.filter { isRaw[$0] }
            // first video track + first audio track across inputs, plus all subtitle tracks
            for type in [AVMediaType.video, .audio] {
                for (i, asset) in assets.enumerated() {
                    guard let asset else { continue }
                    let tracks = try await mediaOp("loading \(input[i])") {
                        try await asset.loadTracks(withMediaType: type)
                    }
                    if let track = tracks.first {
                        selected.append((i, track))
                        break
                    }
                }
            }
            for (i, asset) in assets.enumerated() {
                guard let asset else { continue }
                let subs = try await mediaOp("loading \(input[i])") {
                    try await asset.loadTracks(withMediaType: .subtitle)
                }
                selected.append(contentsOf: subs.map { (i, $0) })
            }
        } else {
            for (idx, type) in wanted {
                if isSRT[idx] {
                    guard type == .subtitle else {
                        throw ValidationError("--map \(idx):\(type == .video ? "v" : "a") is invalid; \(input[idx]) is a subtitle file")
                    }
                    srtInputs.append(idx)
                    continue
                }
                if isRaw[idx] {
                    guard type == .video else {
                        throw ValidationError("--map \(idx):\(type == .audio ? "a" : "s") is invalid; \(input[idx]) is a raw video stream")
                    }
                    rawInputs.append(idx)
                    continue
                }
                let tracks = try await mediaOp("loading \(input[idx])") {
                    try await assets[idx]!.loadTracks(withMediaType: type)
                }
                guard let track = tracks.first else {
                    throw MediaError("no \(type.rawValue) track in \(input[idx])")
                }
                selected.append((idx, track))
            }
        }
        guard !selected.isEmpty || !srtInputs.isEmpty || !rawInputs.isEmpty else {
            throw MediaError("no video or audio tracks found in inputs")
        }

        // all validation that can fail has run; only now is an existing output deleted
        let outURL = try prepareOutput(output, replace: replace)
        let writer = try mediaOp("creating writer for \(output)") {
            try AVAssetWriter(outputURL: outURL, fileType: fileType)
        }

        var pumps: [TrackFeed] = []
        var readers: [Int: AVAssetReader] = [:]
        for (i, track) in selected {
            let reader: AVAssetReader
            if let existing = readers[i] { reader = existing }
            else {
                reader = try mediaOp("creating reader for \(input[i])") { try AVAssetReader(asset: assets[i]!) }
                readers[i] = reader
            }
            let formats = try await mediaOp("reading format of \(input[i])") {
                try await track.load(.formatDescriptions)
            }
            let codec = formats.first.map { fourCC(CMFormatDescriptionGetMediaSubType($0)) } ?? "?"
            let trackOut = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
            reader.add(trackOut)
            let writerIn = AVAssetWriterInput(
                mediaType: track.mediaType, outputSettings: nil, sourceFormatHint: formats.first)
            writerIn.expectsMediaDataInRealTime = false
            guard writer.canAdd(writerIn) else {
                throw MediaError("cannot write \(track.mediaType.rawValue) track (codec \(codec)) from \(input[i]) into \(fileType.rawValue) container")
            }
            writer.add(writerIn)
            if verbose {
                print("map: \(input[i]) \(track.mediaType.rawValue) #\(track.trackID) (\(codec)) -> \(output) [passthrough]")
            }
            pumps.append(TrackFeed(out: trackOut, input: writerIn, reader: reader,
                                   label: "\(track.mediaType.rawValue) #\(i)"))
        }

        // synthesized tx3g tracks from .srt inputs
        var srtFeeds: [(samples: [CMSampleBuffer], in: AVAssetWriterInput, label: String)] = []
        for i in srtInputs {
            srtFeeds.append(try makeSRTFeed(path: input[i], writer: writer, fileType: fileType,
                                            label: "srt #\(i)", verbose: verbose))
        }
        var rawFeeds: [(stream: RawStream, in: AVAssetWriterInput, label: String)] = []
        for i in rawInputs {
            let raw = try RawStream(path: input[i], timestamps: parseTimestampsV2(timestamps!))
            let codec = fourCC(CMFormatDescriptionGetMediaSubType(raw.format))
            let writerIn = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: raw.format)
            writerIn.expectsMediaDataInRealTime = false
            guard writer.canAdd(writerIn) else {
                throw MediaError("cannot write video track (\(codec)) from \(input[i]) into \(fileType.rawValue) container")
            }
            writer.add(writerIn)
            if verbose {
                print("map: \(input[i]) \(raw.frameCount) frames (\(codec)) -> \(output) [raw annex-b]")
            }
            rawFeeds.append((raw, writerIn, "raw #\(i)"))
        }

        for (i, reader) in readers {
            guard reader.startReading() else {
                throw MediaError("starting reader for \(input[i])", underlying: reader.error)
            }
        }
        guard writer.startWriting() else {
            throw MediaError("starting writer", underlying: writer.error)
        }
        writer.startSession(atSourceTime: .zero)
        installSigintCleanup(writers: [writer], readers: Array(readers.values), url: outURL)

        try await withThrowingTaskGroup(of: Void.self) { group in
            for feed in pumps {
                group.addTask { try await pump(feed, writer: writer) }
            }
            for f in srtFeeds {
                group.addTask {
                    try await pumpSamples(f.samples, to: f.in, writer: writer, label: f.label)
                }
            }
            for f in rawFeeds {
                group.addTask { [stream = f.stream] in
                    try await pumpSamples(count: stream.frameCount, make: { try stream.makeSample($0) },
                                          to: f.in, writer: writer, label: f.label)
                }
            }
            try await group.waitForAll()
        }

        await writer.finishWriting()
        teardownSigintCleanup()
        if writer.status != .completed {
            throw MediaError("finalizing \(output)", underlying: writer.error)
        }
        print("wrote \(output)")
    }
}

// MARK: - SRT -> tx3g

/// A styled character range within a cue: offsets are characters (not bytes),
/// flags per 3GPP TS 26.245: bold 1, italic 2, underline 4.
struct StyleSpan: Equatable {
    let start: Int
    let end: Int
    let flags: UInt8
}

