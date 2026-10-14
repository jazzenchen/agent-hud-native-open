import Foundation
import Testing
@testable import AgentHUDSupport

@Test func preservesLargeIntegerCounters() throws {
    let counter: Int64 = 9_007_199_254_740_993
    let value = try JSONDecoder().decode(JSONValue.self, from: Data("{\"tokens\":9007199254740993}".utf8))
    #expect(value == .object(["tokens": .integer(counter)]))
    #expect(String(decoding: try RecordCoding.encoder().encode(value), as: UTF8.self) == "{\"tokens\":9007199254740993}")
}

@Test func parsingReadsWhatTheDecoderReads() throws {
    let numbers = ["0", "-0", "1.0", "1.5", "1e3", "-2.5E-3", "9223372036854775807", "9223372036854775808", "-9223372036854775809",
                   "9007199254740993.0", "18446744073709551616", "1e400", "01", "1."]
    let texts = numbers.flatMap { [$0, "[\($0)]", "{\"n\":\($0)}"] } + [
        #""\u00e9\ud83d\ude00 \" \\ \/ \b\f\n\r\t""#, #""\ud83d""#, "\"é中😀\"", #"{"a":{"b":[true,false,null]}}"#,
        #"{"a":1,"a":2}"#, "[1,]", "\u{FEFF}{\"a\":1}", " [ 1 , 2 ] ", "[1 2]", "", "nul",
    ]
    for data in texts.map({ Data($0.utf8) }) + [Data([0x22, 0xFF, 0x22]), Data([0x7B, 0x22, 0xC3, 0x22, 0x3A, 0x31, 0x7D])] {
        let decoded = try? JSONDecoder().decode(JSONValue.self, from: data)
        #expect((try? JSONValue.parse(data)) == decoded, "\(String(decoding: data, as: UTF8.self))")
    }
    #expect(try JSONValue.parse(Data("9007199254740993.0".utf8)) == .integer(9_007_199_254_740_993), "whole numbers keep every digit")
}

@Test func recordIdentitiesHaveUnambiguousComponents() {
    #expect(RecordCoding.hash(["ab", "c"]) != RecordCoding.hash(["a", "bc"]))
    #expect(RecordCoding.hash(["", "a"]) != RecordCoding.hash(["a", ""]))
    #expect(RecordCoding.hash([]) == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
}

@Test func digestsMatchTheSpecificationExamples() {
    func hex(_ bytes: [UInt8]) -> String { bytes.map { String(format: "%02x", $0) }.joined() }
    let abc = Data("abc".utf8)
    let long = Data("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq".utf8)
    #expect(hex(Digest.sha256(Data())) == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    #expect(hex(Digest.sha256(abc)) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    #expect(hex(Digest.sha256(long)) == "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1")
    #expect(hex(Digest.sha1(Data())) == "da39a3ee5e6b4b0d3255bfef95601890afd80709")
    #expect(hex(Digest.sha1(abc)) == "a9993e364706816aba3e25717850c26c9cd0d89d")
    #expect(hex(Digest.sha1(long)) == "84983e441c3bd26ebaae4aa1f95129e5e54670f1")
}

@Test func datesRoundTripAtMillisecondPrecision() throws {
    struct Sample: Codable, Equatable { var at: Date; var count: Int64 }
    let sample = Sample(at: RecordCoding.date(1_700_000_000_123), count: 9_007_199_254_740_993)
    let value = try JSONValue.from(sample)
    #expect(try value.decode(Sample.self) == sample)
    #expect(RecordCoding.milliseconds(sample.at) == 1_700_000_000_123)
}
