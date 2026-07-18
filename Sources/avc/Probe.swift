import ArgumentParser
import AVFoundation
import Foundation

struct Probe: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Print tracks, codecs, durations, formats.")

    @Option(name: .shortAndLong, help: "Input file.")
    var input: String

    func run() async throws {
        try await exitOnMediaError { try await probe() }
    }

    func probe() async throws {
        let url = URL(fileURLWithPath: input)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ValidationError("no such file: \(input)")
        }
        let asset = AVURLAsset(url: url)
        let (duration, tracks) = try await mediaOp("loading asset \(input)") {
            try await asset.load(.duration, .tracks)
        }

        print("\(input): duration \(fmt(duration))")
        for track in tracks {
            let type = track.mediaType.rawValue
            var line = "  track #\(track.trackID) [\(type)]"
            let (formats, size, rate, frameRate, timeRange) = try await track.load(
                .formatDescriptions, .naturalSize, .estimatedDataRate, .nominalFrameRate, .timeRange)
            for fd in formats {
                let fourcc = fourCC(CMFormatDescriptionGetMediaSubType(fd))
                line += " codec=\(fourcc)"
                if track.mediaType == .audio,
                   let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fd)?.pointee {
                    line += " \(Int(asbd.mSampleRate))Hz \(asbd.mChannelsPerFrame)ch"
                }
            }
            if track.mediaType == .video {
                line += " \(Int(size.width))x\(Int(size.height))"
                if frameRate > 0 { line += String(format: " %.3ffps", frameRate) }
                let color = colorInfo(formats.first)
                if let props = color.avProperties {
                    line += " \(props[AVVideoColorPrimariesKey]!)/\(props[AVVideoTransferFunctionKey]!)"
                    if color.isHDR { line += " HDR" }
                }
            }
            line += String(format: " %.1fkb/s", rate / 1000)
            line += " duration \(fmt(timeRange.duration))"
            print(line)
        }
    }
}

func fourCC(_ code: FourCharCode) -> String {
    let bytes = [24, 16, 8, 0].map { UInt8((code >> $0) & 0xFF) }
    return String(bytes: bytes, encoding: .ascii)?
        .trimmingCharacters(in: .whitespaces) ?? String(code)
}

func fmt(_ time: CMTime) -> String {
    guard time.isNumeric else { return "n/a" }
    return String(format: "%.3fs", time.seconds)
}
