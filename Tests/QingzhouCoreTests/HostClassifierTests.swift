import XCTest
@testable import QingzhouCore

/// `HostClassifier.isBareIP`：判断连接目标是不是「裸 IP」（没有域名）。
/// 用于连接页 / 域名分析页的「忽略 IP」过滤 —— FakeDNS 反查不到域名的连接
/// 目标就是裸 IP，对域名分析没价值，在连接列表里是噪音。
///
/// 判定原则：**只有能确定是合法 IP 才返回 true**（宁可漏过滤，不能把域名或
/// 畸形输入误杀 —— 误杀会让用户以为数据丢了）。
final class HostClassifierTests: XCTestCase {

    // MARK: - IPv4

    func testIPv4Plain() {
        XCTAssertTrue(HostClassifier.isBareIP("1.2.3.4"))
        XCTAssertTrue(HostClassifier.isBareIP("0.0.0.0"))
        XCTAssertTrue(HostClassifier.isBareIP("255.255.255.255"))
        XCTAssertTrue(HostClassifier.isBareIP("127.0.0.1"))
    }

    func testIPv4WithPort() {
        XCTAssertTrue(HostClassifier.isBareIP("1.2.3.4:443"))
        XCTAssertTrue(HostClassifier.isBareIP("10.0.0.1:65535"))
        XCTAssertTrue(HostClassifier.isBareIP("192.168.1.1:80"))
    }

    func testIPv4LeadingZerosStillIPShaped() {
        // "010.0.0.1" 这类写法有解析歧义（八进制），但它显然不是域名，照样忽略。
        XCTAssertTrue(HostClassifier.isBareIP("010.0.0.1"))
    }

    func testIPv4Malformed() {
        XCTAssertFalse(HostClassifier.isBareIP("256.1.1.1"))      // 段超 255
        XCTAssertFalse(HostClassifier.isBareIP("1.2.3"))          // 只有 3 段
        XCTAssertFalse(HostClassifier.isBareIP("1.2.3.4.5"))      // 5 段
        XCTAssertFalse(HostClassifier.isBareIP("1.2.3.4."))       // 尾部空段
        XCTAssertFalse(HostClassifier.isBareIP(".1.2.3.4"))       // 头部空段
        XCTAssertFalse(HostClassifier.isBareIP("1.2..4"))         // 中间空段
        XCTAssertFalse(HostClassifier.isBareIP("1.2.3.a"))        // 非数字
        XCTAssertFalse(HostClassifier.isBareIP("1.2.3.1234"))     // 段超 3 位
    }

    func testIPv4BadPort() {
        XCTAssertFalse(HostClassifier.isBareIP("1.2.3.4:"))       // 端口空
        XCTAssertFalse(HostClassifier.isBareIP("1.2.3.4:abc"))    // 端口非数字
        XCTAssertFalse(HostClassifier.isBareIP("1.2.3.4:123456")) // 端口超 65535
        XCTAssertFalse(HostClassifier.isBareIP("1.2.3.4:0"))      // 端口 0 非法
    }

    // MARK: - IPv6

    func testIPv6Plain() {
        XCTAssertTrue(HostClassifier.isBareIP("::"))
        XCTAssertTrue(HostClassifier.isBareIP("::1"))
        XCTAssertTrue(HostClassifier.isBareIP("2001:db8::1"))
        XCTAssertTrue(HostClassifier.isBareIP("fe80::"))
        XCTAssertTrue(HostClassifier.isBareIP("2001:0db8:85a3:0000:0000:8a2e:0370:7334")) // 完整 8 组
        XCTAssertTrue(HostClassifier.isBareIP("2001:DB8::1"))     // 大写 hex
    }

    func testIPv6WithEmbeddedIPv4() {
        XCTAssertTrue(HostClassifier.isBareIP("::ffff:192.168.0.1"))
        XCTAssertTrue(HostClassifier.isBareIP("64:ff9b::1.2.3.4"))
        XCTAssertFalse(HostClassifier.isBareIP("::ffff:192.168.0.256")) // 内嵌 IPv4 非法
    }

    func testIPv6WithZoneID() {
        // link-local 常带 %interface，AccessLog 里可能出现
        XCTAssertTrue(HostClassifier.isBareIP("fe80::1%en0"))
        XCTAssertFalse(HostClassifier.isBareIP("%en0"))           // 只有 zone 没地址
    }

    func testIPv6Bracketed() {
        XCTAssertTrue(HostClassifier.isBareIP("[::1]"))
        XCTAssertTrue(HostClassifier.isBareIP("[2001:db8::1]"))
        XCTAssertTrue(HostClassifier.isBareIP("[2001:db8::1]:443"))
        XCTAssertTrue(HostClassifier.isBareIP("[fe80::1%en0]:8080"))
    }

    func testIPv6BracketedMalformed() {
        XCTAssertFalse(HostClassifier.isBareIP("["))
        XCTAssertFalse(HostClassifier.isBareIP("[]"))
        XCTAssertFalse(HostClassifier.isBareIP("[::1"))           // 缺右括号
        XCTAssertFalse(HostClassifier.isBareIP("[::1]abc"))       // 括号后跟垃圾
        XCTAssertFalse(HostClassifier.isBareIP("[::1]:"))         // 端口空
        XCTAssertFalse(HostClassifier.isBareIP("[::1]:99999"))    // 端口超范围
        XCTAssertFalse(HostClassifier.isBareIP("[example.com]:443")) // 括号里不是 IPv6
    }

    func testIPv6Malformed() {
        XCTAssertFalse(HostClassifier.isBareIP("1::2::3"))        // 两个 ::
        XCTAssertFalse(HostClassifier.isBareIP(":::"))
        XCTAssertFalse(HostClassifier.isBareIP("12345::1"))       // 组超 4 位
        XCTAssertFalse(HostClassifier.isBareIP("gggg::1"))        // 非 hex
        XCTAssertFalse(HostClassifier.isBareIP("1:2:3:4:5:6:7:8:9")) // 9 组
        XCTAssertFalse(HostClassifier.isBareIP("1:2:3:4:5:6:7"))  // 7 组且无 ::
        XCTAssertFalse(HostClassifier.isBareIP(":1:2:3:4:5:6:7:8")) // 单个前导冒号
        XCTAssertFalse(HostClassifier.isBareIP("1:2:3:4:5:6:7:8:")) // 单个尾随冒号
        XCTAssertFalse(HostClassifier.isBareIP("a:b"))            // 2 组无 ::，不是合法 IPv6
        XCTAssertFalse(HostClassifier.isBareIP("1:2:3:4:5:6:7:1.2.3.4")) // 内嵌 v4 后组数超限
    }

    func testIPv6DoubleColonGroupCount() {
        // :: 至少压缩 1 组：显式 7 组 + :: 合法（共 8），显式 8 组 + :: 非法（超 8）
        XCTAssertTrue(HostClassifier.isBareIP("1:2:3:4:5:6:7::"))
        XCTAssertFalse(HostClassifier.isBareIP("1:2:3:4:5:6:7:8::"))
        XCTAssertTrue(HostClassifier.isBareIP("::2:3:4:5:6:7:8"))
        XCTAssertFalse(HostClassifier.isBareIP("::1:2:3:4:5:6:7:8"))
    }

    // MARK: - 域名 / 非 IP

    func testDomainsAreNotIP() {
        XCTAssertFalse(HostClassifier.isBareIP("example.com"))
        XCTAssertFalse(HostClassifier.isBareIP("example.com:443"))
        XCTAssertFalse(HostClassifier.isBareIP("www.google.com"))
        XCTAssertFalse(HostClassifier.isBareIP("localhost"))
        XCTAssertFalse(HostClassifier.isBareIP("xn--fiqs8s.cn"))   // punycode
        XCTAssertFalse(HostClassifier.isBareIP("1.2.3.4.example.com")) // IP 开头的域名
        XCTAssertFalse(HostClassifier.isBareIP("v4.ipv6-test.com"))
    }

    func testNumericButNotIP() {
        XCTAssertFalse(HostClassifier.isBareIP("1234"))
        XCTAssertFalse(HostClassifier.isBareIP("1.2"))
        XCTAssertFalse(HostClassifier.isBareIP("3232235521"))     // 整数形式 IP 不识别（域名里不会出现，保守放过）
    }

    // MARK: - 空 / 空白 / 垃圾

    func testEmptyAndWhitespace() {
        XCTAssertFalse(HostClassifier.isBareIP(""))
        XCTAssertFalse(HostClassifier.isBareIP("   "))
        XCTAssertTrue(HostClassifier.isBareIP("  1.2.3.4  "))     // 两端空白容忍
        XCTAssertFalse(HostClassifier.isBareIP("1.2. 3.4"))       // 中间空白非法
    }
}
