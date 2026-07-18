import ArgumentParser
import AVFoundation
import Foundation

struct Remux: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Combine tracks from multiple inputs without re-encoding.")

    @Option(name: .shortAndLong, help: "Input file (repeatable).") var input: [String]
    @Option(name: .shortAndLong, help: "Output file (.mov/.mp4/.m4v).") var output: String
    @Option(help: "Track mapping INDEX:v or INDEX:a (index = position of -i, 0-based). Default: first video + first audio found.")
    var map: [String] = []
    @Flag(help: "Overwrite existing output file.") var replace = false
    @Flag(help: "Print per-track mapping decisions.") var verbose = false

    func run() async throws {
        try await exitOnMediaError { try await remux() }
    }

    func remux() async throws {
        guard !input.isEmpty else { throw ValidationError("at least one -i input required") }
        let outURL = try prepareOutput(output, replace: replace)
        let fileType = try containerType(for: outURL)

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

        let assets = input.map { AVURLAsset(url: URL(fileURLWithPath: $0)) }
        var selected: [(inputIndex: Int, track: AVAssetTrack)] = []
        if wanted.isEmpty {
            // first video track + first audio track across inputs, plus all subtitle tracks
            for type in [AVMediaType.video, .audio] {
                for (i, asset) in assets.enumerated() {
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
                let subs = try await mediaOp("loading \(input[i])") {
                    try await asset.loadTracks(withMediaType: .subtitle)
                }
                selected.append(contentsOf: subs.map { (i, $0) })
            }
        } else {
            for (idx, type) in wanted {
                let tracks = try await mediaOp("loading \(input[idx])") {
                    try await assets[idx].loadTracks(withMediaType: type)
                }
                guard let track = tracks.first else {
                    throw MediaError("no \(type.rawValue) track in \(input[idx])")
                }
                selected.append((idx, track))
            }
        }
        guard !selected.isEmpty else {
            throw MediaError("no video or audio tracks found in inputs")
        }

        let writer = try mediaOp("creating writer for \(output)") {
            try AVAssetWriter(outputURL: outURL, fileType: fileType)
        }

        var pumps: [(out: AVAssetReaderTrackOutput, in: AVAssetWriterInput, reader: AVAssetReader, label: String)] = []
        var readers: [Int: AVAssetReader] = [:]
        for (i, track) in selected {
            let reader: AVAssetReader
            if let existing = readers[i] { reader = existing }
            else {
                reader = try mediaOp("creating reader for \(input[i])") { try AVAssetReader(asset: assets[i]) }
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
            pumps.append((trackOut, writerIn, reader, "\(track.mediaType.rawValue) #\(i)"))
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
            for p in pumps {
                group.addTask {
                    try await pump(from: p.out, to: p.in, reader: p.reader, writer: writer, label: p.label, progress: nil)
                }
            }
            try await group.waitForAll()
        }

        await writer.finishWriting()
        if writer.status != .completed {
            throw MediaError("finalizing \(output)", underlying: writer.error)
        }
        print("wrote \(output)")
    }
}
