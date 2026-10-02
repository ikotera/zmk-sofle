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
 * ホストから先頭バイト 0x4C のレポートを受け取ると、現在の状態を返す。
 */

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
        k_work_schedule(&layer_report_work, K_MSEC(TAP_HOLDOVER_MS));
    }
}

// 送信はイベント発生元（キースキャン／USB 制御転送）のスレッドを塞がないようワークキューで行う
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
            k_work_reschedule(&layer_report_work, K_NO_WAIT);
        }
        return ZMK_EV_EVENT_BUBBLE;
    }

    if (as_zmk_layer_state_changed(eh)) {
        k_work_reschedule(&layer_report_work, K_NO_WAIT);
        return ZMK_EV_EVENT_BUBBLE;
    }

    struct raw_hid_received_event *rx = as_raw_hid_received_event(eh);
    if (rx && rx->length > 0 && rx->data[0] == LAYER_REPORT_ID) {
        k_work_reschedule(&layer_report_work, K_NO_WAIT);
    }

    return ZMK_EV_EVENT_BUBBLE;
}

ZMK_LISTENER(layer_report, layer_report_listener);
ZMK_SUBSCRIPTION(layer_report, zmk_layer_state_changed);
ZMK_SUBSCRIPTION(layer_report, zmk_position_state_changed);
ZMK_SUBSCRIPTION(layer_report, raw_hid_received_event);
