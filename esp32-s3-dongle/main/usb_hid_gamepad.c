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

// Explicit HID configuration descriptor. This is intentionally HID-only because
// the CDC composite variant was unreliable on the XIAO ESP32-S3 USB-C port.
#define TUSB_DESC_TOTAL_LEN      (TUD_CONFIG_DESC_LEN + (2 * TUD_HID_DESC_LEN))

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

// 1 configuration, 2 HID interfaces: one standard gamepad, one standard mouse.
static const uint8_t hid_configuration_descriptor[] = {
    TUD_CONFIG_DESCRIPTOR(1, ITF_NUM_TOTAL, 0, TUSB_DESC_TOTAL_LEN, TUSB_DESC_CONFIG_ATT_REMOTE_WAKEUP, 100),
    TUD_HID_DESCRIPTOR(ITF_NUM_GAMEPAD, 4, false, sizeof(gamepad_report_descriptor), 0x81, 16, 1),
    TUD_HID_DESCRIPTOR(ITF_NUM_MOUSE, 5, HID_ITF_PROTOCOL_MOUSE, sizeof(mouse_report_descriptor), 0x82, 16, 1),
};

// TinyUSB callbacks (minimal).
uint8_t const *tud_hid_descriptor_report_cb(uint8_t instance) {
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

void usb_hid_gamepad_init(void) {
    // Use chip MAC as a stable-ish serial string.
    uint8_t mac[6] = {0};
    (void)esp_efuse_mac_get_default(mac);
    snprintf(s_serial_str, sizeof(s_serial_str), "%02X%02X%02X%02X%02X%02X",
             mac[0], mac[1], mac[2], mac[3], mac[4], mac[5]);

    ESP_LOGI(TAG, "TinyUSB driver install (HID config descriptor)");
    tinyusb_config_t cfg = TINYUSB_DEFAULT_CONFIG();
    cfg.descriptor.string = hid_string_descriptor;
    cfg.descriptor.string_count = sizeof(hid_string_descriptor) / sizeof(hid_string_descriptor[0]);
    cfg.descriptor.full_speed_config = hid_configuration_descriptor;
    cfg.descriptor.high_speed_config = NULL;
    esp_err_t err = tinyusb_driver_install(&cfg);
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "tinyusb_driver_install failed err=0x%x", (unsigned int)err);
        return;
    }
}

void usb_hid_gamepad_send(const usb_gamepad_report_t *report) {
    if (!tud_hid_n_ready(ITF_NUM_GAMEPAD) || !report) {
        return;
    }
    uint8_t buf[11];
    buf[0] = (uint8_t)report->lx; // X
    buf[1] = (uint8_t)report->ly; // Y
    buf[2] = (uint8_t)report->rx; // Z
    buf[3] = (uint8_t)report->ry; // Rz
    buf[4] = 0;                   // Rx
    buf[5] = 0;                   // Ry
    buf[6] = report->hat;         // 0=centered, 1=up ... 8=up-left
    buf[7] = (uint8_t)(report->buttons & 0xFF);
    buf[8] = (uint8_t)((report->buttons >> 8) & 0xFF);
    buf[9] = (uint8_t)((report->buttons >> 16) & 0xFF);
    buf[10] = (uint8_t)((report->buttons >> 24) & 0xFF);
    tud_hid_n_report(ITF_NUM_GAMEPAD, 0, buf, sizeof(buf));
}

void usb_hid_mouse_send(const usb_mouse_report_t *report) {
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
