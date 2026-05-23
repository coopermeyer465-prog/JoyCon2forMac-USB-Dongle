#include <stdio.h>
#include <math.h>
#include <string.h>
#include <stdlib.h>

#include "esp_log.h"
#include "driver/gpio.h"
#include "freertos/FreeRTOS.h"
#include "freertos/semphr.h"
#include "freertos/task.h"

#include "joycon2_ble.h"
#include "usb_hid_gamepad.h"

static const char *TAG = "main";

// XIAO ESP32-S3 user LED (active-low). Seeed docs: GPIO21.
// Keeping this here avoids needing a separate board support layer.
#ifndef JOYCON2_STATUS_LED_GPIO
#define JOYCON2_STATUS_LED_GPIO GPIO_NUM_21
#endif

typedef enum {
    LED_MODE_SCANNING = 0,
    LED_MODE_FOUND,
    LED_MODE_CONNECTED,
    LED_MODE_SUBSCRIBED,
    LED_MODE_NOTIFY_OTHER,
    LED_MODE_PACKET_REJECTED,
    LED_MODE_NOTIFICATIONS,
} led_mode_t;

static volatile led_mode_t s_led_mode = LED_MODE_SCANNING;
static volatile led_mode_t s_last_ble_mode = LED_MODE_SCANNING;
static volatile TickType_t s_last_real_input_at = 0;

static void status_led_init(void) {
    gpio_config_t cfg = {
        .pin_bit_mask = 1ULL << JOYCON2_STATUS_LED_GPIO,
        .mode = GPIO_MODE_OUTPUT,
        .pull_up_en = false,
        .pull_down_en = false,
        .intr_type = GPIO_INTR_DISABLE,
    };
    (void)gpio_config(&cfg);
    // Default off (active-low).
    (void)gpio_set_level(JOYCON2_STATUS_LED_GPIO, 1);
}

static void status_led_set(bool on) {
    // active-low
    (void)gpio_set_level(JOYCON2_STATUS_LED_GPIO, on ? 0 : 1);
}

static void status_led_pulse(int on_ms, int off_ms) {
    status_led_set(true);
    vTaskDelay(pdMS_TO_TICKS(on_ms));
    status_led_set(false);
    vTaskDelay(pdMS_TO_TICKS(off_ms));
}

static void status_led_blink_task(void *param) {
    (void)param;
    while (1) {
        led_mode_t mode = s_led_mode;
        if (mode == LED_MODE_NOTIFICATIONS &&
            (s_last_real_input_at == 0 ||
             (int32_t)(xTaskGetTickCount() - s_last_real_input_at) > (int32_t)pdMS_TO_TICKS(1500))) {
            mode = s_last_ble_mode;
            s_led_mode = mode;
        }
        switch (mode) {
            case LED_MODE_SCANNING:
                status_led_pulse(80, 920);
                break;
            case LED_MODE_FOUND:
                status_led_pulse(80, 170);
                break;
            case LED_MODE_CONNECTED:
                status_led_pulse(80, 120);
                status_led_pulse(80, 720);
                break;
            case LED_MODE_SUBSCRIBED:
                status_led_pulse(80, 120);
                status_led_pulse(80, 120);
                status_led_pulse(80, 520);
                break;
            case LED_MODE_NOTIFY_OTHER:
                status_led_pulse(80, 120);
                status_led_pulse(80, 120);
                status_led_pulse(80, 120);
                status_led_pulse(80, 520);
                break;
            case LED_MODE_PACKET_REJECTED:
                status_led_pulse(80, 120);
                status_led_pulse(80, 120);
                status_led_pulse(80, 120);
                status_led_pulse(80, 120);
                status_led_pulse(80, 520);
                break;
            case LED_MODE_NOTIFICATIONS:
                status_led_pulse(35, 65);
                status_led_pulse(35, 65);
                status_led_pulse(35, 865);
                break;
        }
    }
}

static void on_ble_status(joycon2_ble_status_t status) {
    switch (status) {
        case JOYCON2_BLE_STATUS_SCANNING:
        case JOYCON2_BLE_STATUS_DISCONNECTED:
            s_last_ble_mode = LED_MODE_SCANNING;
            s_led_mode = s_last_ble_mode;
            break;
        case JOYCON2_BLE_STATUS_FOUND:
            s_last_ble_mode = LED_MODE_FOUND;
            s_led_mode = s_last_ble_mode;
            break;
        case JOYCON2_BLE_STATUS_CONNECTED:
            s_last_ble_mode = LED_MODE_CONNECTED;
            s_led_mode = s_last_ble_mode;
            break;
        case JOYCON2_BLE_STATUS_SUBSCRIBED:
            s_last_ble_mode = LED_MODE_SUBSCRIBED;
            s_led_mode = s_last_ble_mode;
            break;
        case JOYCON2_BLE_STATUS_NOTIFY_OTHER:
            s_last_ble_mode = LED_MODE_NOTIFY_OTHER;
            s_led_mode = s_last_ble_mode;
            break;
        case JOYCON2_BLE_STATUS_PACKET_REJECTED:
            s_last_ble_mode = LED_MODE_PACKET_REJECTED;
            s_led_mode = s_last_ble_mode;
            break;
        case JOYCON2_BLE_STATUS_NOTIFYING:
            if (s_last_real_input_at != 0 &&
                (int32_t)(xTaskGetTickCount() - s_last_real_input_at) <= (int32_t)pdMS_TO_TICKS(1500)) {
                s_led_mode = LED_MODE_NOTIFICATIONS;
            }
            break;
    }
}

// Button bit masks match the macOS parser.
enum {
    BTN_A      = 0x00000800,
    BTN_B      = 0x00000400,
    BTN_X      = 0x00000200,
    BTN_Y      = 0x00000100,
    BTN_R      = 0x00004000,
    BTN_ZR     = 0x00008000,
    BTN_SL_R   = 0x00002000,
    BTN_SR_R   = 0x00001000,
    BTN_LS     = 0x00080000,
    BTN_RS     = 0x00040000,
    BTN_SELECT = 0x00010000,
    BTN_START  = 0x00020000,
    BTN_HOME   = 0x00100000,
    BTN_CAMERA = 0x00200000,
    BTN_CHAT   = 0x00400000,
    BTN_L      = 0x40000000,
    BTN_ZL     = 0x80000000,
    BTN_SL_L   = 0x20000000,
    BTN_SR_L   = 0x10000000,
};

static int8_t normalize_12bit_axis(uint16_t v, bool invert) {
    // Joy-Con reports 0..4095 with center ~2047.
    double n = ((double)v - 2047.0) / 2047.0;
    if (n < -1.0) n = -1.0;
    if (n > 1.0) n = 1.0;
    if (invert) n = -n;
    int scaled = (int)llround(n * 127.0);
    if (scaled < -127) scaled = -127;
    if (scaled > 127) scaled = 127;
    return (int8_t)scaled;
}

static int8_t normalize_motion_axis(int16_t v, bool invert) {
    // IMU values vary by mode/firmware; scale conservatively for generic HID axes.
    double n = (double)v / 8192.0;
    if (n < -1.0) n = -1.0;
    if (n > 1.0) n = 1.0;
    if (invert) n = -n;
    int scaled = (int)llround(n * 127.0);
    if (scaled < -127) scaled = -127;
    if (scaled > 127) scaled = 127;
    return (int8_t)scaled;
}

static uint8_t hat_from_buttons(uint32_t buttons) {
    // Button bit masks match the macOS parser.
    const uint32_t UP = 0x02000000;
    const uint32_t DOWN = 0x01000000;
    const uint32_t LEFT = 0x08000000;
    const uint32_t RIGHT = 0x04000000;

    bool up = (buttons & UP) != 0;
    bool down = (buttons & DOWN) != 0;
    bool left = (buttons & LEFT) != 0;
    bool right = (buttons & RIGHT) != 0;

    if (up && right) return 2;
    if (right && down) return 4;
    if (down && left) return 6;
    if (left && up) return 8;
    if (up) return 1;
    if (right) return 3;
    if (down) return 5;
    if (left) return 7;
    return 0;
}

static int8_t clamp_i16_to_i8(int v) {
    if (v < -127) return -127;
    if (v > 127) return 127;
    return (int8_t)v;
}

typedef struct {
    joycon2_state_t state;
    bool valid;
    bool has_mouse_sample;
    int16_t last_mouse_x;
    int16_t last_mouse_y;
    double smooth_mouse_x;
    double smooth_mouse_y;
    TickType_t last_optical_motion_at;
    TickType_t mouse_mode_until;
    uint8_t mouse_warmup_samples;
    uint8_t optical_motion_confidence;
} device_slot_t;

static device_slot_t s_left;
static device_slot_t s_right;
static SemaphoreHandle_t s_state_mutex;
static uint32_t s_previous_buttons;
static TickType_t s_button_latch_until[32];

static bool is_right_state(const joycon2_state_t *st) {
    if (st->is_right) return true;
    const uint32_t right_mask = 0x0000FF00u | BTN_R | BTN_ZR | BTN_RS | BTN_START | BTN_HOME | BTN_CHAT;
    return (st->buttons & right_mask) != 0;
}

static bool is_left_state(const joycon2_state_t *st) {
    if (st->is_left) return true;
    const uint32_t left_mask = 0xFF000000u | BTN_L | BTN_ZL | BTN_LS | BTN_SELECT | BTN_CAMERA;
    return (st->buttons & left_mask) != 0;
}

static uint32_t merged_buttons(void) {
    uint32_t buttons = 0;
    if (s_left.valid) buttons |= s_left.state.buttons;
    if (s_right.valid) buttons |= s_right.state.buttons;
    return buttons;
}

static bool any_controller_valid(void) {
    return s_left.valid || s_right.valid;
}

static uint32_t apply_button_latch_locked(uint32_t buttons) {
    uint32_t raw_buttons = buttons;
    TickType_t now = xTaskGetTickCount();
    uint32_t pressed = raw_buttons & ~s_previous_buttons;
    for (int i = 0; i < 32; i++) {
        uint32_t bit = 1UL << i;
        if ((pressed & bit) != 0) {
            s_button_latch_until[i] = now + pdMS_TO_TICKS(55);
        }
        if ((buttons & bit) == 0 &&
            s_button_latch_until[i] != 0 &&
            (int32_t)(s_button_latch_until[i] - now) > 0) {
            buttons |= bit;
        }
    }
    s_previous_buttons = raw_buttons;
    return buttons;
}

static uint16_t latest_left_x(void) {
    return s_left.valid ? s_left.state.left_x : 2047;
}

static uint16_t latest_left_y(void) {
    return s_left.valid ? s_left.state.left_y : 2047;
}

static uint16_t latest_right_x(void) {
    return s_right.valid ? s_right.state.right_x : 2047;
}

static uint16_t latest_right_y(void) {
    return s_right.valid ? s_right.state.right_y : 2047;
}

static bool right_mouse_active(device_slot_t *slot, usb_mouse_report_t *mouse) {
    if (!slot || !slot->valid || !mouse) {
        return false;
    }

    joycon2_state_t *st = &slot->state;
    if (!st->is_right) {
        return false;
    }

    int dx = 0;
    int dy = 0;

    if (!slot->has_mouse_sample) {
        slot->last_mouse_x = st->mouse_x;
        slot->last_mouse_y = st->mouse_y;
        slot->has_mouse_sample = true;
    } else {
        dx = (int)st->mouse_x - (int)slot->last_mouse_x;
        dy = (int)st->mouse_y - (int)slot->last_mouse_y;
        slot->last_mouse_x = st->mouse_x;
        slot->last_mouse_y = st->mouse_y;
    }

    // Optical mode reports absolute-ish counters. Ignore tiny drift and impossible jumps.
    if (abs(dx) > 96 || abs(dy) > 96) {
        dx = 0;
        dy = 0;
    }
    if (abs(dx) <= 1) dx = 0;
    if (abs(dy) <= 1) dy = 0;

    if (dx != 0 || dy != 0) {
        slot->last_optical_motion_at = xTaskGetTickCount();
        slot->mouse_mode_until = slot->last_optical_motion_at + pdMS_TO_TICKS(350);
    }

    bool active = slot->mouse_mode_until != 0 &&
                  (int32_t)(slot->mouse_mode_until - xTaskGetTickCount()) > 0;

    if (!active) {
        slot->smooth_mouse_x = 0.0;
        slot->smooth_mouse_y = 0.0;
        slot->mouse_warmup_samples = 0;
        return false;
    }

    // Keep this low latency. A little smoothing removes single-sample grit without
    // making the cursor feel like it is dragging behind the Joy-Con.
    slot->smooth_mouse_x = (slot->smooth_mouse_x * 0.18) + ((double)dx * 0.82);
    slot->smooth_mouse_y = (slot->smooth_mouse_y * 0.18) + ((double)dy * 0.82);
    mouse->x = clamp_i16_to_i8((int)llround(slot->smooth_mouse_x * 2.0));
    mouse->y = clamp_i16_to_i8((int)llround(slot->smooth_mouse_y * 2.0));

    // In real right Joy-Con mouse mode, shoulder buttons become mouse buttons.
    if (st->buttons & BTN_R) mouse->buttons |= 0x01;
    if (st->buttons & BTN_ZR) mouse->buttons |= 0x02;
    return true;
}

static void build_gamepad_report_locked(usb_gamepad_report_t *r, bool mouse_mode) {
    if (!r) return;
    memset(r, 0, sizeof(*r));
    uint32_t buttons = merged_buttons();

    // In right Joy-Con mouse mode, R/ZR are mouse buttons, not gamepad buttons.
    if (mouse_mode) {
        buttons &= ~(BTN_R | BTN_ZR);
    }
    buttons = apply_button_latch_locked(buttons);

    r->hat = hat_from_buttons(buttons);

    // Use Joy-Con labels for Steam's manual setup prompts.
    if (buttons & BTN_A) r->buttons |= (1u << 0);       // A
    if (buttons & BTN_B) r->buttons |= (1u << 1);       // B
    if (buttons & BTN_X) r->buttons |= (1u << 2);       // X
    if (buttons & BTN_Y) r->buttons |= (1u << 3);       // Y
    if (buttons & BTN_L) r->buttons |= (1u << 4);       // L
    if (buttons & BTN_R) r->buttons |= (1u << 5);       // R
    if (buttons & BTN_ZL) r->buttons |= (1u << 6);      // ZL
    if (buttons & BTN_ZR) r->buttons |= (1u << 7);      // ZR
    if (buttons & BTN_SELECT) r->buttons |= (1u << 8);  // Minus
    if (buttons & BTN_START) r->buttons |= (1u << 9);   // Plus
    if (buttons & BTN_LS) r->buttons |= (1u << 10);     // LS
    if (buttons & BTN_RS) r->buttons |= (1u << 11);     // RS
    if (buttons & BTN_HOME) r->buttons |= (1u << 12);   // Home
    if (buttons & BTN_CAMERA) r->buttons |= (1u << 13); // Capture
    if (buttons & BTN_CHAT) r->buttons |= (1u << 14);   // GameChat
    if (buttons & BTN_SL_L) r->buttons |= (1u << 15);   // SL(L)
    if (buttons & BTN_SR_L) r->buttons |= (1u << 16);   // SR(L)
    if (buttons & BTN_SL_R) r->buttons |= (1u << 17);   // SL(R)
    if (buttons & BTN_SR_R) r->buttons |= (1u << 18);   // SR(R)

    r->lx = normalize_12bit_axis(latest_left_x(), false);
    r->ly = normalize_12bit_axis(latest_left_y(), true);
    r->rx = normalize_12bit_axis(latest_right_x(), false);
    r->ry = normalize_12bit_axis(latest_right_y(), true);
    if (s_right.valid) {
        r->gyro_x = normalize_motion_axis(s_right.state.gyro_y, false);
        r->gyro_y = normalize_motion_axis(s_right.state.gyro_x, true);
    }
}

static void on_joycon_state(const joycon2_state_t *st) {
    if (!st) return;
    bool accepted = false;

    if (s_state_mutex) {
        xSemaphoreTake(s_state_mutex, portMAX_DELAY);
    }

    if (is_right_state(st)) {
        s_right.state = *st;
        s_right.state.is_right = true;
        s_right.state.is_left = false;
        s_right.valid = true;
        accepted = true;
    } else if (is_left_state(st)) {
        s_left.state = *st;
        s_left.state.is_left = true;
        s_left.state.is_right = false;
        s_left.valid = true;
        accepted = true;
    }

    if (s_state_mutex) {
        xSemaphoreGive(s_state_mutex);
    }

    if (accepted) {
        s_last_real_input_at = xTaskGetTickCount();
        s_led_mode = LED_MODE_NOTIFICATIONS;
    }
}

static void usb_report_task(void *param) {
    (void)param;
    while (1) {
        usb_mouse_report_t m = {0};
        usb_gamepad_report_t r = {0};
        bool mouse_mode = false;

        if (s_state_mutex) {
            xSemaphoreTake(s_state_mutex, portMAX_DELAY);
        }

        bool has_controller = any_controller_valid();
        if (has_controller) {
            mouse_mode = right_mouse_active(&s_right, &m);
            build_gamepad_report_locked(&r, mouse_mode);
        }

        if (s_state_mutex) {
            xSemaphoreGive(s_state_mutex);
        }

        if (r.buttons != 0 || has_controller) {
            usb_hid_gamepad_send(&r);
            usb_hid_mouse_send(&m);
        }
        vTaskDelay(pdMS_TO_TICKS(5));
    }
}

void app_main(void) {
    ESP_LOGI(TAG, "Starting JoyCon2forMac ESP32-S3 dongle (scaffold)");
    status_led_init();
    // LED patterns: slow=scanning, fast=found/connecting, double=connected, solid=input flowing.
    xTaskCreatePinnedToCore(status_led_blink_task, "led_blink", 2048, NULL, 1, NULL, 1);
    s_state_mutex = xSemaphoreCreateMutex();
    usb_hid_gamepad_init();
    xTaskCreatePinnedToCore(usb_report_task, "usb_report", 4096, NULL, 2, NULL, 1);
    joycon2_ble_set_status_callback(on_ble_status);
    joycon2_ble_start(on_joycon_state);

    while (1) {
        // esp_tinyusb runs its own task after driver install.
        vTaskDelay(pdMS_TO_TICKS(50));
    }
}
