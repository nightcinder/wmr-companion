import Foundation

public enum BatchParseError: Error, Equatable, Sendable {
    case tooShort
    case unknownVersion
    case emptyBatch
    case wrongLength
}

/// Calculate maximum records that can fit in one FF14 batch at given ATT MTU.
public func batchMaxCount(attMTU: Int) -> Int {
    let avail = attMTU - WMRConstants.attNotifyOverhead - WMRConstants.batchHeaderSize
    let n = avail / WMRConstants.decodedRecordSize
    if n <= 0 { return 0 }
    return min(n, WMRConstants.batchMaxRecordCount)
}

/// Parses an FF14 notification payload containing a 2-byte header and 1..9 FF12 records.
public func parseDecodedBatch(_ data: Data) -> Result<[DecodedRecord], BatchParseError> {
    guard data.count >= WMRConstants.batchHeaderSize + WMRConstants.decodedRecordSize else {
        return .failure(.tooShort)
    }
    guard data[0] == WMRConstants.batchVersion else {
        return .failure(.unknownVersion)
    }
    let count = Int(data[1])
    guard count >= 1 else {
        return .failure(.emptyBatch)
    }
    guard data.count == WMRConstants.batchHeaderSize + count * WMRConstants.decodedRecordSize else {
        return .failure(.wrongLength)
    }

    var records: [DecodedRecord] = []
    records.reserveCapacity(count)

    for i in 0..<count {
        let start = WMRConstants.batchHeaderSize + i * WMRConstants.decodedRecordSize
        let end = start + WMRConstants.decodedRecordSize
        let recordData = data.subdata(in: start..<end)
        if case .success(let rec) = parseDecodedRecord(recordData) {
            records.append(rec)
        }
    }
    return .success(records)
}

/// Packs an array of DecodedRecords into one FF14 batch payload.
public func encodeDecodedBatch(_ records: [DecodedRecord]) -> Data {
    precondition(!records.isEmpty && records.count <= 255, "records count must be 1..255")
    var out = Data(count: WMRConstants.batchHeaderSize + records.count * WMRConstants.decodedRecordSize)
    out[0] = WMRConstants.batchVersion
    out[1] = UInt8(records.count)

    for (i, rec) in records.enumerated() {
        let recData = encodeDecodedRecord(rec)
        let offset = WMRConstants.batchHeaderSize + i * WMRConstants.decodedRecordSize
        out.replaceSubrange(offset..<(offset + WMRConstants.decodedRecordSize), with: recData)
    }
    return out
}
