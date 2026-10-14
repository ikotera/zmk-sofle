import XCTest
@testable import LayerViewerCore

final class ProtoTests: XCTestCase {
    func testVarintRoundTrip() throws {
        for v: UInt64 in [0, 1, 127, 128, 300, 1 << 31, UInt64.max] {
            let bytes = Proto.field(1, varint: v)
            let f = try Proto.parse(Data(bytes))
            XCTAssertEqual(f.first(1)?.varint, v)
        }
    }

    func testZigzag() {
        XCTAssertEqual(Proto.zigzag(0), 0)
        XCTAssertEqual(Proto.zigzag(1), -1)
        XCTAssertEqual(Proto.zigzag(2), 1)
        XCTAssertEqual(Proto.zigzag(5999), -3000)  // 回転 -30 度（1/100 度単位）
    }

    func testNestedAndPacked() throws {
        let inner = Proto.field(1, bytes: Proto.varint(3) + Proto.varint(300))
        let msg = Proto.field(4, bytes: inner)
        let outer = try Proto.parse(Data(msg))
        let sub = try Proto.parse(outer.first(4)!.bytes)
        XCTAssertEqual(try Proto.packedVarints(sub.first(1)!.bytes), [3, 300])
    }

    func testTruncatedInputThrows() {
        XCTAssertThrowsError(try Proto.parse(Data([0x0A, 0x05, 0x01])))
    }
}

final class LabelsTests: XCTestCase {
    private func kp(_ usage: UInt32, mods: UInt32 = 0) -> UInt32 { mods << 24 | 0x07 << 16 | usage }

    func testShiftedDigitShowsActualCharacter() {
        XCTAssertEqual(Labels.key(kp(0x1F, mods: 0x20), host: .us).main, "@")   // R Shift + 2
        XCTAssertEqual(Labels.key(kp(0x1F, mods: 0x02), host: .jis).main, "\"")  // JIS では "
    }

    func testPlainKeyShowsShiftHint() {
        let l = Labels.key(kp(0x1F), host: .us)
        XCTAssertEqual(l.main, "2")
        XCTAssertEqual(l.shift, "@")
    }

    func testCommandCombo() {
        XCTAssertEqual(Labels.key(kp(0x06, mods: 0x08), host: .us).main, "⌘C")
    }
}

final class KeymapTests: XCTestCase {
    /// layer0: 位置0=a, 位置1=b / layer1(id 5): 位置0=透過, 位置1=c
    private func keymap() -> KeymapData {
        let kpA = Binding(behaviorId: 1, param1: 0x07 << 16 | 0x04)
        let kpB = Binding(behaviorId: 1, param1: 0x07 << 16 | 0x05)
        let kpC = Binding(behaviorId: 1, param1: 0x07 << 16 | 0x06)
        let trans = Binding(behaviorId: 2)
        return KeymapData(keys: [KeyAttr(), KeyAttr(x: 100)],
                          layers: [Layer(id: 0, name: "M1", bindings: [kpA, kpB]),
                                   Layer(id: 5, name: "M2", bindings: [trans, kpC])],
                          behaviors: ["1": "Key Press", "2": "Transparent"])
    }

    func testTransparentFallsThrough() {
        let km = keymap()
        let mask: UInt32 = 1 | 1 << 5
        XCTAssertEqual(km.resolve(position: 0, layerMask: mask)?.layerIndex, 0)
        XCTAssertEqual(km.hidUsage(position: 0, layerMask: mask), 0x04)
        XCTAssertEqual(km.hidUsage(position: 1, layerMask: mask), 0x06)
        XCTAssertEqual(km.hidUsage(position: 1, layerMask: 1), 0x05)
    }

    func testLayerMaskUsesLayerIdNotIndex() {
        XCTAssertEqual(keymap().activeIndices(layerMask: 1 << 1), [0])  // id 1 のレイヤーは無い
        XCTAssertEqual(keymap().activeIndices(layerMask: 1 << 5), [0, 1])
    }
}

final class KeyCodesTests: XCTestCase {
    func testRoundTrip() {
        for usage in [0x04, 0x1D, 0x1E, 0x27, 0x2A, 0x2C, 0x4F, 0x52, 0x87, 0x89, 0x90, 0x91, 0xE1] {
            let kc = KeyCodes.keyCode(forUsage: usage)
            XCTAssertNotNil(kc, "usage \(usage)")
            XCTAssertEqual(KeyCodes.usage(forKeyCode: kc!), usage)
        }
        XCTAssertEqual(KeyCodes.keyCode(forUsage: 0x04), 0)   // a
        XCTAssertEqual(KeyCodes.keyCode(forUsage: 0x2A), 51)  // Backspace
    }
}

final class RecorderTests: XCTestCase {
    private let posA = 10  // 位置 10 を押すと 'a'（usage 0x04, keyCode 0）
    private func recorder() -> Recorder {
        Recorder { position, _ in position == 10 ? 0x04 : nil }
    }
    private func repeats(_ r: Recorder, from t: Double, count: Int) -> [Finding] {
        (0..<count).flatMap { r.feed(.os(keyCode: 0, down: true, autorepeat: true), at: t + Double($0) * 0.05) }
    }

    func testIntentionalHoldIsKeyboardHolding() {
        let r = recorder()
        r.feed(.firmware(pressed: [posA], layerMask: 1), at: 0)
        r.feed(.hid(usage: 0x04, down: true), at: 0.01)
        r.feed(.os(keyCode: 0, down: true, autorepeat: false), at: 0.02)
        let found = repeats(r, from: 0.5, count: 8)
        let verdicts: [Verdict] = found.compactMap {
            if case let .repeatBurst(_, _, _, v) = $0 { return v } else { return nil }
        }
        XCTAssertEqual(verdicts, [.keyboardHolding])
    }

    func testReleaseLostOnTheWayToMac() {
        let r = recorder()
        r.feed(.firmware(pressed: [posA], layerMask: 1), at: 0)
        r.feed(.hid(usage: 0x04, down: true), at: 0.01)
        r.feed(.firmware(pressed: [], layerMask: 1), at: 0.1)  // キーボードは離した。HID の解放は届かない
        let found = repeats(r, from: 0.5, count: 8)
        XCTAssertTrue(found.contains(.repeatBurst(keyCode: 0, count: 8, since: 0.5, verdict: .lostOnTheWayToMac)))
    }

    func testRepeatAfterHidRelease() {
        let r = recorder()
        r.feed(.firmware(pressed: [posA], layerMask: 1), at: 0)
        r.feed(.hid(usage: 0x04, down: true), at: 0.01)
        r.feed(.firmware(pressed: [], layerMask: 1), at: 0.1)
        r.feed(.hid(usage: 0x04, down: false), at: 0.11)
        let found = repeats(r, from: 0.5, count: 8)
        XCTAssertTrue(found.contains(.repeatBurst(keyCode: 0, count: 8, since: 0.5, verdict: .repeatAfterRelease)))
    }

    func testBurstReportedOnceAndResetByOtherKey() {
        let r = recorder()
        XCTAssertEqual(repeats(r, from: 0, count: 20).count, 1)
        r.feed(.os(keyCode: 11, down: true, autorepeat: false), at: 2)
        XCTAssertEqual(repeats(r, from: 3, count: 8).count, 1)
    }

    func testLongHoldIgnoresModifiersAndReportsOnce() {
        let r = Recorder { p, _ in p == 1 ? 0xE1 : 0x04 }  // 位置 1 は Shift
        r.feed(.firmware(pressed: [1, 2], layerMask: 1), at: 0)
        r.feed(.hid(usage: 0xE1, down: true), at: 0)
        XCTAssertEqual(r.tick(at: 0.5), [])
        XCTAssertEqual(r.tick(at: 1.2), [.firmwareLongHold(position: 2, usage: 0x04, seconds: 1.2)])
        XCTAssertEqual(r.tick(at: 3), [])
    }

    func testStaleFirmwareMeansUnknownWhileMacHolds() {
        let r = recorder()
        r.feed(.hid(usage: 0x04, down: true), at: 0)
        let found = repeats(r, from: 0.5, count: 8)
        XCTAssertTrue(found.contains(.repeatBurst(keyCode: 0, count: 8, since: 0.5, verdict: .unknown)))
    }

    func testRepeatedFirmwareStateIsNotStoredAgain() {
        let r = recorder()
        r.feed(.firmware(pressed: [], layerMask: 1), at: 0)
        r.feed(.firmware(pressed: [], layerMask: 1), at: 2)
        r.feed(.firmware(pressed: [posA], layerMask: 1), at: 3)
        XCTAssertEqual(r.ring.map(\.time), [0, 3])
        // 変化が無くても「報告は届いている」とみなす（判定で古い扱いにしない）
        r.feed(.firmware(pressed: [posA], layerMask: 1), at: 8)
        XCTAssertTrue(repeats(r, from: 8.5, count: 8).contains(
            .repeatBurst(keyCode: 0, count: 8, since: 8.5, verdict: .keyboardHolding)))
    }

    func testKeyNames() {
        XCTAssertEqual(KeyCodes.name(usage: 0x6E), "F19")
        XCTAssertEqual(KeyCodes.name(usage: 0x3A), "F1")
        XCTAssertEqual(KeyCodes.name(usage: 0x1F), "2")
    }

    /// 2026-10-14 01:05 の再現: 記録アプリが約 1.2 秒止まり、解放・リピート・次のキーがまとめて届いた。
    /// 届いた順（解放が先）ではなく、発生した順で判定する
    func testBatchedDeliveryIsJudgedByEventTime() {
        let r = recorder()
        r.feed(.firmware(pressed: [posA], layerMask: 1), at: 0)
        r.feed(.hid(usage: 0x04, down: true), at: 0.01)
        r.feed(.os(keyCode: 0, down: true, autorepeat: false), at: 0.02)
        let arrival = 1.25
        r.feed(.hid(usage: 0x04, down: false), at: 1.20, deliveredAt: arrival)
        r.feed(.firmware(pressed: [], layerMask: 1), at: 1.21, deliveredAt: arrival)
        var found: [Finding] = []
        for i in 0..<9 {
            found += r.feed(.os(keyCode: 0, down: true, autorepeat: true), at: 0.5 + Double(i) * 0.083, deliveredAt: arrival)
        }
        XCTAssertTrue(found.contains { if case .deliveryDelay = $0 { return true } else { return false } })
        let verdicts: [Verdict] = found.compactMap { if case let .repeatBurst(_, _, _, v) = $0 { return v } else { return nil } }
        XCTAssertEqual(verdicts, [.keyboardHolding])  // 8 回目のリピートの時点では、キーボードも Mac もまだ押下中
    }

    func testClockNormalize() {
        let now = 1000.0
        XCTAssertEqual(Clock.normalize(UInt64(999.5 * 1e9), now: now), 999.5, accuracy: 1e-6)  // ナノ秒
        XCTAssertEqual(Clock.normalize(0, now: now), now)  // 解釈できなければ現在時刻
    }

    func testRingKeepsOnlyRecentEvents() {
        var cfg = RecorderConfig()
        cfg.ringSeconds = 5
        let r = Recorder(config: cfg) { _, _ in nil }
        r.feed(.mark, at: 0)
        r.feed(.mark, at: 10)
        XCTAssertEqual(r.ring.map(\.time), [10])
    }
}

final class LayerReportTests: XCTestCase {
    private func report(version: UInt8) -> [UInt8] {
        var r = [UInt8](repeating: 0, count: 32)
        r[0] = 0x4C; r[1] = version
        r[4] = 0b100        // layer id 2
        r[8 + 2] = 0b10     // position 17
        return r
    }

    func testVersion2UsesWholeBitmap() {
        var r = report(version: 2)
        r[31] = 1  // position 184
        let p = LayerReport.parse(r)!
        XCTAssertEqual(p.layerMask, 0b101)
        XCTAssertEqual(p.pressed, [17, 184])
        XCTAssertNil(p.diag)
    }

    func testVersion3SeparatesDiag() {
        var r = report(version: 3)
        r[24] = 0x84; r[25] = 0x03         // 900 ms
        r[26] = 120                         // 120 ms
        r[28] = 7
        r[29] = UInt8(ascii: "r"); r[30] = UInt8(ascii: "g"); r[31] = UInt8(ascii: "b")
        let p = LayerReport.parse(r)!
        XCTAssertEqual(p.pressed, [17])  // [24..] は押下中のキーとして読まない
        XCTAssertEqual(p.diag, KeyboardDiag(maxQueueDelayMs: 900, lastSaveMs: 120, saveCount: 7, lastSaveName: "rgb"))
    }

    func testOtherReportsAreIgnored() {
        XCTAssertNil(LayerReport.parse([0x00, 3, 0, 0, 0, 0, 0, 0]))
    }
}

final class KeyboardDiagRecorderTests: XCTestCase {
    private func diag(delay: Int = 0, saveMs: Int = 0, count: Int, name: String = "") -> RecEvent {
        .diag(KeyboardDiag(maxQueueDelayMs: delay, lastSaveMs: saveMs, saveCount: count, lastSaveName: name))
    }

    func testStallWithRecentSave() {
        let r = Recorder { _, _ in nil }
        XCTAssertEqual(r.feed(diag(count: 3, name: "ble"), at: 0), [])  // 最初の報告は保存として数えない
        let found = r.feed(diag(delay: 900, saveMs: 880, count: 4, name: "rgb"), at: 10)
        XCTAssertEqual(found, [.settingsSave(name: "rgb", ms: 880), .keyboardStall(ms: 900, recentSave: "rgb（880 ms）")])
        XCTAssertEqual(r.ring.count, 1)
    }

    func testStallWithoutSaveAndQuietReportsAreNotStored() {
        let r = Recorder { _, _ in nil }
        r.feed(diag(count: 3), at: 0)
        XCTAssertEqual(r.feed(diag(delay: 20, count: 3), at: 1), [])
        XCTAssertEqual(r.feed(diag(delay: 400, count: 3), at: 2), [.keyboardStall(ms: 400, recentSave: nil)])
        XCTAssertEqual(r.ring.count, 1)
    }

    func testSaveCountWraps() {
        let r = Recorder { _, _ in nil }
        r.feed(diag(count: 255), at: 0)
        XCTAssertEqual(r.feed(diag(saveMs: 5, count: 0, name: "ext"), at: 1), [.settingsSave(name: "ext", ms: 5)])
    }
}

