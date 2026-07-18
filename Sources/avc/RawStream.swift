// Raw Annex B elementary streams: NAL scanning, HEVC bitstream parsing (SPS/PPS/POC),
// and presentation-order recovery for mkvextract timestamp files.
import AVFoundation
import Foundation

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
