// SRT parsing, markup scanning, and tx3g (3GPP TS 26.245) synthesis.
import AVFoundation
import Foundation

/// Scan SRT markup: strip <i>/<b>/<u>/<font> tags, return plain text plus styled
/// character ranges (character offsets, not bytes — the classic tx3g pitfall).
func parseSRTMarkup(_ raw: String) -> (text: String, styles: [StyleSpan]) {
    var text = ""
    var count = 0                 // characters appended so far
    var styles: [StyleSpan] = []
    var bold = 0, italic = 0, underline = 0
    var flags: UInt8 = 0
    var runStart = 0

    // a tag boundary may change the active flags: close the open run, start the next
    func updateFlags() {
        let new: UInt8 = (bold > 0 ? 1 : 0) | (italic > 0 ? 2 : 0) | (underline > 0 ? 4 : 0)
        guard new != flags else { return }
        if flags != 0, count > runStart { styles.append(StyleSpan(start: runStart, end: count, flags: flags)) }
        flags = new
        runStart = count
    }

    var i = raw.startIndex
    while i < raw.endIndex {
        if raw[i] == "<", let close = raw[i...].firstIndex(of: ">") {
            let tag = raw[raw.index(after: i)..<close].lowercased()
            let delta = tag.hasPrefix("/") ? -1 : 1
            let name = tag.drop(while: { $0 == "/" }).prefix(while: { $0 != " " })
            switch name {
            case "i": italic = max(0, italic + delta)
            case "b": bold = max(0, bold + delta)
            case "u": underline = max(0, underline + delta)
            case "font": break    // color not carried into tx3g; tag stripped
            default:
                // not a known tag: keep the literal '<' and continue scanning after it
                text.append(raw[i]); count += 1
                i = raw.index(after: i)
                continue
            }
            updateFlags()
            i = raw.index(after: close)
            continue
        }
        text.append(raw[i]); count += 1
        i = raw.index(after: i)
    }
    if flags != 0, count > runStart { styles.append(StyleSpan(start: runStart, end: count, flags: flags)) }

    // trim whitespace; spans shift by the leading trim and clamp to the new length
    let leading = text.prefix(while: \.isWhitespace).count
    text = text.trimmingCharacters(in: .whitespacesAndNewlines)
    styles = styles.compactMap { span in
        let start = max(0, span.start - leading)
        let end = min(text.count, span.end - leading)
        return end > start ? StyleSpan(start: start, end: end, flags: span.flags) : nil
    }
    return (text, styles)
}

struct SRTCue {
    let start: Double
    let end: Double
    let text: String
    var styles: [StyleSpan] = []
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
        let raw = lines.dropFirst().joined(separator: "\n")
        let (text, styles) = parseSRTMarkup(raw)
        if !text.isEmpty { cues.append(SRTCue(start: start, end: end, text: text, styles: styles)) }
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
/// Parse an .srt file and register a tx3g writer input for it; returns the samples to pump.
func makeSRTFeed(path: String, writer: AVAssetWriter, fileType: AVFileType,
                 label: String, verbose: Bool) throws -> (samples: [CMSampleBuffer], in: AVAssetWriterInput, label: String) {
    let text = try mediaOp("reading \(path)") { try String(contentsOfFile: path, encoding: .utf8) }
    let cues = try parseSRT(text, file: path)
    let fd = try tx3gFormatDescription()
    let input = AVAssetWriterInput(mediaType: .subtitle, outputSettings: nil, sourceFormatHint: fd)
    input.expectsMediaDataInRealTime = false
    guard writer.canAdd(input) else {
        throw MediaError("cannot write subtitle track (tx3g) from \(path) into \(fileType.rawValue) container")
    }
    writer.add(input)
    if verbose { print("subtitles: \(path) \(cues.count) cues [srt -> tx3g]") }
    return (try tx3gSamples(cues, format: fd), input, label)
}

func tx3gSamples(_ cues: [SRTCue], format: CMFormatDescription) throws -> [CMSampleBuffer] {
    var samples: [CMSampleBuffer] = []
    var cursor = 0.0
    for cue in cues {
        // overlapping cues: clip to the end of the previous one; fully-contained cues are dropped
        guard cue.end > cursor else { continue }
        if cue.start > cursor {
            samples.append(try tx3gSample("", format: format, start: cursor, end: cue.start))
        }
        samples.append(try tx3gSample(cue.text, format: format, start: max(cue.start, cursor), end: cue.end, styles: cue.styles))
        cursor = max(cursor, cue.end)
    }
    return samples
}

func tx3gSample(_ text: String, format: CMFormatDescription, start: Double, end: Double,
                styles: [StyleSpan] = []) throws -> CMSampleBuffer {
    var payload = Data()
    payload.append(contentsOf: be16(text.utf8.count))
    payload.append(Data(text.utf8))
    if !styles.isEmpty {
        // TextStyleBox per TS 26.245: size 'styl' count, then 12-byte StyleRecords
        // {startChar endChar fontID faceFlags fontSize rgba}; offsets are characters
        payload.append(contentsOf: be32(10 + styles.count * 12))
        payload.append(Data("styl".utf8))
        payload.append(contentsOf: be16(styles.count))
        for span in styles {
            payload.append(contentsOf: be16(span.start))
            payload.append(contentsOf: be16(span.end))
            payload.append(contentsOf: be16(1))            // fontID, matches sample entry
            payload.append(span.flags)
            payload.append(12)                              // font size, matches sample entry
            payload.append(contentsOf: [255, 255, 255, 255]) // white, opaque
        }
    }
    let timing = CMSampleTimingInfo(
        duration: CMTime(seconds: end - start, preferredTimescale: 600),
        presentationTimeStamp: CMTime(seconds: start, preferredTimescale: 600),
        decodeTimeStamp: .invalid)
    return try makeSampleBuffer(payload, format: format, timing: timing, sync: true,
                                what: "tx3g sample at \(start)s")
}

