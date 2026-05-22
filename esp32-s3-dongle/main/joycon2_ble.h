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
    int16_t mouse_unk;
    int16_t mouse_distance;
    int16_t accel_x;
    int16_t accel_y;
    int16_t accel_z;
    int16_t gyro_x;
    int16_t gyro_y;
    int16_t gyro_z;
    uint8_t trigger_l;
    uint8_t trigger_r;
    bool is_right;
    bool is_left;
} joycon2_state_t;

typedef void (*joycon2_state_cb_t)(const joycon2_state_t *state);

typedef enum {
    JOYCON2_BLE_STATUS_SCANNING = 0,
    JOYCON2_BLE_STATUS_FOUND,
    JOYCON2_BLE_STATUS_CONNECTED,
    JOYCON2_BLE_STATUS_SUBSCRIBED,
    JOYCON2_BLE_STATUS_NOTIFY_OTHER,
    JOYCON2_BLE_STATUS_PACKET_REJECTED,
    JOYCON2_BLE_STATUS_NOTIFYING,
    JOYCON2_BLE_STATUS_DISCONNECTED,
} joycon2_ble_status_t;

typedef void (*joycon2_status_cb_t)(joycon2_ble_status_t status);

void joycon2_ble_set_status_callback(joycon2_status_cb_t cb);

// Start BLE scan/connect + notifications and call `cb` for each parsed packet.
void joycon2_ble_start(joycon2_state_cb_t cb);
