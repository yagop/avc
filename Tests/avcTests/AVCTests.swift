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
