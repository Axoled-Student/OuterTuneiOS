import Foundation

/// Lightweight remuxer that converts DASH fragmented MP4 (fMP4) to standard M4A.
///
/// YouTube's adaptive audio streams use DASH fMP4 format (ftyp/dash, moof+mdat segments),
/// which CoreMedia/AVFoundation on iOS/macOS cannot play directly.
/// This remuxer parses the fMP4 and rebuilds it as a standard M4A with a proper sample table.
enum DashRemuxer {

    struct RemuxError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    // MARK: - Public API

    /// Remux DASH fMP4 data to standard M4A data that AVPlayer can play.
    /// - Parameter dashData: Complete DASH fMP4 file data.
    /// - Returns: Standard M4A data, or nil if remuxing fails.
    static func remux(_ dashData: Data) -> Data? {
        do {
            return try performRemux(dashData)
        } catch {
            print("[DashRemuxer] remux failed: \(error)")
            return nil
        }
    }

    // MARK: - Internal Types

    private struct MP4Box {
        let type: String
        let offset: Int
        let size: Int
        var dataRange: Range<Int> { (offset + 8)..<(offset + size) }
    }

    private struct SampleInfo {
        let duration: UInt32
        let size: UInt32
    }

    private struct FragmentDefaults {
        var defaultSampleDuration: UInt32 = 0
        var defaultSampleSize: UInt32 = 0
    }

    // MARK: - Core Remux Logic

    private static func performRemux(_ data: Data) throws -> Data {
        let topBoxes = parseBoxes(in: data, range: 0..<data.count)

        // Extract moov box (contains track metadata, codec config)
        guard let moovBox = topBoxes.first(where: { $0.type == "moov" }) else {
            throw RemuxError(message: "No moov box found")
        }

        // Get trex defaults from mvex
        let trexDefaults = extractTrexDefaults(from: data, moovBox: moovBox)

        // Find stsd box (codec sample description) inside moov
        guard let stsdData = findBoxData(in: data, moovBox: moovBox, path: ["trak", "mdia", "minf", "stbl", "stsd"]) else {
            throw RemuxError(message: "No stsd box in moov")
        }

        // Extract timescale from mdhd
        let timescale = extractTimescale(from: data, moovBox: moovBox) ?? 44100

        // Parse all moof+mdat pairs to collect samples and audio data
        var samples: [SampleInfo] = []
        var audioPayload = Data()

        var i = 0
        while i < topBoxes.count {
            if topBoxes[i].type == "moof" {
                // Only process moof+mdat pairs — skip orphan moofs (e.g. truncated files)
                if i + 1 < topBoxes.count && topBoxes[i + 1].type == "mdat" {
                    let moofBox = topBoxes[i]
                    let fragmentDefaults = extractFragmentDefaults(from: data, moofBox: moofBox, trexDefaults: trexDefaults)
                    let fragmentSamples = parseTrun(from: data, moofBox: moofBox, defaults: fragmentDefaults)
                    samples.append(contentsOf: fragmentSamples)

                    let mdatBox = topBoxes[i + 1]
                    let mdatPayload = data[mdatBox.dataRange]
                    audioPayload.append(mdatPayload)
                    i += 2
                    continue
                }
            }
            i += 1
        }

        guard !samples.isEmpty else {
            throw RemuxError(message: "No samples found in moof boxes")
        }

        // Calculate total duration
        let totalDuration: UInt64 = samples.reduce(0) { $0 + UInt64($1.duration) }

        // Build the new M4A
        let newFtyp = buildFtypBox()
        let newMdat = buildMdatBox(payload: audioPayload)

        // Build moov with a placeholder stco offset, then fix it
        let moovContent = buildMoovContent(
            stsdData: stsdData,
            samples: samples,
            timescale: UInt32(timescale),
            totalDuration: totalDuration,
            mdatPayloadOffset: 0 // placeholder
        )
        let moovSize = moovContent.count + 8
        let actualMdatPayloadOffset = UInt32(newFtyp.count + moovSize + 8)

        let finalMoovContent = buildMoovContent(
            stsdData: stsdData,
            samples: samples,
            timescale: UInt32(timescale),
            totalDuration: totalDuration,
            mdatPayloadOffset: actualMdatPayloadOffset
        )

        var result = Data()
        result.append(newFtyp)
        result.append(writeBox(type: "moov", content: finalMoovContent))
        result.append(newMdat)

        return result
    }

    // MARK: - Box Parsing

    private static func parseBoxes(in data: Data, range: Range<Int>) -> [MP4Box] {
        var boxes: [MP4Box] = []
        var pos = range.lowerBound
        while pos + 8 <= range.upperBound {
            let size = Int(data.readUInt32BE(at: pos))
            guard size >= 8 && pos + size <= range.upperBound else { break }
            let type = data.readASCII(at: pos + 4, length: 4)
            boxes.append(MP4Box(type: type, offset: pos, size: size))
            pos += size
        }
        return boxes
    }

    private static func findBoxData(in data: Data, moovBox: MP4Box, path: [String]) -> Data? {
        var currentRange = moovBox.dataRange
        for name in path {
            let children = parseBoxes(in: data, range: currentRange)
            guard let child = children.first(where: { $0.type == name }) else { return nil }
            currentRange = child.dataRange
        }
        return Data(data[currentRange])
    }

    // MARK: - Metadata Extraction

    private static func extractTimescale(from data: Data, moovBox: MP4Box) -> Int? {
        guard let mdhdData = findBoxData(in: data, moovBox: moovBox, path: ["trak", "mdia", "mdhd"]) else { return nil }
        // mdhd: version(1) + flags(3) + ...
        // v0: creation(4) + modification(4) + timescale(4)
        // v1: creation(8) + modification(8) + timescale(4)
        guard mdhdData.count >= 4 else { return nil }
        let version = mdhdData[0]
        if version == 0 && mdhdData.count >= 16 {
            return Int(mdhdData.readUInt32BE(at: 12))
        } else if version == 1 && mdhdData.count >= 24 {
            return Int(mdhdData.readUInt32BE(at: 20))
        }
        return nil
    }

    private static func extractTrexDefaults(from data: Data, moovBox: MP4Box) -> FragmentDefaults {
        var defaults = FragmentDefaults()
        guard let trexData = findBoxData(in: data, moovBox: moovBox, path: ["mvex", "trex"]) else { return defaults }
        // trex: version(1) + flags(3) + track_id(4) + default_sample_description_index(4)
        //       + default_sample_duration(4) + default_sample_size(4) + default_sample_flags(4)
        guard trexData.count >= 20 else { return defaults }
        defaults.defaultSampleDuration = trexData.readUInt32BE(at: 12)
        defaults.defaultSampleSize = trexData.readUInt32BE(at: 16)
        return defaults
    }

    private static func extractFragmentDefaults(from data: Data, moofBox: MP4Box, trexDefaults: FragmentDefaults) -> FragmentDefaults {
        var defaults = trexDefaults
        let moofChildren = parseBoxes(in: data, range: moofBox.dataRange)
        guard let trafBox = moofChildren.first(where: { $0.type == "traf" }) else { return defaults }

        let trafChildren = parseBoxes(in: data, range: trafBox.dataRange)
        guard let tfhdBox = trafChildren.first(where: { $0.type == "tfhd" }) else { return defaults }

        let tfhdData = Data(data[tfhdBox.dataRange])
        guard tfhdData.count >= 8 else { return defaults }

        let flags = UInt32(tfhdData[1]) << 16 | UInt32(tfhdData[2]) << 8 | UInt32(tfhdData[3])
        var offset = 8 // skip version(1) + flags(3) + track_id(4)

        if flags & 0x01 != 0 { offset += 8 } // base_data_offset
        if flags & 0x02 != 0 { offset += 4 } // sample_description_index

        if flags & 0x08 != 0 && offset + 4 <= tfhdData.count {
            defaults.defaultSampleDuration = tfhdData.readUInt32BE(at: offset)
            offset += 4
        }
        if flags & 0x10 != 0 && offset + 4 <= tfhdData.count {
            defaults.defaultSampleSize = tfhdData.readUInt32BE(at: offset)
        }

        return defaults
    }

    // MARK: - trun Parsing

    private static func parseTrun(from data: Data, moofBox: MP4Box, defaults: FragmentDefaults) -> [SampleInfo] {
        let moofChildren = parseBoxes(in: data, range: moofBox.dataRange)
        guard let trafBox = moofChildren.first(where: { $0.type == "traf" }) else { return [] }

        let trafChildren = parseBoxes(in: data, range: trafBox.dataRange)
        var allSamples: [SampleInfo] = []

        for trunBox in trafChildren where trunBox.type == "trun" {
            let trunData = Data(data[trunBox.dataRange])
            guard trunData.count >= 8 else { continue }

            let flags = UInt32(trunData[1]) << 16 | UInt32(trunData[2]) << 8 | UInt32(trunData[3])
            let sampleCount = Int(trunData.readUInt32BE(at: 4))

            var offset = 8
            if flags & 0x001 != 0 { offset += 4 } // data_offset
            if flags & 0x004 != 0 { offset += 4 } // first_sample_flags

            let hasDuration = flags & 0x100 != 0
            let hasSize = flags & 0x200 != 0
            let hasFlags = flags & 0x400 != 0
            let hasCompOffset = flags & 0x800 != 0

            for _ in 0..<sampleCount {
                var duration = defaults.defaultSampleDuration
                var size = defaults.defaultSampleSize

                if hasDuration && offset + 4 <= trunData.count {
                    duration = trunData.readUInt32BE(at: offset)
                    offset += 4
                }
                if hasSize && offset + 4 <= trunData.count {
                    size = trunData.readUInt32BE(at: offset)
                    offset += 4
                }
                if hasFlags { offset += 4 }
                if hasCompOffset { offset += 4 }

                allSamples.append(SampleInfo(duration: duration, size: size))
            }
        }

        return allSamples
    }

    // MARK: - M4A Construction

    private static func buildFtypBox() -> Data {
        var content = Data()
        content.append(ascii: "M4A ") // major brand
        content.appendUInt32BE(0x0200) // minor version
        content.append(ascii: "M4A ") // compatible brand
        content.append(ascii: "isom") // compatible brand
        content.append(ascii: "iso2") // compatible brand
        return writeBox(type: "ftyp", content: content)
    }

    private static func buildMdatBox(payload: Data) -> Data {
        if payload.count + 8 > UInt32.max {
            // Use 64-bit extended size
            var box = Data()
            box.appendUInt32BE(1) // signals 64-bit size follows
            box.append(ascii: "mdat")
            box.appendUInt64BE(UInt64(payload.count + 16))
            box.append(payload)
            return box
        }
        return writeBox(type: "mdat", content: payload)
    }

    private static func buildMoovContent(
        stsdData: Data,
        samples: [SampleInfo],
        timescale: UInt32,
        totalDuration: UInt64,
        mdatPayloadOffset: UInt32
    ) -> Data {
        // mvhd
        let mvhd = buildMvhd(timescale: timescale, duration: totalDuration)

        // trak
        let tkhd = buildTkhd(duration: totalDuration, timescale: timescale)
        let mdhd = buildMdhd(timescale: timescale, duration: totalDuration)
        let hdlr = buildHdlr()
        let smhd = buildSmhd()
        let dinf = buildDinf()

        let stts = buildStts(samples: samples)
        let stsz = buildStsz(samples: samples)
        let stsc = buildStsc(sampleCount: UInt32(samples.count))
        let stco = buildStco(offset: mdatPayloadOffset)
        let stsdBox = writeBox(type: "stsd", content: stsdData)

        let stbl = writeBox(type: "stbl", content: stsdBox + stts + stsz + stsc + stco)
        let minf = writeBox(type: "minf", content: smhd + dinf + stbl)
        let mdia = writeBox(type: "mdia", content: mdhd + hdlr + minf)
        let trak = writeBox(type: "trak", content: tkhd + mdia)

        return mvhd + trak
    }

    // MARK: - Box Builders

    private static func buildMvhd(timescale: UInt32, duration: UInt64) -> Data {
        // version 0: durations in movie timescale
        // We use timescale=1000 for mvhd (movie-level)
        let movieTimescale: UInt32 = 1000
        let movieDuration = UInt32(duration * UInt64(movieTimescale) / UInt64(timescale))

        var content = Data()
        content.appendUInt32BE(0) // creation_time
        content.appendUInt32BE(0) // modification_time
        content.appendUInt32BE(movieTimescale) // timescale
        content.appendUInt32BE(movieDuration) // duration
        content.appendUInt32BE(0x00010000) // rate = 1.0
        content.appendUInt16BE(0x0100) // volume = 1.0
        content.append(Data(count: 10)) // reserved
        // Matrix (9 * 4 = 36 bytes) - identity
        let matrix: [UInt32] = [0x00010000, 0, 0, 0, 0x00010000, 0, 0, 0, 0x40000000]
        for val in matrix { content.appendUInt32BE(val) }
        content.append(Data(count: 24)) // pre-defined
        content.appendUInt32BE(2) // next_track_ID

        return writeFullBox(type: "mvhd", version: 0, flags: 0, content: content)
    }

    private static func buildTkhd(duration: UInt64, timescale: UInt32) -> Data {
        let movieTimescale: UInt32 = 1000
        let movieDuration = UInt32(duration * UInt64(movieTimescale) / UInt64(timescale))

        var content = Data()
        content.appendUInt32BE(0) // creation_time
        content.appendUInt32BE(0) // modification_time
        content.appendUInt32BE(1) // track_ID
        content.appendUInt32BE(0) // reserved
        content.appendUInt32BE(movieDuration) // duration
        content.append(Data(count: 8)) // reserved
        content.appendUInt16BE(0) // layer
        content.appendUInt16BE(0) // alternate_group
        content.appendUInt16BE(0x0100) // volume = 1.0 (audio track)
        content.appendUInt16BE(0) // reserved
        let matrix: [UInt32] = [0x00010000, 0, 0, 0, 0x00010000, 0, 0, 0, 0x40000000]
        for val in matrix { content.appendUInt32BE(val) }
        content.appendUInt32BE(0) // width
        content.appendUInt32BE(0) // height

        return writeFullBox(type: "tkhd", version: 0, flags: 3, content: content) // flags=3: track_enabled | track_in_movie
    }

    private static func buildMdhd(timescale: UInt32, duration: UInt64) -> Data {
        var content = Data()
        content.appendUInt32BE(0) // creation_time
        content.appendUInt32BE(0) // modification_time
        content.appendUInt32BE(timescale)
        content.appendUInt32BE(UInt32(min(duration, UInt64(UInt32.max))))
        content.appendUInt16BE(0x55C4) // language: undetermined
        content.appendUInt16BE(0) // pre_defined

        return writeFullBox(type: "mdhd", version: 0, flags: 0, content: content)
    }

    private static func buildHdlr() -> Data {
        var content = Data()
        content.appendUInt32BE(0) // pre_defined
        content.append(ascii: "soun") // handler_type
        content.append(Data(count: 12)) // reserved
        content.append("SoundHandler".data(using: .utf8)!)
        content.append(0) // null terminator

        return writeFullBox(type: "hdlr", version: 0, flags: 0, content: content)
    }

    private static func buildSmhd() -> Data {
        var content = Data()
        content.appendUInt16BE(0) // balance
        content.appendUInt16BE(0) // reserved
        return writeFullBox(type: "smhd", version: 0, flags: 0, content: content)
    }

    private static func buildDinf() -> Data {
        // dref with a single self-contained url entry
        let urlContent = Data()
        // url with flag 0x000001 = self-contained (data in same file)
        let urlBox = writeFullBox(type: "url ", version: 0, flags: 1, content: urlContent)

        var drefContent = Data()
        drefContent.appendUInt32BE(1) // entry_count
        drefContent.append(urlBox)
        let dref = writeFullBox(type: "dref", version: 0, flags: 0, content: drefContent)

        return writeBox(type: "dinf", content: dref)
    }

    private static func buildStts(samples: [SampleInfo]) -> Data {
        // Run-length encode sample durations
        var entries: [(count: UInt32, delta: UInt32)] = []
        for sample in samples {
            if let last = entries.last, last.delta == sample.duration {
                entries[entries.count - 1].count += 1
            } else {
                entries.append((count: 1, delta: sample.duration))
            }
        }

        var content = Data()
        content.appendUInt32BE(UInt32(entries.count))
        for entry in entries {
            content.appendUInt32BE(entry.count)
            content.appendUInt32BE(entry.delta)
        }
        return writeFullBox(type: "stts", version: 0, flags: 0, content: content)
    }

    private static func buildStsz(samples: [SampleInfo]) -> Data {
        // Check if all samples have the same size
        let allSameSize = samples.count > 0 && samples.allSatisfy { $0.size == samples[0].size }

        var content = Data()
        if allSameSize {
            content.appendUInt32BE(samples[0].size) // sample_size (uniform)
            content.appendUInt32BE(UInt32(samples.count)) // sample_count
        } else {
            content.appendUInt32BE(0) // sample_size = 0 (variable)
            content.appendUInt32BE(UInt32(samples.count))
            for sample in samples {
                content.appendUInt32BE(sample.size)
            }
        }
        return writeFullBox(type: "stsz", version: 0, flags: 0, content: content)
    }

    private static func buildStsc(sampleCount: UInt32) -> Data {
        // All samples in a single chunk
        var content = Data()
        content.appendUInt32BE(1) // entry_count
        content.appendUInt32BE(1) // first_chunk
        content.appendUInt32BE(sampleCount) // samples_per_chunk
        content.appendUInt32BE(1) // sample_description_index
        return writeFullBox(type: "stsc", version: 0, flags: 0, content: content)
    }

    private static func buildStco(offset: UInt32) -> Data {
        var content = Data()
        content.appendUInt32BE(1) // entry_count
        content.appendUInt32BE(offset) // chunk_offset
        return writeFullBox(type: "stco", version: 0, flags: 0, content: content)
    }

    // MARK: - Box Writing Helpers

    private static func writeBox(type: String, content: Data) -> Data {
        var box = Data()
        box.appendUInt32BE(UInt32(content.count + 8))
        box.append(ascii: type)
        box.append(content)
        return box
    }

    private static func writeFullBox(type: String, version: UInt8, flags: UInt32, content: Data) -> Data {
        var fullContent = Data()
        fullContent.append(version)
        fullContent.append(UInt8((flags >> 16) & 0xFF))
        fullContent.append(UInt8((flags >> 8) & 0xFF))
        fullContent.append(UInt8(flags & 0xFF))
        fullContent.append(content)
        return writeBox(type: type, content: fullContent)
    }
}

// MARK: - Data Helpers

private extension Data {
    func readUInt32BE(at offset: Int) -> UInt32 {
        guard offset + 4 <= count else { return 0 }
        return UInt32(self[startIndex + offset]) << 24
             | UInt32(self[startIndex + offset + 1]) << 16
             | UInt32(self[startIndex + offset + 2]) << 8
             | UInt32(self[startIndex + offset + 3])
    }

    func readASCII(at offset: Int, length: Int) -> String {
        guard offset + length <= count else { return "" }
        return String(bytes: self[(startIndex + offset)..<(startIndex + offset + length)], encoding: .ascii) ?? ""
    }

    mutating func appendUInt32BE(_ value: UInt32) {
        append(UInt8((value >> 24) & 0xFF))
        append(UInt8((value >> 16) & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
        append(UInt8(value & 0xFF))
    }

    mutating func appendUInt16BE(_ value: UInt16) {
        append(UInt8((value >> 8) & 0xFF))
        append(UInt8(value & 0xFF))
    }

    mutating func appendUInt64BE(_ value: UInt64) {
        appendUInt32BE(UInt32((value >> 32) & 0xFFFFFFFF))
        appendUInt32BE(UInt32(value & 0xFFFFFFFF))
    }

    mutating func append(ascii string: String) {
        append(contentsOf: Array(string.utf8))
    }
}
