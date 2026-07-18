import AVFoundation
import Testing

@testable import avc

@Suite struct BitrateTests {
    @Test func suffixes() throws {
        #expect(try parseBitrate("8M") == 8_000_000)
        #expect(try parseBitrate("8000k") == 8_000_000)
        #expect(try parseBitrate("8000000") == 8_000_000)
        #expect(try parseBitrate("0.5M") == 500_000)
        #expect(try parseBitrate("19m") == 19_000_000)
    }

    @Test(arguments: ["lots", "", "-5M", "0"])
    func invalid(_ s: String) {
        #expect(throws: (any Error).self) { try parseBitrate(s) }
    }
}

@Suite struct ClampSizeTests {
    let source = CGSize(width: 1920, height: 1080)

    @Test func defaultsToSource() {
        #expect(clampSize(source, width: nil, height: nil) == source)
    }

    @Test func aspectFromWidth() {
        #expect(clampSize(source, width: 1280, height: nil) == CGSize(width: 1280, height: 720))
    }

    @Test func aspectFromHeight() {
        #expect(clampSize(source, width: nil, height: 720) == CGSize(width: 1280, height: 720))
    }

    @Test func neverUpscales() {
        #expect(clampSize(source, width: 4000, height: nil) == source)
    }

    @Test func evenDimensions() {
        let out = clampSize(CGSize(width: 855, height: 481), width: nil, height: nil)
        #expect(Int(out.width) % 2 == 0)
        #expect(Int(out.height) % 2 == 0)
    }
}

@Suite struct ContainerTests {
    @Test func knownExtensions() throws {
        #expect(try containerType(for: URL(fileURLWithPath: "/x/a.mov")) == .mov)
        #expect(try containerType(for: URL(fileURLWithPath: "/x/a.MP4")) == .mp4)
        #expect(try containerType(for: URL(fileURLWithPath: "/x/a.m4v")) == .mp4)
    }

    @Test func unknownExtensionThrows() {
        #expect(throws: (any Error).self) {
            try containerType(for: URL(fileURLWithPath: "/x/a.xyz"))
        }
    }
}

@Suite struct ErrorTests {
    @Test func knownStatus() {
        #expect(describe(OSStatus(-12902)).contains("kVTParameterErr"))
        #expect(describe(OSStatus(-11828)).contains("AVErrorFileFormatNotRecognized"))
    }

    @Test func unknownStatus() {
        #expect(describe(OSStatus(-99999)).contains("look up in VTErrors.h"))
    }

    @Test func errorChainAndHint() {
        let underlying = NSError(domain: NSOSStatusErrorDomain, code: -12902)
        let top = NSError(domain: AVFoundationErrorDomain, code: -11800,
                          userInfo: [NSUnderlyingErrorKey: underlying])
        let message = MediaError("encoding failed", underlying: top).message
        #expect(message.contains("AVFoundationErrorDomain"))
        #expect(message.contains("└─"))
        #expect(message.contains("kVTParameterErr"))
        #expect(message.contains("hint:"))
    }
}

@Suite struct SRTTests {
    @Test func basic() throws {
        let cues = try parseSRT("1\n00:00:01,500 --> 00:00:03,000\nHello\n\n", file: "t")
        #expect(cues.count == 1)
        #expect(cues[0].start == 1.5)
        #expect(cues[0].end == 3.0)
        #expect(cues[0].text == "Hello")
    }

    @Test func crlfBOMAndDotMillis() throws {
        let srt = "\u{FEFF}1\r\n00:00:00.200 --> 00:00:01.000\r\nHi\r\n\r\n"
        let cues = try parseSRT(srt, file: "t")
        #expect(cues.count == 1)
        #expect(abs(cues[0].start - 0.2) < 0.001)
    }

    @Test func multilineTextPreserved() throws {
        let cues = try parseSRT("1\n00:00:00,000 --> 00:00:01,000\nline one\nline two\n\n", file: "t")
        #expect(cues[0].text == "line one\nline two")
    }

    @Test func outOfOrderCuesSorted() throws {
        let srt = "2\n00:00:05,000 --> 00:00:06,000\nB\n\n1\n00:00:01,000 --> 00:00:02,000\nA\n\n"
        let cues = try parseSRT(srt, file: "t")
        #expect(cues.map(\.text) == ["A", "B"])
    }

    @Test func garbageThrows() {
        #expect(throws: (any Error).self) { try parseSRT("no cues here\n\n", file: "t") }
    }

    @Test func hourTimestamps() throws {
        let cues = try parseSRT("1\n01:02:03,400 --> 01:02:04,000\nX\n\n", file: "t")
        #expect(abs(cues[0].start - 3723.4) < 0.001)
    }
}

@Suite struct Tx3gTests {
    @Test func formatDescription() throws {
        let fd = try tx3gFormatDescription()
        #expect(CMFormatDescriptionGetMediaType(fd) == kCMMediaType_Subtitle)
        #expect(CMFormatDescriptionGetMediaSubType(fd) == kCMSubtitleFormatType_3GText)
    }

    @Test func gapFilling() throws {
        let fd = try tx3gFormatDescription()
        let cues = [SRTCue(start: 0.5, end: 1.0, text: "a"), SRTCue(start: 2.0, end: 3.0, text: "b")]
        let samples = try tx3gSamples(cues, format: fd)
        // gap before "a", cue "a", gap between, cue "b"
        #expect(samples.count == 4)
        #expect(CMSampleBufferGetPresentationTimeStamp(samples[0]).seconds == 0)
        #expect(CMSampleBufferGetPresentationTimeStamp(samples[3]).seconds == 2.0)
    }
}

@Suite struct TimestampsV2Tests {
    @Test func parse() throws {
        let path = NSTemporaryDirectory() + "/ts-\(UUID()).txt"
        try "# timestamp format v2\n0\n42\n83.5\n".write(toFile: path, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: path) }
        #expect(try parseTimestampsV2(path) == [0, 0.042, 0.0835])
    }

    @Test func onlyCommentsThrows() throws {
        let path = NSTemporaryDirectory() + "/ts-\(UUID()).txt"
        try "# only comments\n".write(toFile: path, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: path) }
        #expect(throws: (any Error).self) { try parseTimestampsV2(path) }
    }
}

@Suite struct BitReaderTests {
    @Test func fixedBits() {
        var r = BitReader(Data([0b1011_0100]), skippingHeaderBytes: 0)
        #expect(r.u(1) == 1)
        #expect(r.u(3) == 0b011)
        #expect(r.u(4) == 0b0100)
    }

    @Test func expGolomb() {
        // bits: 1 | 010 | 011 | 00100  -> ue values 0, 1, 2, 3
        var r = BitReader(Data([0b1010_0110, 0b0100_0000]), skippingHeaderBytes: 0)
        #expect(r.ue() == 0)
        #expect(r.ue() == 1)
        #expect(r.ue() == 2)
        #expect(r.ue() == 3)
    }

    @Test func emulationPreventionStripped() {
        // 00 00 03 01: the 03 is an emulation-prevention byte and must be removed
        var r = BitReader(Data([0x00, 0x00, 0x03, 0x01]), skippingHeaderBytes: 0)
        #expect(r.u(24) == 1)
    }
}

@Suite struct HEVCParserTests {
    // Real-world SPS payloads from the h265nal project's parser unit tests
    // (github.com/chemag/h265nal, test/h265_sps_parser_unittest.cc), with the
    // 2-byte NAL header (0x42 0x01) prepended. Expected values from the same tests:
    // both have log2_max_pic_order_cnt_lsb_minus4 = 4 (so log2MaxPocLsb == 8),
    // sps_seq_parameter_set_id = 0, chroma_format_idc = 1 (no separate colour planes).
    static let sampleSPS = Data([0x42, 0x01,
        0x01, 0x01, 0x60, 0x00, 0x00, 0x03, 0x00, 0xb0,
        0x00, 0x00, 0x03, 0x00, 0x00, 0x03, 0x00, 0x5d,
        0xa0, 0x02, 0x80, 0x80, 0x2e, 0x1f, 0x13, 0x96,
        0xbb, 0x93, 0x24, 0xbb, 0x95, 0x82, 0x83, 0x03,
        0x01, 0x76, 0x85, 0x09, 0x40])

    static let complexSPS = Data([0x42, 0x01,
        0x01, 0x01, 0x60, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x99, 0xa0, 0x03, 0xc0,
        0x80, 0x11, 0x07, 0xf9, 0x65, 0x26, 0x49, 0x1b,
        0x61, 0xa5, 0x88, 0xaa, 0x93, 0x13, 0x0c, 0xbe,
        0xcf, 0xaf, 0x37, 0xe5, 0x9f, 0x5e, 0x14, 0x46,
        0x27, 0x2e, 0xda, 0xc0, 0xff, 0xff])

    @Test(arguments: [sampleSPS, complexSPS])
    func realWorldSPS(_ sps: Data) {
        let (id, info) = parseHEVCSPS(sps)
        #expect(id == 0)
        #expect(info.log2MaxPocLsb == 8)
        #expect(!info.separateColourPlane)
    }

    @Test func minimalPPS() {
        // bits after header: pps_id ue(0)=1, sps_id ue(0)=1, dependent u(1)=0, output_flag u(1)=1
        let pps = Data([0x44, 0x01, 0b1101_0000])
        let (id, spsId, info) = parseHEVCPPS(pps)
        #expect(id == 0)
        #expect(spsId == 0)
        #expect(info.outputFlagPresent)
    }
}

/// End-to-end: encode a B-frame HEVC stream with AVFoundation, dump it to Annex B,
/// wrap it back through RawStream with an mkvextract-style sorted timestamp file, and
/// verify every reconstructed PTS matches the encoder's original presentation times.
@Suite struct RawStreamRoundTripTests {
    @Test func presentationOrderRecoveredFromSortedTimestamps() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("avc-test-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        // 1. encode 30 frames of HEVC (hardware encoder reorders: B-frames present)
        let mov = dir.appendingPathComponent("src.mov")
        let writer = try AVAssetWriter(outputURL: mov, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: 320, AVVideoHeightKey: 240,
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: 320, kCVPixelBufferHeightKey as String: 240,
        ])
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<30 {
            while !input.isReadyForMoreMediaData { usleep(500) }
            var pb: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &pb)
            CVPixelBufferLockBaseAddress(pb!, [])
            memset(CVPixelBufferGetBaseAddress(pb!), Int32(frame * 8 % 255), CVPixelBufferGetDataSize(pb!))
            CVPixelBufferUnlockBaseAddress(pb!, [])
            adaptor.append(pb!, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 30))
        }
        input.markAsFinished()
        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        done.wait()
        #expect(writer.status == .completed)

        // 2. dump to Annex B, remembering decode-order PTS as ground truth
        let asset = AVURLAsset(url: mov)
        let loaded = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var track: AVAssetTrack!
        asset.loadTracks(withMediaType: .video) { t, _ in track = t!.first; loaded.signal() }
        loaded.wait()
        let reader = try AVAssetReader(asset: asset)
        let out = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        reader.add(out)
        reader.startReading()

        var stream = Data()
        var groundTruthPTS: [Double] = []
        let startCode = Data([0, 0, 0, 1])
        var wroteParams = false
        while let sample = out.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
            if !wroteParams, let fd = CMSampleBufferGetFormatDescription(sample) {
                var count = 0
                CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(fd, parameterSetIndex: 0, parameterSetPointerOut: nil, parameterSetSizeOut: nil, parameterSetCountOut: &count, nalUnitHeaderLengthOut: nil)
                for i in 0..<count {
                    var ptr: UnsafePointer<UInt8>?
                    var size = 0
                    CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(fd, parameterSetIndex: i, parameterSetPointerOut: &ptr, parameterSetSizeOut: &size, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil)
                    stream.append(startCode)
                    stream.append(Data(bytes: ptr!, count: size))
                }
                wroteParams = true
            }
            var length = 0
            var dataPtr: UnsafeMutablePointer<CChar>?
            CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &dataPtr)
            let data = Data(bytes: dataPtr!, count: length)
            var offset = 0
            while offset + 4 <= data.count {
                let len = data.subdata(in: offset..<offset + 4).reduce(0) { ($0 << 8) | Int($1) }
                stream.append(startCode)
                stream.append(data.subdata(in: offset + 4..<min(offset + 4 + len, data.count)))
                offset += 4 + len
            }
            groundTruthPTS.append(CMSampleBufferGetPresentationTimeStamp(sample).seconds)
        }
        let rawPath = dir.appendingPathComponent("raw.h265").path
        try stream.write(to: URL(fileURLWithPath: rawPath))
        #expect(groundTruthPTS != groundTruthPTS.sorted(),
                "encoder produced no B-frames; reorder test is vacuous")

        // 3. wrap with mkvextract-style SORTED timestamps; verify exact PTS recovery
        let raw = try RawStream(path: rawPath, timestamps: groundTruthPTS.sorted())
        #expect(raw.frameCount == 30)
        for i in 0..<raw.frameCount {
            let sample = try raw.makeSample(i)
            let pts = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            #expect(abs(pts - groundTruthPTS[i]) < 0.001,
                    "frame \(i): POC-recovered PTS \(pts) != encoder ground truth \(groundTruthPTS[i])")
            #expect(CMSampleBufferGetDecodeTimeStamp(sample).seconds >= 0,
                    "frame \(i): negative DTS")
        }
    }

    @Test func frameCountMismatchThrows() throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("bogus-\(UUID()).h265").path
        // SPS-only header + one VCL NAL (IDR_W_RADL, first-slice flag set): 1 frame, 3 timestamps
        var data = Data([0, 0, 0, 1, 0x42, 0x01])
        data.append(Data([0, 0, 0, 1, 19 << 1, 0x01, 0x80]))
        try data.write(to: URL(fileURLWithPath: path))
        defer { try? FileManager.default.removeItem(atPath: path) }
        #expect(throws: (any Error).self) {
            try RawStream(path: path, timestamps: [0, 0.033, 0.066])
        }
    }
}

@Suite struct SRTMarkupTests {
    @Test func stripsFormattingTags() throws {
        let srt = "1\n00:00:01,000 --> 00:00:02,000\n[Mary]<i> Eye movement detected.</i>\n\n"
            + "2\n00:00:03,000 --> 00:00:04,000\n<font color=\"#ff0000\"><b>Bold red</b></font>\n\n"
        let cues = try parseSRT(srt, file: "t")
        #expect(cues[0].text == "[Mary] Eye movement detected.")
        #expect(cues[1].text == "Bold red")
    }

    @Test func keepsNonTagAngleBrackets() throws {
        let cues = try parseSRT("1\n00:00:01,000 --> 00:00:02,000\n2 < 3 and 5 > 4\n\n", file: "t")
        #expect(cues[0].text == "2 < 3 and 5 > 4")
    }
}

/// SRT -> tx3g oracle: run our full conversion (parseSRT -> tx3gSamples -> AVAssetWriter),
/// then validate the result through Apple's independent tx3g implementation — AVFoundation
/// must parse the sample entry (it rejects malformed tx3g with -12712), and the samples
/// read back must decode, per 3GPP TS 26.245, to exactly the cue text and timing we put in.
/// Edge-case corpus modeled on FFmpeg's movtextenc concerns (UTF-8 multibyte, markup, overlaps).
@Suite struct SRTToTx3gOracleTests {
    static let corpus = """
    1
    00:00:00,500 --> 00:00:01,500
    Plain ASCII

    2
    00:00:02,000 --> 00:00:03,000
    <i>héllo wörld</i>

    3
    00:00:03,500 --> 00:00:04,500
    日本語テスト 🎬

    4
    00:00:05,000 --> 00:00:06,000
    two lines
    second <b>bold</b> line

    5
    00:00:06,500 --> 00:00:08,000
    overlap victim

    6
    00:00:07,000 --> 00:00:07,500
    swallowed by previous cue

    7
    00:00:08,500 --> 00:00:09,000
    2 < 3 and 5 > 4

    """

    static let expectedTexts = [
        "Plain ASCII",
        "héllo wörld",
        "日本語テスト 🎬",
        "two lines\nsecond bold line",
        "overlap victim",
        // cue 6 dropped (fully inside cue 5)
        "2 < 3 and 5 > 4",
    ]

    @Test func appleParsesAndDecodesOurOutput() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tx3g-oracle-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let mov = dir.appendingPathComponent("subs.mov")

        // our writer path
        let cues = try parseSRT(Self.corpus, file: "corpus")
        let fd = try tx3gFormatDescription()
        let samples = try tx3gSamples(cues, format: fd)
        let writer = try AVAssetWriter(outputURL: mov, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .subtitle, outputSettings: nil, sourceFormatHint: fd)
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        for sample in samples {
            while !input.isReadyForMoreMediaData { usleep(500) }
            #expect(input.append(sample), "Apple's writer rejected a tx3g sample")
        }
        input.markAsFinished()
        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        done.wait()
        #expect(writer.status == .completed)

        // Apple's reader: opening the asset parses the tx3g sample entry (oracle #1)
        let asset = AVURLAsset(url: mov)
        let loaded = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var track: AVAssetTrack?
        asset.loadTracks(withMediaType: .subtitle) { t, _ in track = t?.first; loaded.signal() }
        loaded.wait()
        let subTrack = try #require(track, "Apple did not recognize a subtitle track")

        let reader = try AVAssetReader(asset: asset)
        let out = AVAssetReaderTrackOutput(track: subTrack, outputSettings: nil)
        reader.add(out)
        #expect(reader.startReading())

        // decode payloads per 3GPP TS 26.245 (independent, read-side parser: production
        // code only ever writes tx3g) and collect non-empty cues with timing
        var texts: [String] = []
        var timing: [(start: Double, duration: Double)] = []
        while let sample = out.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
            var length = 0
            var ptr: UnsafeMutablePointer<CChar>?
            CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &ptr)
            let payload = Data(bytes: ptr!, count: length)
            #expect(payload.count >= 2, "tx3g sample shorter than its length field")
            let textLen = Int(payload[0]) << 8 | Int(payload[1])
            #expect(2 + textLen <= payload.count, "tx3g text length field exceeds sample size")
            let text = String(decoding: payload[2..<2 + textLen], as: UTF8.self)
            if !text.isEmpty {
                texts.append(text)
                timing.append((CMSampleBufferGetPresentationTimeStamp(sample).seconds,
                               CMSampleBufferGetDuration(sample).seconds))
            }
        }
        #expect(reader.status == .completed)

        #expect(texts == Self.expectedTexts)
        // spot-check timing survived the round trip
        #expect(abs(timing[0].start - 0.5) < 0.002)
        #expect(abs(timing[0].duration - 1.0) < 0.002)
        #expect(abs(timing[2].start - 3.5) < 0.002)   // UTF-8 cue
        #expect(abs(timing[4].start - 6.5) < 0.002)   // overlap victim keeps full range
        #expect(abs(timing[4].duration - 1.5) < 0.002)
        #expect(abs(timing[5].start - 8.5) < 0.002)
    }
}

/// StyleRecord support, TDD'd against FFmpeg movtextenc's wire format knowledge:
/// styl box = size(4) 'styl' count(2) then 12-byte records
/// {startChar(2) endChar(2) fontID(2) faceFlags(1) fontSize(1) rgba(4)},
/// offsets in CHARACTERS not bytes (the FFmpeg ticket-6021 UTF-8 fix),
/// flags: bold 1, italic 2, underline 4.
@Suite struct StyleSpanTests {
    func spans(_ srt: String) throws -> ([StyleSpan], String) {
        let cues = try parseSRT("1\n00:00:01,000 --> 00:00:02,000\n\(srt)\n\n", file: "t")
        return (cues[0].styles, cues[0].text)
    }

    @Test func wholeCueItalic() throws {
        let (styles, text) = try spans("<i>whisper</i>")
        #expect(text == "whisper")
        #expect(styles == [StyleSpan(start: 0, end: 7, flags: 2)])
    }

    @Test func partialBold() throws {
        let (styles, text) = try spans("say <b>bold</b> thing")
        #expect(text == "say bold thing")
        #expect(styles == [StyleSpan(start: 4, end: 8, flags: 1)])
    }

    @Test func nestedTagsMergeFlags() throws {
        let (styles, text) = try spans("<i>a<b>b</b>c</i>")
        #expect(text == "abc")
        #expect(styles == [StyleSpan(start: 0, end: 1, flags: 2),
                           StyleSpan(start: 1, end: 2, flags: 3),
                           StyleSpan(start: 2, end: 3, flags: 2)])
    }

    @Test func multibyteOffsetsAreCharactersNotBytes() throws {
        // 日本語 = 3 characters (9 UTF-8 bytes); offsets must be 3..6, not 9..18
        let (styles, text) = try spans("日本語<i>テスト</i>")
        #expect(text == "日本語テスト")
        #expect(styles == [StyleSpan(start: 3, end: 6, flags: 2)])
    }

    @Test func underline() throws {
        let (styles, _) = try spans("<u>under</u>")
        #expect(styles == [StyleSpan(start: 0, end: 5, flags: 4)])
    }

    @Test func fontTagStrippedNoSpan() throws {
        let (styles, text) = try spans("<font color=\"#ff0000\">red</font>")
        #expect(text == "red")
        #expect(styles.isEmpty)
    }

    @Test func unclosedTagRunsToEnd() throws {
        let (styles, text) = try spans("<i>oops no close")
        #expect(text == "oops no close")
        #expect(styles == [StyleSpan(start: 0, end: 13, flags: 2)])
    }

    @Test func multilineSpansCrossNewline() throws {
        let (styles, text) = try spans("<i>line one\nline two</i>")
        #expect(text == "line one\nline two")
        #expect(styles == [StyleSpan(start: 0, end: 17, flags: 2)])
    }
}

@Suite struct StylBoxTests {
    /// Decode a tx3g sample payload per TS 26.245: text-length + utf8 + optional atoms.
    func decode(_ payload: Data) -> (text: String, records: [(Int, Int, UInt8)]) {
        let textLen = Int(payload[0]) << 8 | Int(payload[1])
        let text = String(decoding: payload[2..<2 + textLen], as: UTF8.self)
        var records: [(Int, Int, UInt8)] = []
        var i = 2 + textLen
        while i + 8 <= payload.count {
            let size = payload[i..<i+4].reduce(0) { $0 << 8 | Int($1) }
            let tag = String(decoding: payload[i+4..<i+8], as: UTF8.self)
            if tag == "styl" {
                let count = Int(payload[i+8]) << 8 | Int(payload[i+9])
                var j = i + 10
                for _ in 0..<count {
                    let start = Int(payload[j]) << 8 | Int(payload[j+1])
                    let end = Int(payload[j+2]) << 8 | Int(payload[j+3])
                    let flags = payload[j+6]
                    records.append((start, end, flags))
                    j += 12
                }
            }
            i += size
        }
        return (text, records)
    }

    func payload(of sample: CMSampleBuffer) -> Data {
        let block = CMSampleBufferGetDataBuffer(sample)!
        var length = 0
        var ptr: UnsafeMutablePointer<CChar>?
        CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &ptr)
        return Data(bytes: ptr!, count: length)
    }

    @Test func stylBoxWrittenWithFFmpegLayout() throws {
        let fd = try tx3gFormatDescription()
        let cue = SRTCue(start: 0, end: 1, text: "say bold thing",
                         styles: [StyleSpan(start: 4, end: 8, flags: 1)])
        let samples = try tx3gSamples([cue], format: fd)
        let (text, records) = decode(payload(of: samples[0]))
        #expect(text == "say bold thing")
        #expect(records.count == 1)
        #expect(records[0] == (4, 8, 1))
    }

    @Test func noStylesNoBox() throws {
        let fd = try tx3gFormatDescription()
        let samples = try tx3gSamples([SRTCue(start: 0, end: 1, text: "plain")], format: fd)
        #expect(payload(of: samples[0]).count == 2 + 5)  // just length + text
    }

    @Test func multipleRecords() throws {
        let fd = try tx3gFormatDescription()
        let cue = SRTCue(start: 0, end: 1, text: "abc",
                         styles: [StyleSpan(start: 0, end: 1, flags: 2),
                                  StyleSpan(start: 1, end: 2, flags: 3),
                                  StyleSpan(start: 2, end: 3, flags: 2)])
        let samples = try tx3gSamples([cue], format: fd)
        let (_, records) = decode(payload(of: samples[0]))
        #expect(records.map { $0.2 } == [2, 3, 2])
    }
}
