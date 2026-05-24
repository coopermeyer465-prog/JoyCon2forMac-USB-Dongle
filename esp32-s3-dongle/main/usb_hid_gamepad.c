#include "usb_hid_gamepad.h"

#include "esp_err.h"
#include "esp_log.h"
#include "esp_mac.h"
#include "esp_system.h"
#include "tinyusb.h"
#include "tinyusb_default_config.h"
#include "tusb.h"
#include "class/hid/hid_device.h"

static const char *TAG = "usb_hid";

enum {
    ITF_NUM_GAMEPAD = 0,
    ITF_NUM_MOUSE,
    ITF_NUM_TOTAL,
};

static usb_hid_mode_t s_usb_mode = USB_HID_MODE_COMPUTER;

// Explicit HID configuration descriptor. This is intentionally HID-only because
// the CDC composite variant was unreliable on the XIAO ESP32-S3 USB-C port.
#define COMPUTER_DESC_TOTAL_LEN      (TUD_CONFIG_DESC_LEN + (2 * TUD_HID_DESC_LEN))
#define SWITCH_DESC_TOTAL_LEN        (TUD_CONFIG_DESC_LEN + TUD_HID_INOUT_DESC_LEN)

// Conventional TinyUSB gamepad layout:
// X,Y,Z,Rz,Rx,Ry (6 axes) + hat byte + 32 button bits.
// This is much friendlier to Steam's "Generic Controller" HID path than the
// earlier custom 24-button report.
static const uint8_t gamepad_report_descriptor[] = {
    TUD_HID_REPORT_DESC_GAMEPAD()
};

static const uint8_t mouse_report_descriptor[] = {
    0x05, 0x01,        // Usage Page (Generic Desktop)
    0x09, 0x02,        // Usage (Mouse)
    0xA1, 0x01,        // Collection (Application)
    0x09, 0x01,        //   Usage (Pointer)
    0xA1, 0x00,        //   Collection (Physical)
    0x05, 0x09,        //     Usage Page (Button)
    0x19, 0x01,        //     Usage Minimum (Button 1)
    0x29, 0x03,        //     Usage Maximum (Button 3)
    0x15, 0x00,        //     Logical Minimum (0)
    0x25, 0x01,        //     Logical Maximum (1)
    0x95, 0x03,        //     Report Count (3)
    0x75, 0x01,        //     Report Size (1)
    0x81, 0x02,        //     Input (Data,Var,Abs)
    0x95, 0x01,        //     Report Count (1)
    0x75, 0x05,        //     Report Size (5)
    0x81, 0x03,        //     Input (Cnst,Var,Abs)
    0x05, 0x01,        //     Usage Page (Generic Desktop)
    0x09, 0x30,        //     Usage (X)
    0x09, 0x31,        //     Usage (Y)
    0x09, 0x38,        //     Usage (Wheel)
    0x15, 0x81,        //     Logical Minimum (-127)
    0x25, 0x7F,        //     Logical Maximum (127)
    0x75, 0x08,        //     Report Size (8)
    0x95, 0x03,        //     Report Count (3)
    0x81, 0x06,        //     Input (Data,Var,Rel)
    0xC0,              //   End Collection
    0xC0               // End Collection
};

// Switch-compatible HORI/Pokken-style USB HID report descriptor. This avoids
// the full Nintendo Pro Controller handshake while still giving the console
// buttons, D-pad, and two analog sticks.
static const uint8_t switch_report_descriptor[] = {
    0x05, 0x01,        // Usage Page (Generic Desktop)
    0x09, 0x05,        // Usage (Game Pad)
    0xA1, 0x01,        // Collection (Application)
    0x15, 0x00,        //   Logical Minimum (0)
    0x25, 0x01,        //   Logical Maximum (1)
    0x35, 0x00,        //   Physical Minimum (0)
    0x45, 0x01,        //   Physical Maximum (1)
    0x75, 0x01,        //   Report Size (1)
    0x95, 0x10,        //   Report Count (16)
    0x05, 0x09,        //   Usage Page (Button)
    0x19, 0x01,        //   Usage Minimum (Button 1)
    0x29, 0x10,        //   Usage Maximum (Button 16)
    0x81, 0x02,        //   Input (Data,Var,Abs)
    0x05, 0x01,        //   Usage Page (Generic Desktop)
    0x25, 0x07,        //   Logical Maximum (7)
    0x46, 0x3B, 0x01,  //   Physical Maximum (315)
    0x75, 0x04,        //   Report Size (4)
    0x95, 0x01,        //   Report Count (1)
    0x65, 0x14,        //   Unit (English Rotation, degrees)
    0x09, 0x39,        //   Usage (Hat switch)
    0x81, 0x42,        //   Input (Data,Var,Abs,Null)
    0x65, 0x00,        //   Unit (None)
    0x95, 0x01,        //   Report Count (1)
    0x81, 0x01,        //   Input (Constant)
    0x26, 0xFF, 0x00,  //   Logical Maximum (255)
    0x46, 0xFF, 0x00,  //   Physical Maximum (255)
    0x09, 0x30,        //   Usage (X)
    0x09, 0x31,        //   Usage (Y)
    0x09, 0x32,        //   Usage (Z)
    0x09, 0x35,        //   Usage (Rz)
    0x75, 0x08,        //   Report Size (8)
    0x95, 0x04,        //   Report Count (4)
    0x81, 0x02,        //   Input (Data,Var,Abs)
    0x06, 0x00, 0xFF,  //   Usage Page (Vendor Defined)
    0x09, 0x20,        //   Usage (0x20)
    0x95, 0x01,        //   Report Count (1)
    0x81, 0x02,        //   Input (Data,Var,Abs)
    0x0A, 0x21, 0x26,  //   Usage (0x2621)
    0x95, 0x08,        //   Report Count (8)
    0x91, 0x02,        //   Output (Data,Var,Abs)
    0xC0               // End Collection
};

static const tusb_desc_device_t switch_device_descriptor = {
    .bLength = sizeof(tusb_desc_device_t),
    .bDescriptorType = TUSB_DESC_DEVICE,
    .bcdUSB = 0x0200,
    .bDeviceClass = 0x00,
    .bDeviceSubClass = 0x00,
    .bDeviceProtocol = 0x00,
    .bMaxPacketSize0 = CFG_TUD_ENDPOINT0_SIZE,
    .idVendor = 0x0F0D,
    .idProduct = 0x0092,
    .bcdDevice = 0x0100,
    .iManufacturer = 0x01,
    .iProduct = 0x02,
    .iSerialNumber = 0x03,
    .bNumConfigurations = 0x01,
};

// String descriptor table:
// - Index 0 is language ID.
// - Index 1..N are referenced by the configuration descriptor.
static char s_serial_str[16] = "000000000000";
static const char *hid_string_descriptor[] = {
    (char[]){0x09, 0x04},  // 0: English (0x0409)
    "JoyCon2forMac",       // 1: Manufacturer
    "JoyCon2 USB Dongle",  // 2: Product
    s_serial_str,          // 3: Serial
    "Gamepad",             // 4: Gamepad HID Interface
    "Mouse",               // 5: Mouse HID Interface
};

static const char *switch_string_descriptor[] = {
    (char[]){0x09, 0x04},   // 0: English (0x0409)
    "HORI CO.,LTD.",        // 1: Manufacturer
    "POKKEN CONTROLLER",    // 2: Product
    s_serial_str,           // 3: Serial
    "Controller",           // 4: HID Interface
};

// 1 configuration, 2 HID interfaces: one standard gamepad, one standard mouse.
static const uint8_t computer_configuration_descriptor[] = {
    TUD_CONFIG_DESCRIPTOR(1, ITF_NUM_TOTAL, 0, COMPUTER_DESC_TOTAL_LEN, TUSB_DESC_CONFIG_ATT_REMOTE_WAKEUP, 100),
    TUD_HID_DESCRIPTOR(ITF_NUM_GAMEPAD, 4, false, sizeof(gamepad_report_descriptor), 0x81, 16, 1),
    TUD_HID_DESCRIPTOR(ITF_NUM_MOUSE, 5, HID_ITF_PROTOCOL_MOUSE, sizeof(mouse_report_descriptor), 0x82, 16, 1),
};

static const uint8_t switch_configuration_descriptor[] = {
    TUD_CONFIG_DESCRIPTOR(1, 1, 0, SWITCH_DESC_TOTAL_LEN, 0, 500),
    TUD_HID_INOUT_DESCRIPTOR(0, 4, false, sizeof(switch_report_descriptor), 0x02, 0x81, 64, 1),
};

// TinyUSB callbacks (minimal).
uint8_t const *tud_hid_descriptor_report_cb(uint8_t instance) {
    if (s_usb_mode == USB_HID_MODE_SWITCH) {
        return switch_report_descriptor;
    }
    if (instance == ITF_NUM_MOUSE) {
        return mouse_report_descriptor;
    }
    return gamepad_report_descriptor;
}

uint16_t tud_hid_get_report_cb(uint8_t instance, uint8_t report_id, hid_report_type_t report_type,
                               uint8_t *buffer, uint16_t reqlen) {
    (void)instance;
    (void)report_id;
    (void)report_type;
    (void)buffer;
    (void)reqlen;
    return 0;
}

void tud_hid_set_report_cb(uint8_t instance, uint8_t report_id, hid_report_type_t report_type,
                           uint8_t const *buffer, uint16_t bufsize) {
    (void)instance;
    (void)report_id;
    (void)report_type;
    (void)buffer;
    (void)bufsize;
}

void usb_hid_gamepad_init(usb_hid_mode_t mode) {
    s_usb_mode = mode;

    // Use chip MAC as a stable-ish serial string.
    uint8_t mac[6] = {0};
    (void)esp_efuse_mac_get_default(mac);
    snprintf(s_serial_str, sizeof(s_serial_str), "%02X%02X%02X%02X%02X%02X",
             mac[0], mac[1], mac[2], mac[3], mac[4], mac[5]);

    ESP_LOGI(TAG, "TinyUSB driver install (%s mode)", s_usb_mode == USB_HID_MODE_SWITCH ? "Switch" : "computer");
    tinyusb_config_t cfg = TINYUSB_DEFAULT_CONFIG();
    if (s_usb_mode == USB_HID_MODE_SWITCH) {
        cfg.descriptor.device = &switch_device_descriptor;
        cfg.descriptor.string = switch_string_descriptor;
        cfg.descriptor.string_count = sizeof(switch_string_descriptor) / sizeof(switch_string_descriptor[0]);
        cfg.descriptor.full_speed_config = switch_configuration_descriptor;
    } else {
        cfg.descriptor.string = hid_string_descriptor;
        cfg.descriptor.string_count = sizeof(hid_string_descriptor) / sizeof(hid_string_descriptor[0]);
        cfg.descriptor.full_speed_config = computer_configuration_descriptor;
    }
    cfg.descriptor.high_speed_config = NULL;
    esp_err_t err = tinyusb_driver_install(&cfg);
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "tinyusb_driver_install failed err=0x%x", (unsigned int)err);
        return;
    }
}

usb_hid_mode_t usb_hid_current_mode(void) {
    return s_usb_mode;
}

static uint8_t axis_i8_to_u8(int8_t v) {
    int out = (int)v + 128;
    if (out < 0) return 0;
    if (out > 255) return 255;
    return (uint8_t)out;
}

static uint8_t switch_hat_from_tinyusb_hat(uint8_t hat) {
    // Switch/HORI hat: 0=up, 1=up-right, ... 7=up-left, 8=centered.
    static const uint8_t map[] = {8, 0, 1, 2, 3, 4, 5, 6, 7};
    if (hat < sizeof(map)) {
        return map[hat];
    }
    return 8;
}

static uint16_t switch_buttons_from_generic(uint32_t buttons) {
    uint16_t out = 0;
    if (buttons & (1u << 3)) out |= 0x0001;  // Y
    if (buttons & (1u << 1)) out |= 0x0002;  // B
    if (buttons & (1u << 0)) out |= 0x0004;  // A
    if (buttons & (1u << 2)) out |= 0x0008;  // X
    if (buttons & (1u << 4)) out |= 0x0010;  // L
    if (buttons & (1u << 5)) out |= 0x0020;  // R
    if (buttons & (1u << 6)) out |= 0x0040;  // ZL
    if (buttons & (1u << 7)) out |= 0x0080;  // ZR
    if (buttons & (1u << 8)) out |= 0x0100;  // Minus
    if (buttons & (1u << 9)) out |= 0x0200;  // Plus
    if (buttons & (1u << 10)) out |= 0x0400; // Left stick press
    if (buttons & (1u << 11)) out |= 0x0800; // Right stick press
    if (buttons & (1u << 12)) out |= 0x1000; // Home
    if (buttons & (1u << 13)) out |= 0x2000; // Capture
    return out;
}

void usb_hid_gamepad_send(const usb_gamepad_report_t *report) {
    if (!tud_hid_n_ready(ITF_NUM_GAMEPAD) || !report) {
        return;
    }
    if (s_usb_mode == USB_HID_MODE_SWITCH) {
        // The HORI/Pokken endpoint is 64 bytes. The useful report is the first
        // 8 bytes, but sending a full interrupt packet keeps picky hosts happy.
        uint8_t buf[64] = {0};
        uint16_t buttons = switch_buttons_from_generic(report->buttons);
        buf[0] = (uint8_t)(buttons & 0xFF);
        buf[1] = (uint8_t)((buttons >> 8) & 0xFF);
        buf[2] = switch_hat_from_tinyusb_hat(report->hat);
        buf[3] = axis_i8_to_u8(report->lx);
        buf[4] = axis_i8_to_u8(report->ly);
        buf[5] = axis_i8_to_u8(report->rx);
        buf[6] = axis_i8_to_u8(report->ry);
        buf[7] = 0;
        tud_hid_n_report(ITF_NUM_GAMEPAD, 0, buf, sizeof(buf));
        return;
    }

    uint8_t buf[11];
    buf[0] = (uint8_t)report->lx; // X
    buf[1] = (uint8_t)report->ly; // Y
    buf[2] = (uint8_t)report->rx; // Z
    buf[3] = (uint8_t)report->ry; // Rz
    // Keep spare axes neutral. Steam's generic controller setup can mistake
    // noisy IMU axes for input while it is waiting for button presses.
    buf[4] = 0; // Rx
    buf[5] = 0; // Ry
    buf[6] = report->hat;         // 0=centered, 1=up ... 8=up-left
    buf[7] = (uint8_t)(report->buttons & 0xFF);
    buf[8] = (uint8_t)((report->buttons >> 8) & 0xFF);
    buf[9] = (uint8_t)((report->buttons >> 16) & 0xFF);
    buf[10] = (uint8_t)((report->buttons >> 24) & 0xFF);
    tud_hid_n_report(ITF_NUM_GAMEPAD, 0, buf, sizeof(buf));
}

void usb_hid_mouse_send(const usb_mouse_report_t *report) {
    if (s_usb_mode == USB_HID_MODE_SWITCH) {
        return;
    }
    if (!tud_hid_n_ready(ITF_NUM_MOUSE) || !report) {
        return;
    }
    uint8_t buf[4];
    buf[0] = report->buttons;
    buf[1] = (uint8_t)report->x;
    buf[2] = (uint8_t)report->y;
    buf[3] = (uint8_t)report->wheel;
    tud_hid_n_report(ITF_NUM_MOUSE, 0, buf, sizeof(buf));
}
