import XCTest
import QingzhouCore

final class GeoSiteCNParityTests: XCTestCase {

    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // XrayConfigTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // repo root
    }

    func testBundledMatcherMatchesGeositeDatCNExactly() throws {
        let datURL = repoRoot.appendingPathComponent("Apps/Tunnel-Shared/Resources/geosite.dat")
        let data = try Data(contentsOf: datURL)
        let datEntries = try Self.extractCNCategory(from: data)

        let txtURL = repoRoot.appendingPathComponent("Sources/QingzhouCore/Resources/geosite-cn.txt")
        let txtContent = try String(contentsOf: txtURL, encoding: .utf8)
        let parsedFromTxt = GeoSiteCNMatcher(parsing: txtContent)
        let bundled = GeoSiteCNMatcher.bundled

        XCTAssertEqual(bundled.rootDomains, datEntries.rootDomains)
        XCTAssertEqual(bundled.fullDomains, datEntries.fullDomains)
        XCTAssertEqual(Set(bundled.regexPatterns), datEntries.regexPatterns)
        XCTAssertEqual(datEntries.plainValues, [])

        XCTAssertEqual(parsedFromTxt.rootDomains, bundled.rootDomains)
        XCTAssertEqual(parsedFromTxt.fullDomains, bundled.fullDomains)
        XCTAssertEqual(parsedFromTxt.regexPatterns, bundled.regexPatterns)

        // Probe every extracted RootDomain and Full entry directly
        for root in datEntries.rootDomains {
            XCTAssertTrue(bundled.isCovered(root), "Missing root domain match for \(root)")
            XCTAssertTrue(bundled.isCovered("probe.\(root)"), "Missing subdomain match for \(root)")
        }
        for full in datEntries.fullDomains {
            XCTAssertTrue(bundled.isCovered(full), "Missing full domain match for \(full)")
        }
    }

    // MARK: - Minimal Protobuf Wire Decoder for GeoSiteList

    private struct ExtractedCN {
        var rootDomains: Set<String> = []
        var fullDomains: Set<String> = []
        var regexPatterns: Set<String> = []
        var plainValues: [String] = []
    }

    private static func readVarint(_ bytes: [UInt8], _ offset: inout Int) throws -> UInt64 {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while offset < bytes.count {
            let b = bytes[offset]
            offset += 1
            result |= UInt64(b & 0x7F) << shift
            if (b & 0x80) == 0 {
                return result
            }
            shift += 7
        }
        throw NSError(domain: "GeoSiteCNParityTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "Truncated varint"])
    }

    private static func skipField(_ bytes: [UInt8], _ offset: inout Int, wireType: UInt64) throws {
        switch wireType {
        case 0:
            _ = try readVarint(bytes, &offset)
        case 1:
            offset += 8
        case 2:
            let len = Int(try readVarint(bytes, &offset))
            offset += len
        case 5:
            offset += 4
        default:
            throw NSError(domain: "GeoSiteCNParityTests", code: 2, userInfo: [NSLocalizedDescriptionKey: "Unsupported wire type \(wireType)"])
        }
    }

    private static func extractCNCategory(from data: Data) throws -> ExtractedCN {
        let bytes = [UInt8](data)
        var offset = 0
        while offset < bytes.count {
            let tag = try readVarint(bytes, &offset)
            let fieldNum = tag >> 3
            let wireType = tag & 0x7
            if fieldNum == 1 && wireType == 2 {
                let len = Int(try readVarint(bytes, &offset))
                let slice = Array(bytes[offset..<(offset + len)])
                offset += len
                let (code, entries) = try parseGeoSite(slice)
                if code.uppercased() == "CN" {
                    return entries
                }
            } else {
                try skipField(bytes, &offset, wireType: wireType)
            }
        }
        throw NSError(domain: "GeoSiteCNParityTests", code: 3, userInfo: [NSLocalizedDescriptionKey: "CN category not found in geosite.dat"])
    }

    private static func parseGeoSite(_ bytes: [UInt8]) throws -> (String, ExtractedCN) {
        var code = ""
        var out = ExtractedCN()
        var offset = 0
        while offset < bytes.count {
            let tag = try readVarint(bytes, &offset)
            let fieldNum = tag >> 3
            let wireType = tag & 0x7
            if fieldNum == 1 && wireType == 2 {
                let len = Int(try readVarint(bytes, &offset))
                code = String(decoding: bytes[offset..<(offset + len)], as: UTF8.self)
                offset += len
            } else if fieldNum == 2 && wireType == 2 {
                let len = Int(try readVarint(bytes, &offset))
                let slice = Array(bytes[offset..<(offset + len)])
                offset += len
                let (dtype, value) = try parseDomain(slice)
                switch dtype {
                case 0: out.plainValues.append(value)
                case 1: out.regexPatterns.insert(value)
                case 2: out.rootDomains.insert(value.lowercased())
                case 3: out.fullDomains.insert(value.lowercased())
                default:
                    throw NSError(domain: "GeoSiteCNParityTests", code: 4, userInfo: [NSLocalizedDescriptionKey: "Unknown Domain.Type \(dtype)"])
                }
            } else {
                try skipField(bytes, &offset, wireType: wireType)
            }
        }
        return (code, out)
    }

    private static func parseDomain(_ bytes: [UInt8]) throws -> (UInt64, String) {
        var dtype: UInt64 = 0
        var value = ""
        var offset = 0
        while offset < bytes.count {
            let tag = try readVarint(bytes, &offset)
            let fieldNum = tag >> 3
            let wireType = tag & 0x7
            if fieldNum == 1 && wireType == 0 {
                dtype = try readVarint(bytes, &offset)
            } else if fieldNum == 2 && wireType == 2 {
                let len = Int(try readVarint(bytes, &offset))
                value = String(decoding: bytes[offset..<(offset + len)], as: UTF8.self)
                offset += len
            } else {
                try skipField(bytes, &offset, wireType: wireType)
            }
        }
        return (dtype, value)
    }
}
