/*
 * アクティブレイヤーの状態を Raw HID でホストへ通知する（layer-viewer 用）。
 *
 * レポート（CONFIG_RAW_HID_REPORT_SIZE バイト、残りは 0）:
 *   [0] 0x4C ('L')  識別子
 *   [1] 0x01        プロトコルバージョン
 *   [2] 最上位アクティブレイヤーの index
 *   [3] 予約
 *   [4..7] レイヤー状態ビットマスク（layer id 単位, little endian）
 *
 * ホストから先頭バイト 0x4C のレポートを受け取ると、現在の状態を返す。
 */

#include <zephyr/kernel.h>
#include <zephyr/sys/byteorder.h>

#include <zmk/event_manager.h>
#include <zmk/events/layer_state_changed.h>
#include <zmk/keymap.h>

#include <raw_hid/events.h>

#include <zephyr/logging/log.h>
LOG_MODULE_DECLARE(zmk, CONFIG_ZMK_LOG_LEVEL);

#define LAYER_REPORT_ID 0x4C
#define LAYER_REPORT_VERSION 0x01

static void layer_report_work_handler(struct k_work *work) {
    static uint8_t report[8];

    report[0] = LAYER_REPORT_ID;
    report[1] = LAYER_REPORT_VERSION;
    report[2] = zmk_keymap_highest_layer_active();
    report[3] = 0;
    sys_put_le32((uint32_t)zmk_keymap_layer_state(), &report[4]);

    raise_raw_hid_sent_event(
        (struct raw_hid_sent_event){.data = report, .length = sizeof(report)});
}

static K_WORK_DEFINE(layer_report_work, layer_report_work_handler);

// 送信はイベント発生元（キースキャン／USB 制御転送）のスレッドを塞がないようワークキューで行う
static int layer_report_listener(const zmk_event_t *eh) {
    if (as_zmk_layer_state_changed(eh)) {
        k_work_submit(&layer_report_work);
        return ZMK_EV_EVENT_BUBBLE;
    }

    struct raw_hid_received_event *rx = as_raw_hid_received_event(eh);
    if (rx && rx->length > 0 && rx->data[0] == LAYER_REPORT_ID) {
        k_work_submit(&layer_report_work);
    }

    return ZMK_EV_EVENT_BUBBLE;
}

ZMK_LISTENER(layer_report, layer_report_listener);
ZMK_SUBSCRIPTION(layer_report, zmk_layer_state_changed);
ZMK_SUBSCRIPTION(layer_report, raw_hid_received_event);
