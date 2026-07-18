// Fixture generator for test.sh: swift gen-fixtures.swift <dir>
// Writes video.mp4 (SDR h264), hdr.mov (HLG 10-bit HEVC), subbed.mov (video + tx3g subtitles).
import AVFoundation
import VideoToolbox

let dir = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)

func writeVideo(to out: URL, settings: [String: Any], pixelFormat: OSType, frames: Int) throws {
    try? FileManager.default.removeItem(at: out)
    let writer = try AVAssetWriter(outputURL: out, fileType: out.pathExtension == "mov" ? .mov : .mp4)
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: pixelFormat,
        kCVPixelBufferWidthKey as String: 640, kCVPixelBufferHeightKey as String: 360,
    ])
    writer.add(input)
    writer.startWriting()
    writer.startSession(atSourceTime: .zero)
    for frame in 0..<frames {
        while !input.isReadyForMoreMediaData { usleep(1000) }
        var pb: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &pb)
        CVPixelBufferLockBaseAddress(pb!, [])
        memset(CVPixelBufferGetBaseAddress(pb!), Int32(frame * 4 % 255), CVPixelBufferGetDataSize(pb!))
        CVPixelBufferUnlockBaseAddress(pb!, [])
        adaptor.append(pb!, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 30))
    }
    input.markAsFinished()
    let sema = DispatchSemaphore(value: 0)
    writer.finishWriting { sema.signal() }
    sema.wait()
    guard writer.status == .completed else { fatalError("\(out.lastPathComponent): \(String(describing: writer.error))") }
}

// tx3g TextSampleEntry atom per 3GPP TS 26.245
func be16(_ v: Int) -> [UInt8] { [UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)] }
func be32(_ v: Int) -> [UInt8] { [UInt8(v >> 24 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)] }

func tx3gFormatDescription() -> CMFormatDescription {
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
    guard status == 0, let fd else { fatalError("tx3g format desc: \(status)") }
    return fd
}

func subtitleSample(_ fd: CMFormatDescription, _ text: String, start: Double, dur: Double) -> CMSampleBuffer {
    var payload = Data()
    payload.append(contentsOf: be16(text.utf8.count))
    payload.append(Data(text.utf8))
    var block: CMBlockBuffer?
    CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: payload.count,
        blockAllocator: nil, customBlockSource: nil, offsetToData: 0, dataLength: payload.count,
        flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block)
    _ = payload.withUnsafeBytes { CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block!, offsetIntoDestination: 0, dataLength: payload.count) }
    var timing = CMSampleTimingInfo(
        duration: CMTime(seconds: dur, preferredTimescale: 600),
        presentationTimeStamp: CMTime(seconds: start, preferredTimescale: 600),
        decodeTimeStamp: .invalid)
    var size = payload.count
    var sample: CMSampleBuffer?
    CMSampleBufferCreateReady(allocator: nil, dataBuffer: block!, formatDescription: fd,
        sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
        sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample)
    return sample!
}

func writeSubbed(from src: URL, to out: URL) throws {
    try? FileManager.default.removeItem(at: out)
    let fd = tx3gFormatDescription()
    let asset = AVURLAsset(url: src)
    let sema0 = DispatchSemaphore(value: 0)
    nonisolated(unsafe) var videoTrack: AVAssetTrack!
    nonisolated(unsafe) var vFmt: CMFormatDescription!
    asset.loadTracks(withMediaType: .video) { t, _ in
        videoTrack = t!.first
        videoTrack.loadValuesAsynchronously(forKeys: ["formatDescriptions"]) {
            vFmt = (videoTrack.formatDescriptions as! [CMFormatDescription]).first
            sema0.signal()
        }
    }
    sema0.wait()
    let reader = try AVAssetReader(asset: asset)
    let vOut = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: nil)
    reader.add(vOut)
    let writer = try AVAssetWriter(outputURL: out, fileType: .mov)
    let vIn = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: vFmt)
    let sIn = AVAssetWriterInput(mediaType: .subtitle, outputSettings: nil, sourceFormatHint: fd)
    writer.add(vIn); writer.add(sIn)
    reader.startReading(); writer.startWriting()
    writer.startSession(atSourceTime: .zero)
    let sema = DispatchSemaphore(value: 0)
    vIn.requestMediaDataWhenReady(on: DispatchQueue(label: "v")) {
        while vIn.isReadyForMoreMediaData {
            guard let s = vOut.copyNextSampleBuffer() else { vIn.markAsFinished(); sema.signal(); return }
            vIn.append(s)
        }
    }
    sema.wait()
    for (i, text) in ["Hello", "World"].enumerated() {
        while !sIn.isReadyForMoreMediaData { usleep(1000) }
        sIn.append(subtitleSample(fd, text, start: Double(i), dur: 1))
    }
    sIn.markAsFinished()
    let sema2 = DispatchSemaphore(value: 0)
    writer.finishWriting { sema2.signal() }
    sema2.wait()
    guard writer.status == .completed else { fatalError("subbed.mov: \(String(describing: writer.error))") }
}

let video = dir.appendingPathComponent("video.mp4")
try writeVideo(to: video, settings: [
    AVVideoCodecKey: AVVideoCodecType.h264,
    AVVideoWidthKey: 640, AVVideoHeightKey: 360,
], pixelFormat: kCVPixelFormatType_32BGRA, frames: 60)

try writeVideo(to: dir.appendingPathComponent("hdr.mov"), settings: [
    AVVideoCodecKey: AVVideoCodecType.hevc,
    AVVideoWidthKey: 640, AVVideoHeightKey: 360,
    AVVideoCompressionPropertiesKey: [AVVideoProfileLevelKey: kVTProfileLevel_HEVC_Main10_AutoLevel as String],
    AVVideoColorPropertiesKey: [
        AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_2020,
        AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_2100_HLG,
        AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_2020,
    ],
], pixelFormat: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange, frames: 30)

try writeSubbed(from: video, to: dir.appendingPathComponent("subbed.mov"))
print("ok")
