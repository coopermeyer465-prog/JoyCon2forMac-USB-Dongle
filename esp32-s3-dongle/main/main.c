#include <stdio.h>
#include <math.h>

#include "esp_log.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"

#include "joycon2_ble.h"
#include "usb_hid_gamepad.h"

static const char *TAG = "main";

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

static int8_t clamp_i16_to_i8(int v) {
    if (v < -127) return -127;
    if (v > 127) return 127;
    return (int8_t)v;
}

static void on_joycon_state(const joycon2_state_t *st) {
    if (!st) return;

    // "Mouse mode" is a simple modifier: hold Right Stick press (RS) to enable mouse reports.
    // This keeps the dongle gamepad-first while still allowing cursor navigation without a Mac app.
    bool rs = (st->buttons & BTN_RS) != 0;
    bool mouse_mode = rs;

    usb_gamepad_report_t r = {0};
    r.hat = hat_from_buttons(st->buttons);

    // Map common buttons to the first 8 bits, using the Joy-Con bit masks.
    // A/B/X/Y:
    if (st->buttons & BTN_A) r.buttons |= (1u << 0); // A
    if (st->buttons & BTN_B) r.buttons |= (1u << 1); // B
    if (st->buttons & BTN_X) r.buttons |= (1u << 2); // X
    if (st->buttons & BTN_Y) r.buttons |= (1u << 3); // Y
    // L/R/ZL/ZR:
    if (st->buttons & BTN_L) r.buttons |= (1u << 4); // L
    if (st->buttons & BTN_R) r.buttons |= (1u << 5); // R
    if (st->buttons & BTN_ZL) r.buttons |= (1u << 6); // ZL
    if (st->buttons & BTN_ZR) r.buttons |= (1u << 7); // ZR

    // Secondary buttons (bits 8..18).
    if (st->buttons & BTN_LS) r.buttons |= (1u << 8);       // LS
    if (st->buttons & BTN_RS) r.buttons |= (1u << 9);       // RS
    if (st->buttons & BTN_SELECT) r.buttons |= (1u << 10);  // Minus
    if (st->buttons & BTN_START) r.buttons |= (1u << 11);   // Plus
    if (st->buttons & BTN_HOME) r.buttons |= (1u << 12);    // Home
    if (st->buttons & BTN_CAMERA) r.buttons |= (1u << 13);  // Capture
    if (st->buttons & BTN_CHAT) r.buttons |= (1u << 14);    // GameChat
    if (st->buttons & BTN_SL_L) r.buttons |= (1u << 15);    // SL(L)
    if (st->buttons & BTN_SR_L) r.buttons |= (1u << 16);    // SR(L)
    if (st->buttons & BTN_SL_R) r.buttons |= (1u << 17);    // SL(R)
    if (st->buttons & BTN_SR_R) r.buttons |= (1u << 18);    // SR(R)

    r.lx = normalize_12bit_axis(st->left_x, false);
    r.ly = normalize_12bit_axis(st->left_y, true);
    r.rx = normalize_12bit_axis(st->right_x, false);
    r.ry = normalize_12bit_axis(st->right_y, true);

    usb_hid_gamepad_send(&r);

    // Optional mouse output. Use right stick while RS is held.
    usb_mouse_report_t m = {0};
    if (mouse_mode) {
        // Convert stick to relative mouse deltas. Keep it conservative; users can tune later.
        const int kStickToMouse = 8; // higher = faster cursor
        int dx = (int)r.rx / kStickToMouse;
        int dy = (int)r.ry / kStickToMouse;
        m.x = clamp_i16_to_i8(dx);
        m.y = clamp_i16_to_i8(dy);

        // Mouse click mappings in mouse mode:
        // - R  -> left click (drag-select capable)
        // - ZR -> right click
        if (st->buttons & BTN_R) m.buttons |= 0x01;
        if (st->buttons & BTN_ZR) m.buttons |= 0x02;
    }
    usb_hid_mouse_send(&m);
}

void app_main(void) {
    ESP_LOGI(TAG, "Starting JoyCon2forMac ESP32-S3 dongle (scaffold)");
    usb_hid_gamepad_init();
    joycon2_ble_start(on_joycon_state);

    while (1) {
        // esp_tinyusb runs its own task after driver install.
        vTaskDelay(pdMS_TO_TICKS(50));
    }
}
