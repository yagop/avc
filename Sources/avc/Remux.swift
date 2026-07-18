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

        var pumps: [(out: AVAssetReaderTrackOutput, in: AVAssetWriterInput, reader: AVAssetReader, label: String)] = []
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
            pumps.append((trackOut, writerIn, reader, "\(track.mediaType.rawValue) #\(i)"))
        }

        // synthesized tx3g tracks from .srt inputs
        var srtFeeds: [(samples: [CMSampleBuffer], in: AVAssetWriterInput, label: String)] = []
        for i in srtInputs {
            let text = try mediaOp("reading \(input[i])") {
                try String(contentsOfFile: input[i], encoding: .utf8)
            }
            let cues = try parseSRT(text, file: input[i])
            let fd = try tx3gFormatDescription()
            let writerIn = AVAssetWriterInput(mediaType: .subtitle, outputSettings: nil, sourceFormatHint: fd)
            writerIn.expectsMediaDataInRealTime = false
            guard writer.canAdd(writerIn) else {
                throw MediaError("cannot write subtitle track (tx3g) from \(input[i]) into \(fileType.rawValue) container")
            }
            writer.add(writerIn)
            if verbose {
                print("map: \(input[i]) \(cues.count) cues -> \(output) [srt -> tx3g]")
            }
            srtFeeds.append((try tx3gSamples(cues, format: fd), writerIn, "srt #\(i)"))
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
            for p in pumps {
                group.addTask {
                    try await pump(from: p.out, to: p.in, reader: p.reader, writer: writer, label: p.label, progress: nil)
                }
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

struct SRTCue {
    let start: Double
    let end: Double
    let text: String
}

/// Parse SubRip: blocks of "index / HH:MM:SS,mmm --> HH:MM:SS,mmm / text lines" separated by blank lines.
func parseSRT(_ content: String, file: String) throws -> [SRTCue] {
    func seconds(_ stamp: Substring) -> Double? {
        // HH:MM:SS,mmm (comma or dot)
        let parts = stamp.replacingOccurrences(of: ",", with: ".").split(separator: ":")
        guard parts.count == 3, let h = Double(parts[0]), let m = Double(parts[1]), let s = Double(parts[2])
        else { return nil }
        return h * 3600 + m * 60 + s
    }
    var cues: [SRTCue] = []
    let normalized = content.replacingOccurrences(of: "\r\n", with: "\n")
        .trimmingCharacters(in: CharacterSet(charactersIn: "\u{FEFF}"))
    for block in normalized.components(separatedBy: "\n\n") where !block.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        let lines = block.split(separator: "\n", omittingEmptySubsequences: false)
            .drop { !$0.contains("-->") }
        guard let timing = lines.first else { continue }  // block without a timing line
        let stamps = timing.components(separatedBy: "-->")
        guard stamps.count == 2,
              let start = seconds(Substring(stamps[0].trimmingCharacters(in: .whitespaces))),
              let end = seconds(Substring(stamps[1].trimmingCharacters(in: .whitespaces).prefix(12))),
              end > start
        else {
            throw MediaError("cannot parse SRT timing line '\(timing)' in \(file)")
        }
        let text = lines.dropFirst().joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty { cues.append(SRTCue(start: start, end: end, text: text)) }
    }
    guard !cues.isEmpty else { throw MediaError("no subtitle cues found in \(file)") }
    return cues.sorted { $0.start < $1.start }
}

private func be16(_ v: Int) -> [UInt8] { [UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)] }
private func be32(_ v: Int) -> [UInt8] { [UInt8(v >> 24 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)] }

/// Full tx3g TextSampleEntry atom per 3GPP TS 26.245 (the writer requires all fields incl. font table).
func tx3gFormatDescription() throws -> CMFormatDescription {
    let fontName = Array("Sans-Serif".utf8)
    let ftab = be32(8 + 2 + 2 + 1 + fontName.count) + Array("ftab".utf8) + be16(1) + be16(1) + [UInt8(fontName.count)] + fontName
    var entry: [UInt8] = []
    entry += [0, 0, 0, 0, 0, 0] + be16(1)             // reserved + data_reference_index
    entry += be32(0)                                   // displayFlags
    entry += [1, 0xFF]                                 // h-just center, v-just bottom
    entry += [0, 0, 0, 0]                              // background rgba
    entry += be16(0) + be16(0) + be16(90) + be16(640)  // default text box
    entry += be16(0) + be16(0) + be16(1) + [0, 12] + [255, 255, 255, 255] // style record
    entry += ftab
    let atom = be32(8 + entry.count) + Array("tx3g".utf8) + entry
    var fd: CMFormatDescription?
    let status = Data(atom).withUnsafeBytes { buf in
        CMTextFormatDescriptionCreateFromBigEndianTextDescriptionData(
            allocator: nil, bigEndianTextDescriptionData: buf.baseAddress!.assumingMemoryBound(to: UInt8.self),
            size: atom.count, flavor: nil, mediaType: kCMMediaType_Subtitle, formatDescriptionOut: &fd)
    }
    guard status == noErr, let fd else {
        throw MediaError("creating tx3g format description", underlying: NSError(domain: NSOSStatusErrorDomain, code: Int(status)))
    }
    return fd
}

/// One tx3g sample per cue, plus empty samples filling the gaps (tx3g timelines are contiguous).
func tx3gSamples(_ cues: [SRTCue], format: CMFormatDescription) throws -> [CMSampleBuffer] {
    var samples: [CMSampleBuffer] = []
    var cursor = 0.0
    for cue in cues {
        // overlapping cues: clip to the end of the previous one; fully-contained cues are dropped
        guard cue.end > cursor else { continue }
        if cue.start > cursor {
            samples.append(try tx3gSample("", format: format, start: cursor, end: cue.start))
        }
        samples.append(try tx3gSample(cue.text, format: format, start: max(cue.start, cursor), end: cue.end))
        cursor = max(cursor, cue.end)
    }
    return samples
}

func tx3gSample(_ text: String, format: CMFormatDescription, start: Double, end: Double) throws -> CMSampleBuffer {
    var payload = Data()
    payload.append(contentsOf: be16(text.utf8.count))
    payload.append(Data(text.utf8))
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
    var timing = CMSampleTimingInfo(
        duration: CMTime(seconds: end - start, preferredTimescale: 600),
        presentationTimeStamp: CMTime(seconds: start, preferredTimescale: 600),
        decodeTimeStamp: .invalid)
    var size = payload.count
    var sample: CMSampleBuffer?
    if status == noErr {
        status = CMSampleBufferCreateReady(
            allocator: nil, dataBuffer: block!, formatDescription: format,
            sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample)
    }
    guard status == noErr, let sample else {
        throw MediaError("creating tx3g sample at \(start)s", underlying: NSError(domain: NSOSStatusErrorDomain, code: Int(status)))
    }
    return sample
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
    let queue = DispatchQueue(label: "avc.pump.\(label)")
    nonisolated(unsafe) let input = input
    nonisolated(unsafe) let writer = writer
    try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
        nonisolated(unsafe) var next = 0
        nonisolated(unsafe) var done = false
        input.requestMediaDataWhenReady(on: queue) {
            guard !done else { return }
            while input.isReadyForMoreMediaData {
                guard next < count else {
                    done = true
                    input.markAsFinished()
                    cont.resume()
                    return
                }
                let sample: CMSampleBuffer
                do { sample = try make(next) } catch {
                    done = true
                    input.markAsFinished()
                    cont.resume(throwing: error)
                    return
                }
                if !input.append(sample) {
                    done = true
                    input.markAsFinished()
                    cont.resume(throwing: MediaError(
                        "appending \(label) sample at \(fmt(CMSampleBufferGetPresentationTimeStamp(sample)))",
                        underlying: writer.error))
                    return
                }
                next += 1
            }
        }
    }
}

// MARK: - Raw Annex B elementary streams (.h264/.h265) + mkvextract timestamps_v2

/// Lazily-built samples over a memory-mapped Annex B stream: peak memory is one frame,
/// not the whole file.
struct RawStream {
    let format: CMFormatDescription
    let frameCount: Int
    private let data: Data                       // memory-mapped
    private let frames: [(nals: [Range<Int>], sync: Bool)]
    private let timing: [CMSampleTimingInfo]

    func makeSample(_ i: Int) throws -> CMSampleBuffer {
        var payload = Data(capacity: frames[i].nals.reduce(0) { $0 + 4 + $1.count })
        for range in frames[i].nals {
            var len = UInt32(range.count).bigEndian
            payload.append(Data(bytes: &len, count: 4))
            payload.append(data.subdata(in: range))
        }
        return try makeSampleBuffer(payload, format: format, timing: timing[i], sync: frames[i].sync,
                                    what: "raw sample \(i)")
    }

    init(path: String, timestamps: [Double]) throws {
        let data = try mediaOp("mapping \(path)") {
            try Data(contentsOf: URL(fileURLWithPath: path), options: .alwaysMapped)
        }
        let ext = (path as NSString).pathExtension.lowercased()
        let hevc = ext != "h264" && ext != "264"

        // scan NAL unit ranges (offsets only; no payload copies)
        var nalRanges: [Range<Int>] = []
        data.withUnsafeBytes { (buf: UnsafeRawBufferPointer) in
            let bytes = buf.bindMemory(to: UInt8.self)
            var i = 0, start = -1
            while i + 2 < bytes.count {
                if bytes[i] == 0, bytes[i + 1] == 0, bytes[i + 2] == 1 {
                    let codeStart = (i > 0 && bytes[i - 1] == 0) ? i - 1 : i
                    if start >= 0, start < codeStart { nalRanges.append(start..<codeStart) }
                    i += 3
                    start = i
                } else if bytes[i + 2] > 1 {
                    i += 3   // skip ahead: a start code cannot end here
                } else {
                    i += 1
                }
            }
            if start >= 0, start < bytes.count { nalRanges.append(start..<bytes.count) }
        }
        guard !nalRanges.isEmpty else { throw MediaError("no NAL units found in \(path); is it an Annex B stream?") }

        func nalType(_ r: Range<Int>) -> Int { hevc ? Int(data[r.lowerBound] >> 1) & 0x3F : Int(data[r.lowerBound]) & 0x1F }
        func isVCL(_ t: Int) -> Bool { hevc ? t <= 31 : (1...5).contains(t) }
        func isSync(_ t: Int) -> Bool { hevc ? (16...23).contains(t) : t == 5 }
        func isParamSet(_ t: Int) -> Bool { hevc ? (32...34).contains(t) : (t == 7 || t == 8) }
        func startsNewFrame(_ r: Range<Int>, _ t: Int) -> Bool {
            guard isVCL(t) else { return false }
            // first_slice_segment_in_pic_flag (HEVC) / first_mb_in_slice == 0 (H.264, ue(v) leading 1 bit)
            let flagIndex = r.lowerBound + (hevc ? 2 : 1)
            return flagIndex < r.upperBound && data[flagIndex] & 0x80 != 0
        }

        // collect parameter sets (small copies) and group NALs into access units
        var vps: Data?, sps: Data?, pps: Data?
        var spsNals: [Data] = [], ppsNals: [Data] = []
        var grouped: [(nals: [Range<Int>], sync: Bool)] = []
        var current: [Range<Int>] = []
        var currentSync = false, currentHasVCL = false
        for r in nalRanges {
            let t = nalType(r)
            if isParamSet(t) {
                let set = data.subdata(in: r)
                if hevc {
                    if t == 32 { vps = set }
                    else if t == 33 { sps = set; spsNals.append(set) }
                    else { pps = set; ppsNals.append(set) }
                } else {
                    if t == 7 { sps = set } else { pps = set }
                }
                continue
            }
            if hevc && t == 35 { continue }  // AUD
            if startsNewFrame(r, t), currentHasVCL {
                grouped.append((current, currentSync))
                current = []; currentSync = false; currentHasVCL = false
            }
            current.append(r)
            if isVCL(t) { currentHasVCL = true; currentSync = currentSync || isSync(t) }
        }
        if currentHasVCL { grouped.append((current, currentSync)) }

        guard let sps, let pps, !(hevc && vps == nil) else {
            throw MediaError("missing \(hevc ? "VPS/SPS/PPS" : "SPS/PPS") parameter sets in \(path)")
        }
        guard grouped.count == timestamps.count else {
            throw MediaError("frame count mismatch: \(grouped.count) frames in \(path) but \(timestamps.count) timestamps")
        }
        let format = try mediaOp("creating format description from \(path) parameter sets") {
            try withParameterSets(hevc ? [vps!, sps, pps] : [sps, pps], hevc: hevc)
        }

        // mkvextract writes timestamps_v2 sorted (presentation order) while Annex B frames
        // are in decode order: recover each frame's display rank from HEVC picture order
        // counts and assign timestamps by rank. Non-monotonic files are already per-frame
        // PTS in decode order and are used as-is.
        let isSorted = zip(timestamps, timestamps.dropFirst()).allSatisfy(<=)
        if isSorted, !hevc, timestamps.count > 1 {
            // H.264 slice header: first_mb_in_slice ue(v), slice_type ue(v); type % 5 == 1 is a B slice
            let hasBFrames = grouped.contains { frame in
                guard let vcl = frame.nals.first(where: { (1...5).contains(Int(data[$0.lowerBound]) & 0x1F) })
                else { return false }
                var r = BitReader(data.subdata(in: vcl.lowerBound..<min(vcl.lowerBound + 16, vcl.upperBound)), skippingHeaderBytes: 1)
                _ = r.ue()
                return r.ue() % 5 == 1
            }
            if hasBFrames {
                throw MediaError(
                    "\(path) is H.264 with B-frames and a sorted (presentation-order) timestamps file; "
                    + "reordering recovery is only implemented for HEVC, so the output would have scrambled timing. "
                    + "Remux from the original container with another tool instead.")
            }
        }
        let ptsPerFrame: [Double]
        if isSorted, hevc, timestamps.count > 1 {
            let ranks = try hevcPresentationRanks(
                frames: grouped.map(\.nals), data: data, spsNals: spsNals, ppsNals: ppsNals)
            ptsPerFrame = ranks.map { timestamps[$0] }
        } else {
            ptsPerFrame = timestamps
        }

        // decode order = file order; PTS from container; DTS = i-th smallest PTS
        // (starts at first PTS, monotonic; PTS < DTS is fine — negative composition
        // offsets are legal — but negative DTS makes AVAssetWriter shift the track)
        let sorted = ptsPerFrame.sorted()
        var rank: [Double: Int] = [:]
        for (i, t) in sorted.enumerated() { rank[t] = i }
        let lastDelta = sorted.count > 1 ? sorted[sorted.count - 1] - sorted[sorted.count - 2] : 1.0 / 30
        self.timing = ptsPerFrame.enumerated().map { i, pts in
            let r = rank[pts]!
            return CMSampleTimingInfo(
                duration: CMTime(seconds: r + 1 < sorted.count ? sorted[r + 1] - pts : lastDelta, preferredTimescale: 90000),
                presentationTimeStamp: CMTime(seconds: pts, preferredTimescale: 90000),
                decodeTimeStamp: CMTime(seconds: sorted[i], preferredTimescale: 90000))
        }
        self.data = data
        self.frames = grouped
        self.format = format
        self.frameCount = grouped.count
    }
}

func isRawVideoPath(_ path: String) -> Bool {
    ["h265", "hevc", "265", "h264", "264"].contains((path as NSString).pathExtension.lowercased())
}

/// Parse mkvextract `timestamps_v2` output: '#'-comment lines, then one PTS in ms per frame.
func parseTimestampsV2(_ path: String) throws -> [Double] {
    let content = try mediaOp("reading \(path)") { try String(contentsOfFile: path, encoding: .utf8) }
    let values = content.split(whereSeparator: \.isNewline)
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty && !$0.hasPrefix("#") }
        .compactMap(Double.init)
    guard !values.isEmpty else { throw MediaError("no timestamps found in \(path)") }
    return values.map { $0 / 1000 }
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

private func withParameterSets(_ sets: [Data], hevc: Bool) throws -> CMFormatDescription {
    var fd: CMFormatDescription?
    // stable copies; Data's storage must not be borrowed past withUnsafeBytes
    let buffers: [UnsafeMutableBufferPointer<UInt8>] = sets.map { set in
        let buf = UnsafeMutableBufferPointer<UInt8>.allocate(capacity: set.count)
        _ = buf.initialize(from: set)
        return buf
    }
    defer { buffers.forEach { $0.deallocate() } }
    let pointers = buffers.map { UnsafePointer($0.baseAddress!) }
    let sizes = sets.map(\.count)
    let status: OSStatus
    if hevc {
        status = CMVideoFormatDescriptionCreateFromHEVCParameterSets(
            allocator: nil, parameterSetCount: sets.count, parameterSetPointers: pointers,
            parameterSetSizes: sizes, nalUnitHeaderLength: 4, extensions: nil, formatDescriptionOut: &fd)
    } else {
        status = CMVideoFormatDescriptionCreateFromH264ParameterSets(
            allocator: nil, parameterSetCount: sets.count, parameterSetPointers: pointers,
            parameterSetSizes: sizes, nalUnitHeaderLength: 4, formatDescriptionOut: &fd)
    }
    guard status == noErr, let fd else {
        throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
    }
    return fd
}

// MARK: - HEVC picture order count (presentation-order recovery for sorted timestamp files)

/// RBSP bit reader: strips emulation-prevention bytes (00 00 03) on the fly.
struct BitReader {
    private let bytes: [UInt8]
    private var bit = 0

    init(_ data: Data, skippingHeaderBytes header: Int, limit: Int = 96) {
        var out: [UInt8] = []
        var zeros = 0
        for (n, b) in data.enumerated() {
            if n < header { continue }
            if out.count >= limit { break }
            if zeros >= 2, b == 3 { zeros = 0; continue }  // emulation prevention
            zeros = b == 0 ? zeros + 1 : 0
            out.append(b)
        }
        bytes = out
    }

    mutating func u(_ n: Int) -> Int {
        var v = 0
        for _ in 0..<n {
            let byte = bit >> 3
            guard byte < bytes.count else { return v << 1 }
            v = v << 1 | Int(bytes[byte] >> (7 - bit & 7)) & 1
            bit += 1
        }
        return v
    }

    mutating func ue() -> Int {
        var zeros = 0
        while u(1) == 0, zeros < 32 { zeros += 1 }
        return (1 << zeros) - 1 + u(zeros)
    }
}

struct HEVCSPSInfo { let log2MaxPocLsb: Int; let separateColourPlane: Bool }
struct HEVCPPSInfo { let outputFlagPresent: Bool }

func parseHEVCSPS(_ nal: Data) -> (id: Int, info: HEVCSPSInfo) {
    var r = BitReader(nal, skippingHeaderBytes: 2)
    _ = r.u(4)                                // sps_video_parameter_set_id
    let maxSubLayersMinus1 = r.u(3)
    _ = r.u(1)                                // temporal_id_nesting
    // profile_tier_level: general part is 96 bits
    _ = r.u(32); _ = r.u(32); _ = r.u(32)
    var profilePresent: [Bool] = [], levelPresent: [Bool] = []
    for _ in 0..<maxSubLayersMinus1 { profilePresent.append(r.u(1) == 1); levelPresent.append(r.u(1) == 1) }
    if maxSubLayersMinus1 > 0 { for _ in maxSubLayersMinus1..<8 { _ = r.u(2) } }
    for i in 0..<maxSubLayersMinus1 {
        if profilePresent[i] { _ = r.u(32); _ = r.u(32); _ = r.u(24) }  // 88 bits
        if levelPresent[i] { _ = r.u(8) }
    }
    let spsId = r.ue()
    let chroma = r.ue()
    let separate = chroma == 3 && r.u(1) == 1
    _ = r.ue(); _ = r.ue()                    // pic width/height
    if r.u(1) == 1 { _ = r.ue(); _ = r.ue(); _ = r.ue(); _ = r.ue() }  // conformance window
    _ = r.ue(); _ = r.ue()                    // bit depths
    let log2MaxPocLsb = r.ue() + 4
    return (spsId, HEVCSPSInfo(log2MaxPocLsb: log2MaxPocLsb, separateColourPlane: separate))
}

func parseHEVCPPS(_ nal: Data) -> (id: Int, spsId: Int, info: HEVCPPSInfo) {
    var r = BitReader(nal, skippingHeaderBytes: 2)
    let ppsId = r.ue()
    let spsId = r.ue()
    _ = r.u(1)                                // dependent_slice_segments_enabled
    let outputFlagPresent = r.u(1) == 1
    return (ppsId, spsId, HEVCPPSInfo(outputFlagPresent: outputFlagPresent))
}

/// Presentation rank of each frame (decode order in, display rank out), from slice-header
/// picture order counts. Needed when the timestamp file is sorted (mkvextract writes
/// timestamps_v2 in presentation order, but Annex B frames are in decode order).
func hevcPresentationRanks(
    frames: [[Range<Int>]], data: Data,
    spsNals: [Data], ppsNals: [Data]
) throws -> [Int] {
    var spsById: [Int: HEVCSPSInfo] = [:]
    for nal in spsNals { let (id, info) = parseHEVCSPS(nal); spsById[id] = info }
    var ppsById: [Int: (spsId: Int, info: HEVCPPSInfo)] = [:]
    for nal in ppsNals { let (id, spsId, info) = parseHEVCPPS(nal); ppsById[id] = (spsId, info) }

    // (cvsIndex, poc) per frame; IDR/BLA reset the coded video sequence
    var keys: [(cvs: Int, poc: Int)] = []
    var cvs = 0, prevPocLsb = 0, prevPocMsb = 0
    for (n, frame) in frames.enumerated() {
        guard let vcl = frame.first(where: { Int(data[$0.lowerBound] >> 1) & 0x3F <= 31 }) else {
            throw MediaError("frame \(n) has no VCL NAL unit")
        }
        let type = Int(data[vcl.lowerBound] >> 1) & 0x3F
        var r = BitReader(data.subdata(in: vcl.lowerBound..<min(vcl.lowerBound + 32, vcl.upperBound)), skippingHeaderBytes: 2)
        _ = r.u(1)                            // first_slice_segment_in_pic_flag (always 1 here)
        if (16...23).contains(type) { _ = r.u(1) }  // no_output_of_prior_pics_flag
        let ppsId = r.ue()
        guard let pps = ppsById[ppsId], let sps = spsById[pps.spsId] else {
            throw MediaError("frame \(n) references unknown PPS \(ppsId)")
        }
        _ = r.ue()                            // slice_type
        if pps.info.outputFlagPresent { _ = r.u(1) }
        if sps.separateColourPlane { _ = r.u(2) }

        if type == 19 || type == 20 || (16...18).contains(type) {  // IDR / BLA: new CVS, POC 0
            cvs += 1
            prevPocLsb = 0; prevPocMsb = 0
            keys.append((cvs, 0))
            continue
        }
        let maxLsb = 1 << sps.log2MaxPocLsb
        let lsb = r.u(sps.log2MaxPocLsb)
        var msb = prevPocMsb
        if lsb < prevPocLsb, prevPocLsb - lsb >= maxLsb / 2 { msb += maxLsb }
        else if lsb > prevPocLsb, lsb - prevPocLsb > maxLsb / 2 { msb -= maxLsb }
        prevPocLsb = lsb; prevPocMsb = msb
        keys.append((cvs, msb + lsb))
    }

    // rank in presentation order
    let order = keys.indices.sorted { keys[$0] < keys[$1] }
    var rank = [Int](repeating: 0, count: keys.count)
    for (r, i) in order.enumerated() { rank[i] = r }
    return rank
}
