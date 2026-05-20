#include "joycon2_ble.h"

#include <string.h>

#include "esp_log.h"

// NOTE: This is a scaffold. Implementing Joy-Con 2 BLE central + GATT discovery using NimBLE
// is non-trivial and should be done carefully (bonding, reconnection, MTU, notifications, etc).
//
// We already know the important pieces from the macOS implementation:
// - manufacturer ID filter: 0x0553
// - write characteristic UUID: 649D4AC9-8EB7-4E6C-AF44-1EA54FE5F005
// - notify characteristic UUID: AB7DE9BE-89FE-49AD-828F-118F09DF7FD2
// - init commands (12 bytes each, write-without-response)
//
// Next step: implement NimBLE scan -> connect -> discover characteristics -> subscribe -> write init commands.

static const char *TAG = "joycon2_ble";

static joycon2_state_cb_t s_cb = NULL;

static uint16_t read_le_u16(const uint8_t *buf) {
    return (uint16_t)buf[0] | ((uint16_t)buf[1] << 8);
}

static int16_t read_le_i16(const uint8_t *buf) {
    return (int16_t)read_le_u16(buf);
}

static uint32_t read_le_u32(const uint8_t *buf) {
    return (uint32_t)buf[0] |
           ((uint32_t)buf[1] << 8) |
           ((uint32_t)buf[2] << 16) |
           ((uint32_t)buf[3] << 24);
}

static void parse_packet(const uint8_t *data, size_t len, joycon2_state_t *out) {
    if (!data || !out || len < 0x3E) {
        return;
    }

    memset(out, 0, sizeof(*out));
    out->buttons = read_le_u32(&data[3]);
    out->trigger_l = data[0x3C];
    out->trigger_r = data[0x3D];

    // Stick parse matches macOS version: 12-bit packed pairs in 3 bytes.
    auto parse_stick = [](const uint8_t *p, uint16_t *x, uint16_t *y) {
        uint32_t v = (uint32_t)p[0] | ((uint32_t)p[1] << 8) | ((uint32_t)p[2] << 16);
        *x = (uint16_t)(v & 0x0FFF);
        *y = (uint16_t)((v >> 12) & 0x0FFF);
    };

    parse_stick(&data[0x0A], &out->left_x, &out->left_y);
    parse_stick(&data[0x0D], &out->right_x, &out->right_y);

    out->mouse_x = read_le_i16(&data[0x10]);
    out->mouse_y = read_le_i16(&data[0x12]);
}

void joycon2_ble_start(joycon2_state_cb_t cb) {
    s_cb = cb;
    ESP_LOGW(TAG, "BLE central implementation is not wired up yet. This is a scaffold.");
    (void)parse_packet;
}

