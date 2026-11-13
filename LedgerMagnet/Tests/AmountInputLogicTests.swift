import XCTest
@testable import Ledger

final class AmountInputLogicTests: XCTestCase {
    private func type(_ keys: [AmountInputLogic.Key], start: String = "") -> (AmountInputLogic, [Bool]) {
        var l = AmountInputLogic(text: start)
        let results = keys.map { l.press($0) }
        return (l, results)
    }

    // MARK: 開頭的 0

    func testLeadingZeroIsReplaced() {
        let (l, r) = type([.digit(0), .digit(5)])
        XCTAssertEqual(l.text, "5")
        XCTAssertEqual(r, [true, true])
    }

    func testRepeatedZeroRejected() {
        let (l, r) = type([.digit(0), .digit(0), .digit(0)])
        XCTAssertEqual(l.text, "0")
        XCTAssertEqual(r, [true, false, false])
    }

    func testZeroThenDecimalKeepsZero() {
        let (l, _) = type([.digit(0), .decimal, .digit(0), .digit(5)])
        XCTAssertEqual(l.text, "0.05")
        XCTAssertEqual(l.value, 0.05, accuracy: 1e-9)
    }

    func testDecimalOnEmptyAddsZero() {
        let (l, _) = type([.decimal])
        XCTAssertEqual(l.text, "0.")
        XCTAssertEqual(l.value, 0)
    }

    // MARK: 小數點

    func testOnlyOneDecimalPoint() {
        let (l, r) = type([.digit(1), .decimal, .digit(2), .decimal, .digit(3)])
        XCTAssertEqual(l.text, "1.23")
        XCTAssertEqual(r, [true, true, true, false, true])
    }

    func testTrailingDecimalIsKept() {
        let (l, _) = type([.digit(1), .digit(2), .decimal])
        XCTAssertEqual(l.text, "12.")
        XCTAssertEqual(l.value, 12)
        XCTAssertTrue(l.hasDecimal)
    }

    func testFractionLimitedToTwoDigits() {
        let (l, r) = type([.digit(1), .decimal, .digit(2), .digit(3), .digit(4)])
        XCTAssertEqual(l.text, "1.23")
        XCTAssertEqual(r.last, false)
    }

    // MARK: 位數上限

    func testIntegerLimitedToNineDigits() {
        var l = AmountInputLogic()
        for _ in 0..<9 { XCTAssertTrue(l.press(.digit(9))) }
        XCTAssertFalse(l.press(.digit(9)))
        XCTAssertEqual(l.text, "999999999")
        // 整數滿了仍然可以打小數
        XCTAssertTrue(l.press(.decimal))
        XCTAssertTrue(l.press(.digit(5)))
        XCTAssertEqual(l.text, "999999999.5")
    }

    func testInvalidDigitRejected() {
        var l = AmountInputLogic()
        XCTAssertFalse(l.press(.digit(10)))
        XCTAssertFalse(l.press(.digit(-1)))
        XCTAssertEqual(l.text, "")
    }

    // MARK: 刪除

    func testDeleteToEmpty() {
        let (l, r) = type([.digit(1), .digit(2), .delete, .delete])
        XCTAssertEqual(l.text, "")
        XCTAssertEqual(l.value, 0)
        XCTAssertEqual(r, [true, true, true, true])
    }

    func testDeleteOnEmptyIsInvalid() {
        let (l, r) = type([.delete])
        XCTAssertEqual(l.text, "")
        XCTAssertEqual(r, [false])
    }

    func testDeleteRemovesDecimalPoint() {
        let (l, _) = type([.digit(3), .decimal, .delete, .digit(4)])
        XCTAssertEqual(l.text, "34")
    }

    // MARK: 外部字串

    func testInitSanitizesGroupedString() {
        let l = AmountInputLogic(text: "1,280.50")
        XCTAssertEqual(l.text, "1280.50")
        XCTAssertEqual(l.value, 1280.5, accuracy: 1e-9)
    }

    func testInitDropsExtraFractionDigits() {
        XCTAssertEqual(AmountInputLogic(text: "3.14159").text, "3.14")
        XCTAssertEqual(AmountInputLogic(text: "007").text, "7")
    }

    // MARK: 顯示

    func testDisplayKeepsTypedDecimal() {
        let locale = Locale(identifier: "en_US")
        XCTAssertEqual(AmountDisplay.format(AmountInputLogic(text: "1234."), currencyCode: nil, locale: locale), "1,234.")
        XCTAssertEqual(AmountDisplay.format(AmountInputLogic(text: "1234.5"), currencyCode: nil, locale: locale), "1,234.5")
        XCTAssertEqual(AmountDisplay.format(AmountInputLogic(text: ""), currencyCode: nil, locale: locale), "0")
    }
}
