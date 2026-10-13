// キーリピートが止まらない不具合を捉えるための記録。
// 3 か所の観測を突き合わせ、「離した」がどこで失われた・遅れたかを判定する。
//   1. キーボード内部: ファームウェアが Raw HID で送る押下中のキー位置（src/layer_report.c）
//   2. Mac が受け取った HID: Sofle のキーボード用インターフェースの押下・解放
//   3. macOS のキーイベント: キーリピート（autorepeat）を含む keyDown / keyUp
// 時刻は呼び出し側が渡す（単体テストで時間を進められるように）。
// 各観測は「発生した時刻」（カーネルが受け取った時刻）と「アプリに届いた時刻」を持つ。アプリが止まると
// 観測がまとめて届くので、判定は発生した時刻の順に並べ直して行う（v1.1.1）。
import Foundation

public enum RecEvent: Equatable {
    /// ファームウェアの報告（押下中のキー位置の全体）
    case firmware(pressed: Set<Int>, layerMask: UInt32)
    /// Sofle の HID レポートでのキーの押下・解放
    case hid(usage: Int, down: Bool)
    /// macOS のキーイベント（全キーボード）。autorepeat は OS が作ったリピート
    case os(keyCode: Int, down: Bool, autorepeat: Bool)
    /// 利用者が付けた印
    case mark
}

public struct TimedEvent: Equatable {
    /// 発生した時刻（秒、システムの稼働時間）
    public let time: Double
    /// アプリに届いた時刻
    public let delivered: Double
    public let event: RecEvent
}

/// 異常リピートの判定。どこで「離した」が止まっているか
public enum Verdict: Equatable {
    /// キーボード内部で押下中（意図した長押し、またはキーボード内部での押しっぱなし。右手との通信など）
    case keyboardHolding
    /// キーボードは離しているのに、Mac の HID では押下中（左手 → Mac の送信で解放が失われた・遅れた）
    case lostOnTheWayToMac
    /// Mac の HID では離しているのに、macOS がリピートを続けている（macOS 以降、または別のキーボード）
    case repeatAfterRelease
    /// キーの対応が分からない、またはファームウェアの報告が届いていない
    case unknown

    public var text: String {
        switch self {
        case .keyboardHolding: return "キーボード内部で押下中（意図した長押し、またはキーボード内部での押しっぱなし）"
        case .lostOnTheWayToMac: return "キーボードは解放済み、Mac の HID では押下中（左手→Mac の送信で解放が失われた・遅れた）"
        case .repeatAfterRelease: return "Mac の HID では解放済みなのにリピート継続（macOS 以降、または別のキーボードからの入力）"
        case .unknown: return "判定できない（キーの対応が不明、またはファームウェアの報告が無い）"
        }
    }
}

public enum Finding: Equatable {
    /// 同じキーの autorepeat が続いた
    case repeatBurst(keyCode: Int, count: Int, since: Double, verdict: Verdict)
    /// ファームウェアで文字キーが長く押下中
    case firmwareLongHold(position: Int, usage: Int?, seconds: Double)
    /// Mac の HID で文字キーが長く押下中
    case hidLongHold(usage: Int, seconds: Double)
    /// 利用者の印
    case userMark
    /// 観測がアプリに届くまで遅れた（アプリが止まっていた、または観測がまとめて届いた）
    case deliveryDelay(seconds: Double)
}

public struct RecorderConfig {
    /// これ以上押下が続いたら長押しとして記録する（秒）
    public var holdThreshold = 1.0
    /// 同じキーの autorepeat がこの回数続いたら異常リピートとして記録する
    public var repeatBurst = 8
    /// 直近の観測を何秒ぶん覚えておくか（記録ファイルに書き出す範囲）
    public var ringSeconds = 20.0
    /// ファームウェアの報告がこれより古ければ、キーボード内部の状態は分からないとみなす（秒）
    public var firmwareStaleSeconds = 6.0
    /// これ以上遅れて届いた観測があったら記録する（秒）
    public var deliveryDelayThreshold = 0.5
    public init() {}
}

public final class Recorder {
    public let config: RecorderConfig
    /// キー位置 → 押したときの HID Usage（その時点のレイヤーで解決）。文字キー以外は nil
    private let usageForPosition: (_ position: Int, _ layerMask: UInt32) -> Int?

    public private(set) var ring: [TimedEvent] = []
    private var firmwarePressed: [Int: (since: Double, usage: Int?, reported: Bool)] = [:]
    private var lastFirmwareReport: Double?
    private var layerMask: UInt32 = 1
    private var hidDown: [Int: (since: Double, reported: Bool)] = [:]
    private var repeating: (keyCode: Int, count: Int, since: Double, reported: Bool)?
    private var lastDelayReported = -Double.infinity

    public init(config: RecorderConfig = RecorderConfig(),
                usageForPosition: @escaping (_ position: Int, _ layerMask: UInt32) -> Int?) {
        self.config = config
        self.usageForPosition = usageForPosition
    }

    /// 観測を1つ入れ、新たに分かった異常を返す
    @discardableResult
    /// - Parameters:
    ///   - t: 発生した時刻
    ///   - delivered: アプリに届いた時刻（省略時は t）
    public func feed(_ event: RecEvent, at t: Double, deliveredAt delivered: Double? = nil) -> [Finding] {
        let d = delivered ?? t
        var found: [Finding] = []
        if d - t >= config.deliveryDelayThreshold && d - lastDelayReported > config.ringSeconds {
            lastDelayReported = d
            found.append(.deliveryDelay(seconds: d - t))
        }
        // ファームウェアは購読の維持のため同じ内容を定期的に送ってくるので、変化したときだけ残す
        if case let .firmware(pressed, mask) = event, lastFirmwareReport != nil,
           Set(firmwarePressed.keys) == pressed, mask == layerMask {
            lastFirmwareReport = max(lastFirmwareReport ?? t, t)
            return found + tick(at: d)
        }
        ring.append(TimedEvent(time: t, delivered: d, event: event))
        ring.removeAll { $0.time < d - config.ringSeconds }

        switch event {
        case let .firmware(pressed, mask):
            lastFirmwareReport = max(lastFirmwareReport ?? t, t)
            for p in pressed where firmwarePressed[p] == nil {
                firmwarePressed[p] = (t, usageForPosition(p, layerMask), false)  // 押した瞬間のレイヤーで解決
            }
            for p in firmwarePressed.keys where !pressed.contains(p) { firmwarePressed[p] = nil }
            layerMask = mask
        case let .hid(usage, down):
            if down { if hidDown[usage] == nil { hidDown[usage] = (t, false) } } else { hidDown[usage] = nil }
        case let .os(keyCode, down, autorepeat):
            if down && autorepeat {
                if var r = repeating, r.keyCode == keyCode {
                    r.count += 1
                    if r.count >= config.repeatBurst && !r.reported {
                        r.reported = true
                        found.append(.repeatBurst(keyCode: keyCode, count: r.count, since: r.since,
                                                  verdict: verdict(keyCode: keyCode, at: t)))
                    }
                    repeating = r
                } else {
                    repeating = (keyCode, 1, t, false)
                }
            } else if down || repeating?.keyCode == keyCode {
                repeating = nil  // 別のキーを押した、またはそのキーを離した
            }
        case .mark:
            found.append(.userMark)
        }
        return found + tick(at: d)
    }

    /// 時間の経過だけで分かる異常（長押し）を調べる。定期的に呼ぶ
    @discardableResult
    public func tick(at t: Double) -> [Finding] {
        var found: [Finding] = []
        for (p, s) in firmwarePressed where !s.reported && t - s.since >= config.holdThreshold {
            // 修飾キー・レイヤーキーなど文字キー以外の長押しは普通のことなので記録しない
            if let u = s.usage, !KeyCodes.isModifier(usage: u) {
                found.append(.firmwareLongHold(position: p, usage: u, seconds: t - s.since))
            }
            firmwarePressed[p]?.reported = true
        }
        for (u, s) in hidDown where !s.reported && t - s.since >= config.holdThreshold {
            if !KeyCodes.isModifier(usage: u) { found.append(.hidLongHold(usage: u, seconds: t - s.since)) }
            hidDown[u]?.reported = true
        }
        return found.sorted { "\($0)" < "\($1)" }
    }

    /// 異常リピートの時点（発生した時刻 t）で、キーボード内部と Mac の HID がそのキーをどう見ていたか。
    /// 観測は届いた順ではなく発生した順に並べ直し、t までに発生したものだけで状態を組み立てる
    func verdict(keyCode: Int, at t: Double) -> Verdict {
        guard let usage = KeyCodes.usage(forKeyCode: keyCode) else { return .unknown }
        var macDown = Set<Int>()
        var keyboardUsages = Set<Int>()
        var firmwareSeen: Double?
        for e in ring.sorted(by: { $0.time < $1.time }) where e.time <= t {
            switch e.event {
            case let .hid(u, down): if down { macDown.insert(u) } else { macDown.remove(u) }
            case let .firmware(pressed, mask):
                firmwareSeen = e.time
                keyboardUsages = Set(pressed.compactMap { usageForPosition($0, mask) })
            default: break
            }
        }
        let macHolding = macDown.contains(usage)
        // 記録に残るのは変化したときだけなので、鮮度は最後に届いた報告（同じ内容の定期報告を含む）で見る
        guard firmwareSeen != nil, let last = lastFirmwareReport, t - last <= config.firmwareStaleSeconds else {
            return macHolding ? .unknown : .repeatAfterRelease
        }
        let keyboardHolding = keyboardUsages.contains(usage)
        switch (keyboardHolding, macHolding) {
        case (true, _): return .keyboardHolding
        case (false, true): return .lostOnTheWayToMac
        case (false, false): return .repeatAfterRelease
        }
    }
}
