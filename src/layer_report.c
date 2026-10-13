/*
 * アクティブレイヤーと押下中のキーを Raw HID でホストへ通知する（layer-viewer 用）。
 *
 * レポート（CONFIG_RAW_HID_REPORT_SIZE バイト、残りは 0）:
 *   [0] 0x4C ('L')  識別子
 *   [1] 0x02        プロトコルバージョン
 *   [2] 最上位アクティブレイヤーの index
 *   [3] 予約
 *   [4..7]  レイヤー状態ビットマスク（layer id 単位, little endian）
 *   [8..31] 押下中のキー位置のビットマップ（position 0 = [8] の bit0, 最大 192 キー）
 *
 * ホストから先頭バイト 0x4C のレポートを受け取ると現在の状態を返し、以後
 * LISTENER_TIMEOUT_MS の間だけ変化を通知する。表示アプリは定期的に送り直して購読を続ける。
 * アプリが動いていないときは何も送らない。
 *
 * 送信は専用の低優先度ワークキューで行う。システムワークキューは右手（peripheral）からの
 * キーイベント処理にも使われており、そこで USB / BLE の送信待ちが起きると右手のイベント
 * 待ち行列があふれてキー解放が失われる（＝キーが押しっぱなしになる）おそれがあるため。
 */

#include <zephyr/init.h>
#include <zephyr/kernel.h>
#include <zephyr/sys/atomic.h>
#include <zephyr/sys/byteorder.h>

#include <zmk/event_manager.h>
#include <zmk/events/layer_state_changed.h>
#include <zmk/events/position_state_changed.h>
#include <zmk/keymap.h>

#include <raw_hid/events.h>

#include <zephyr/logging/log.h>
LOG_MODULE_DECLARE(zmk, CONFIG_ZMK_LOG_LEVEL);

#define LAYER_REPORT_ID 0x4C
#define LAYER_REPORT_VERSION 0x02
#define LAYER_REPORT_HEADER 8
#define LAYER_REPORT_MAX_KEYS ((CONFIG_RAW_HID_REPORT_SIZE - LAYER_REPORT_HEADER) * 8)
#define LAYER_REPORT_WORDS (LAYER_REPORT_MAX_KEYS / 32)

// 素早いタップの押下を取りこぼさないよう、前回送信以降に押されたキーも別に覚えておく
#define TAP_HOLDOVER_MS 60
#define LISTENER_TIMEOUT_MS 5000
#define LAYER_REPORT_STACK_SIZE 1024
#define LAYER_REPORT_PRIORITY K_LOWEST_APPLICATION_THREAD_PRIO

K_THREAD_STACK_DEFINE(layer_report_stack, LAYER_REPORT_STACK_SIZE);
static struct k_work_q layer_report_q;

static atomic_t last_request_ms;

static bool host_listening(void) {
    atomic_val_t last = atomic_get(&last_request_ms);
    // 32bit の稼働時間は約 49 日で一周するので、差を符号付きで見る
    int32_t elapsed = (int32_t)(k_uptime_get_32() - (uint32_t)last);
    return last != 0 && elapsed < LISTENER_TIMEOUT_MS;
}

static ATOMIC_DEFINE(pressed, LAYER_REPORT_MAX_KEYS);
static ATOMIC_DEFINE(pressed_since_report, LAYER_REPORT_MAX_KEYS);

static void layer_report_work_handler(struct k_work *work);
static K_WORK_DELAYABLE_DEFINE(layer_report_work, layer_report_work_handler);

static void layer_report_work_handler(struct k_work *work) {
    static uint8_t report[CONFIG_RAW_HID_REPORT_SIZE];
    bool released_unseen = false;

    memset(report, 0, sizeof(report));
    report[0] = LAYER_REPORT_ID;
    report[1] = LAYER_REPORT_VERSION;
    report[2] = zmk_keymap_highest_layer_active();
    sys_put_le32((uint32_t)zmk_keymap_layer_state(), &report[4]);

    for (int i = 0; i < LAYER_REPORT_WORDS; i++) {
        atomic_val_t now = atomic_get(&pressed[i]);
        atomic_val_t tapped = atomic_clear(&pressed_since_report[i]);
        released_unseen |= (tapped & ~now) != 0;
        sys_put_le32((uint32_t)(now | tapped), &report[LAYER_REPORT_HEADER + i * 4]);
    }

    raise_raw_hid_sent_event(
        (struct raw_hid_sent_event){.data = report, .length = sizeof(report)});

    // 押して離したキーを一度「押下中」として送ったので、少し後に解放状態を送り直す
    if (released_unseen) {
        k_work_schedule_for_queue(&layer_report_q, &layer_report_work, K_MSEC(TAP_HOLDOVER_MS));
    }
}

static void request_report(void) {
    if (host_listening()) {
        k_work_reschedule_for_queue(&layer_report_q, &layer_report_work, K_NO_WAIT);
    }
}

static int layer_report_listener(const zmk_event_t *eh) {
    const struct zmk_position_state_changed *pos = as_zmk_position_state_changed(eh);
    if (pos) {
        if (pos->position < LAYER_REPORT_MAX_KEYS) {
            if (pos->state) {
                atomic_set_bit(pressed, pos->position);
                atomic_set_bit(pressed_since_report, pos->position);
            } else {
                atomic_clear_bit(pressed, pos->position);
            }
            request_report();
        }
        return ZMK_EV_EVENT_BUBBLE;
    }

    if (as_zmk_layer_state_changed(eh)) {
        request_report();
        return ZMK_EV_EVENT_BUBBLE;
    }

    struct raw_hid_received_event *rx = as_raw_hid_received_event(eh);
    if (rx && rx->length > 0 && rx->data[0] == LAYER_REPORT_ID) {
        // 0 は「未購読」の印なので避ける
        atomic_set(&last_request_ms, (atomic_val_t)(k_uptime_get_32() | 1));
        request_report();
    }

    return ZMK_EV_EVENT_BUBBLE;
}

ZMK_LISTENER(layer_report, layer_report_listener);
ZMK_SUBSCRIPTION(layer_report, zmk_layer_state_changed);
ZMK_SUBSCRIPTION(layer_report, zmk_position_state_changed);
ZMK_SUBSCRIPTION(layer_report, raw_hid_received_event);

static int layer_report_init(void) {
    static const struct k_work_queue_config cfg = {.name = "layer_report"};
    k_work_queue_start(&layer_report_q, layer_report_stack, K_THREAD_STACK_SIZEOF(layer_report_stack),
                       LAYER_REPORT_PRIORITY, &cfg);
    return 0;
}

SYS_INIT(layer_report_init, APPLICATION, CONFIG_APPLICATION_INIT_PRIORITY);
