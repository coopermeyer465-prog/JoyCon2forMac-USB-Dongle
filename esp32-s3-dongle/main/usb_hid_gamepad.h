#pragma once

#include <stdint.h>

typedef struct {
    uint32_t buttons; // bits 0..31
    uint8_t hat;      // TinyUSB gamepad: 0=centered, 1=up ... 8=up-left
    int8_t lx;
    int8_t ly;
    int8_t rx;
    int8_t ry;
    int8_t gyro_x;
    int8_t gyro_y;
} usb_gamepad_report_t;

typedef struct {
    uint8_t buttons; // bit0=left, bit1=right, bit2=middle
    int8_t x;
    int8_t y;
    int8_t wheel;
} usb_mouse_report_t;

void usb_hid_gamepad_init(void);
void usb_hid_gamepad_send(const usb_gamepad_report_t *report);
void usb_hid_mouse_send(const usb_mouse_report_t *report);
