#pragma once

#include <stdint.h>
#include <stdbool.h>

typedef struct {
    uint32_t buttons;
    uint16_t left_x;
    uint16_t left_y;
    uint16_t right_x;
    uint16_t right_y;
    int16_t mouse_x;
    int16_t mouse_y;
    uint8_t trigger_l;
    uint8_t trigger_r;
    bool is_right;
    bool is_left;
} joycon2_state_t;

typedef void (*joycon2_state_cb_t)(const joycon2_state_t *state);

// Start BLE scan/connect + notifications and call `cb` for each parsed packet.
void joycon2_ble_start(joycon2_state_cb_t cb);

