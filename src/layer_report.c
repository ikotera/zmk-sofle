/*
 * アクティブレイヤーと押下中のキーを Raw HID でホストへ通知する（layer-viewer 用）。
 * あわせて、キーリピートの調査のために、システムワークキューの停止時間と設定の保存を計測して送る。
 *
 * レポート（CONFIG_RAW_HID_REPORT_SIZE = 32 バイト、残りは 0）:
 *   [0] 0x4C ('L')  識別子
 *   [1] 0x03        プロトコルバージョン
 *   [2] 最上位アクティブレイヤーの index
 *   [3] 予約
 *   [4..7]   レイヤー状態ビットマスク（layer id 単位, little endian）
 *   [8..23]  押下中のキー位置のビットマップ（position 0 = [8] の bit0, 最大 128 キー）
 *   [24..25] 前回の送信以降のシステムワークキューの最大の遅れ（ms, little endian）
 *   [26..27] 最後の設定の保存（settings_save_one）にかかった時間（ms, little endian）
 *   [28]     設定の保存の回数（起動からの累計の下位 8 bit）
 *   [29..31] 最後に保存した設定の名前の先頭 3 文字
 *
 * ホストから先頭バイト 0x4C のレポートを受け取ると現在の状態を返し、以後
 * LISTENER_TIMEOUT_MS の間だけ変化を通知する。表示アプリは定期的に送り直して購読を続ける。
 * アプリが動いていないときは何も送らない。
 *
 * 送信は専用の低優先度ワークキューで行う。システムワークキューは右手（peripheral）からの
 * キーイベントと、左手自身のキー読み取りの処理にも使われており、そこを塞ぐとキーの解放が
 * 遅れる（＝キーが押しっぱなしになる）ため。
 */

#include <string.h>

#include <zephyr/init.h>
#include <zephyr/kernel.h>
#include <zephyr/settings/settings.h>
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
#define LAYER_REPORT_VERSION 0x03
#define LAYER_REPORT_HEADER 8
#define LAYER_REPORT_MAX_KEYS 128
#define LAYER_REPORT_WORDS (LAYER_REPORT_MAX_KEYS / 32)
#define LAYER_REPORT_DIAG (LAYER_REPORT_HEADER + LAYER_REPORT_MAX_KEYS / 8)

// 素早いタップの押下を取りこぼさないよう、前回送信以降に押されたキーも別に覚えておく
#define TAP_HOLDOVER_MS 60
#define LISTENER_TIMEOUT_MS 5000
#define LAYER_REPORT_STACK_SIZE 1024
#define LAYER_REPORT_PRIORITY K_LOWEST_APPLICATION_THREAD_PRIO

// システムワークキューの遅れの計測: この間隔で計測用の仕事を投入し、実行されるまでの時間を測る
#define PROBE_INTERVAL_MS 20
// これ以上遅れたら、変化を待たずにすぐ報告する
#define PROBE_REPORT_MS 100

BUILD_ASSERT(LAYER_REPORT_DIAG + 8 <= CONFIG_RAW_HID_REPORT_SIZE, "Raw HID のレポートが小さすぎる");

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

// 計測値（送信のたびに最大の遅れは 0 に戻す）
static atomic_t max_queue_delay_ms;
static atomic_t last_save_ms;
static atomic_t save_count;
static char last_save_name[3];

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

    sys_put_le16((uint16_t)MIN(atomic_clear(&max_queue_delay_ms), UINT16_MAX), &report[LAYER_REPORT_DIAG]);
    sys_put_le16((uint16_t)MIN(atomic_get(&last_save_ms), UINT16_MAX), &report[LAYER_REPORT_DIAG + 2]);
    report[LAYER_REPORT_DIAG + 4] = (uint8_t)atomic_get(&save_count);
    memcpy(&report[LAYER_REPORT_DIAG + 5], last_save_name, sizeof(last_save_name));

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

// ---- システムワークキューの遅れの計測 ----
// タイマー（割り込み）から計測用の仕事をシステムワークキューへ投入し、実行までの時間を測る。
// 前の仕事がまだ実行されていなければ投入し直さないので、キューが止まっている間の時間がそのまま測れる。

static atomic_t probe_submitted_ms;

static void probe_work_handler(struct k_work *work) {
    uint32_t delay = k_uptime_get_32() - (uint32_t)atomic_get(&probe_submitted_ms);
    atomic_val_t prev;
    do {
        prev = atomic_get(&max_queue_delay_ms);
    } while ((atomic_val_t)delay > prev && !atomic_cas(&max_queue_delay_ms, prev, (atomic_val_t)delay));
    if (delay >= PROBE_REPORT_MS) {
        request_report();
    }
}

static K_WORK_DEFINE(probe_work, probe_work_handler);

static void probe_timer_handler(struct k_timer *timer) {
    if (!host_listening() || k_work_is_pending(&probe_work)) {
        return;
    }
    atomic_set(&probe_submitted_ms, (atomic_val_t)k_uptime_get_32());
    k_work_submit(&probe_work);
}

static K_TIMER_DEFINE(probe_timer, probe_timer_handler, NULL);

// ---- 設定の保存の計測 ----
// CMakeLists.txt でリンカーに --wrap=settings_save_one を渡し、ZMK からの呼び出しをここで受ける

int __real_settings_save_one(const char *name, const void *value, size_t val_len);

int __wrap_settings_save_one(const char *name, const void *value, size_t val_len) {
    uint32_t start = k_uptime_get_32();
    int rc = __real_settings_save_one(name, value, val_len);
    atomic_set(&last_save_ms, (atomic_val_t)(k_uptime_get_32() - start));
    memset(last_save_name, 0, sizeof(last_save_name));
    memcpy(last_save_name, name, strnlen(name, sizeof(last_save_name)));
    atomic_inc(&save_count);
    request_report();
    return rc;
}

// ---- イベント ----

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
    k_timer_start(&probe_timer, K_MSEC(PROBE_INTERVAL_MS), K_MSEC(PROBE_INTERVAL_MS));
    return 0;
}

SYS_INIT(layer_report_init, APPLICATION, CONFIG_APPLICATION_INIT_PRIORITY);
