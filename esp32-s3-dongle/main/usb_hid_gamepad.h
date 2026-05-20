#pragma once

#include <stdint.h>

typedef struct {
    uint16_t buttons; // bits 0..15
    uint8_t hat;      // 0..7, 8 = neutral
    int8_t lx;
    int8_t ly;
    int8_t rx;
    int8_t ry;
} usb_gamepad_report_t;

void usb_hid_gamepad_init(void);
void usb_hid_gamepad_send(const usb_gamepad_report_t *report);

