import ArgumentParser
import AVFoundation
import Foundation

let knownStatus: [Int: (name: String, meaning: String)] = [
    -12902: ("kVTParameterErr", "a parameter passed to VideoToolbox was invalid"),
    -12905: ("kVTInvalidSessionErr", "the VideoToolbox session is invalid or was torn down"),
    -12909: ("kVTVideoDecoderBadDataErr", "the decoder was given corrupt or malformed data"),
    -12910: ("kVTVideoDecoderUnsupportedDataFormatErr", "the decoder does not support this data format"),
    -12911: ("kVTVideoDecoderMalfunctionErr", "the video decoder malfunctioned"),
    -12912: ("kVTVideoEncoderMalfunctionErr", "the video encoder malfunctioned"),
    -12785: ("kVTCouldNotFindVideoDecoderErr", "no video decoder is available for this format"),
    -12710: ("kCMFormatDescriptionBridgeError_InvalidParameter", "invalid parameter creating/converting a format description"),
    -11800: ("AVErrorUnknown", "unknown AVFoundation error; the underlying error carries the real cause"),
    -11828: ("AVErrorFileFormatNotRecognized", "the file format is not recognized by AVFoundation"),
    -11829: ("AVErrorFileFailedToParse", "the file is recognized but could not be parsed"),
    -12847: ("kCMFormatReaderError_UnsupportedFormat", "CoreMedia format reader does not support this format"),
]

func describe(_ status: OSStatus) -> String {
    if let known = knownStatus[Int(status)] {
        return "\(status) (\(known.name): \(known.meaning))"
    }
    return "\(status) (unknown code; look up in VTErrors.h / CMFormatDescriptionBridge.h)"
}

let hints: [Int: String] = [
    -12902: "this often means the compression settings are incompatible with the source format; run `avc probe` on the input and check pixel format / dimensions",
    -12910: "the source uses a format this decoder cannot handle; run `avc probe` on the input to see its codec",
    -11828: "the container format is not readable by AVFoundation (e.g. mkv/webm); remux it to mp4/mov first",
]

struct MediaError: Error {
    let operation: String
    let underlying: Error?

    init(_ operation: String, underlying: Error? = nil) {
        self.operation = operation
        self.underlying = underlying
    }

    var message: String {
        var out = "error: \(operation)"
        var hint: String?
        if let underlying {
            out += "\n" + describe(underlying)
            var err: NSError? = underlying as NSError
            while let e = err {
                if hint == nil { hint = hints[e.code] }
                err = e.userInfo[NSUnderlyingErrorKey] as? NSError
            }
        }
        if let hint { out += "\nhint: \(hint)" }
        return out
    }
}

/// Run a media operation; on failure wrap the error with the operation name.
func mediaOp<T>(_ operation: String, _ body: () async throws -> T) async throws -> T {
    do { return try await body() } catch { throw MediaError("\(operation) failed", underlying: error) }
}

func mediaOp<T>(_ operation: String, _ body: () throws -> T) throws -> T {
    do { return try body() } catch { throw MediaError("\(operation) failed", underlying: error) }
}

/// Catch MediaError, print per the error contract, exit 2.
func exitOnMediaError(_ body: () async throws -> Void) async throws {
    do { try await body() } catch let error as MediaError {
        FileHandle.standardError.write(Data(error.message.appending("\n").utf8))
        throw ExitCode(2)
    } catch let error as ValidationError {
        FileHandle.standardError.write(Data("error: \(error.message)\n".utf8))
        throw ExitCode(1)
    }
}

/// Full domain/code chain, one line per level, walking NSUnderlyingError.
func describe(_ error: Error) -> String {
    var lines: [String] = []
    var current: NSError? = error as NSError
    var depth = 0
    while let err = current {
        // symbolic OSStatus names only make sense for CoreMedia/AVFoundation domains;
        // other domains (Cocoa, POSIX...) get their code printed untranslated
        let mediaDomain = err.domain == NSOSStatusErrorDomain || err.domain == AVFoundationErrorDomain
        let code = mediaDomain && err.code >= Int(Int32.min) && err.code <= Int(Int32.max)
            ? describe(OSStatus(err.code))
            : "\(err.code)"
        var line = depth == 0 ? "  " : "  " + String(repeating: "   ", count: depth - 1) + "└─ "
        line += "\(err.domain) \(code)"
        if !err.localizedDescription.isEmpty, !err.localizedDescription.hasPrefix("The operation couldn’t be completed") {
            line += " — \(err.localizedDescription)"
        }
        lines.append(line)
        current = err.userInfo[NSUnderlyingErrorKey] as? NSError
        depth += 1
    }
    return lines.joined(separator: "\n")
}
