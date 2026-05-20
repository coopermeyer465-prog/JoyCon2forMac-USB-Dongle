#include <stdio.h>
#include <math.h>

#include "esp_log.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"

#include "joycon2_ble.h"
#include "usb_hid_gamepad.h"

static const char *TAG = "main";

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

    if (up && right) return 1;
    if (right && down) return 3;
    if (down && left) return 5;
    if (left && up) return 7;
    if (up) return 0;
    if (right) return 2;
    if (down) return 4;
    if (left) return 6;
    return 8;
}

static void on_joycon_state(const joycon2_state_t *st) {
    if (!st) return;

    usb_gamepad_report_t r = {0};
    r.hat = hat_from_buttons(st->buttons);

    // Map common buttons to the first 8 bits, using the Joy-Con bit masks.
    // A/B/X/Y:
    if (st->buttons & 0x00000800) r.buttons |= (1u << 0); // A
    if (st->buttons & 0x00000400) r.buttons |= (1u << 1); // B
    if (st->buttons & 0x00000200) r.buttons |= (1u << 2); // X
    if (st->buttons & 0x00000100) r.buttons |= (1u << 3); // Y
    // L/R/ZL/ZR:
    if (st->buttons & 0x40000000) r.buttons |= (1u << 4); // L
    if (st->buttons & 0x00004000) r.buttons |= (1u << 5); // R
    if (st->buttons & 0x80000000) r.buttons |= (1u << 6); // ZL
    if (st->buttons & 0x00008000) r.buttons |= (1u << 7); // ZR

    r.lx = normalize_12bit_axis(st->left_x, false);
    r.ly = normalize_12bit_axis(st->left_y, true);
    r.rx = normalize_12bit_axis(st->right_x, false);
    r.ry = normalize_12bit_axis(st->right_y, true);

    usb_hid_gamepad_send(&r);
}

void app_main(void) {
    ESP_LOGI(TAG, "Starting JoyCon2forMac ESP32-S3 dongle (scaffold)");
    usb_hid_gamepad_init();
    joycon2_ble_start(on_joycon_state);

    while (1) {
        tud_task();
        vTaskDelay(pdMS_TO_TICKS(5));
    }
}

