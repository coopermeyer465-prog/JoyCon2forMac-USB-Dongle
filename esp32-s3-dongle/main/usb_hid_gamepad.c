#include "usb_hid_gamepad.h"

#include "esp_err.h"
#include "esp_log.h"
#include "esp_mac.h"
#include "esp_system.h"
#include "tinyusb.h"
#include "tinyusb_default_config.h"
#include "tusb.h"
#include "class/hid/hid_device.h"
#include "tusb_cdc_acm.h"
#include "tusb_console.h"

static const char *TAG = "usb_hid";

enum {
    REPORT_ID_GAMEPAD = 1,
    REPORT_ID_MOUSE = 2,
};

// Composite device: CDC (for logs/debug) + HID (gamepad+mouse).
// CDC consumes 2 interfaces, HID consumes 1 => 3 interfaces total.
#define TUSB_DESC_TOTAL_LEN      (TUD_CONFIG_DESC_LEN + TUD_CDC_DESC_LEN + TUD_HID_DESC_LEN)

// Report layout matches the macOS app's virtual gamepad: 16 buttons + hat + 4 axes.
static const uint8_t hid_report_descriptor[] = {
    0x05, 0x01,        // Usage Page (Generic Desktop)
    0x09, 0x05,        // Usage (Game Pad)
    0xA1, 0x01,        // Collection (Application)
    0x85, REPORT_ID_GAMEPAD, //   Report ID
    0x05, 0x09,        //   Usage Page (Button)
    0x19, 0x01,        //   Usage Minimum (Button 1)
    0x29, 0x18,        //   Usage Maximum (Button 24)
    0x15, 0x00,        //   Logical Minimum (0)
    0x25, 0x01,        //   Logical Maximum (1)
    0x75, 0x01,        //   Report Size (1)
    0x95, 0x18,        //   Report Count (24)
    0x81, 0x02,        //   Input (Data,Var,Abs)
    0x05, 0x01,        //   Usage Page (Generic Desktop)
    0x09, 0x39,        //   Usage (Hat switch)
    0x15, 0x00,        //   Logical Minimum (0)
    0x25, 0x07,        //   Logical Maximum (7)
    0x35, 0x00,        //   Physical Minimum (0)
    0x46, 0x3B, 0x01,  //   Physical Maximum (315)
    0x65, 0x14,        //   Unit (Eng Rot: Degree)
    0x75, 0x04,        //   Report Size (4)
    0x95, 0x01,        //   Report Count (1)
    0x81, 0x42,        //   Input (Data,Var,Abs,Null)
    0x75, 0x04,        //   Report Size (4)
    0x95, 0x01,        //   Report Count (1)
    0x81, 0x03,        //   Input (Cnst,Var,Abs)
    0x09, 0x30,        //   Usage (X)
    0x09, 0x31,        //   Usage (Y)
    0x09, 0x33,        //   Usage (Rx)
    0x09, 0x34,        //   Usage (Ry)
    0x15, 0x81,        //   Logical Minimum (-127)
    0x25, 0x7F,        //   Logical Maximum (127)
    0x75, 0x08,        //   Report Size (8)
    0x95, 0x04,        //   Report Count (4)
    0x81, 0x02,        //   Input (Data,Var,Abs)
    0xC0               // End Collection

    ,
    // Mouse (relative), for optional cursor mode while still presenting as a normal gamepad.
    0x05, 0x01,        // Usage Page (Generic Desktop)
    0x09, 0x02,        // Usage (Mouse)
    0xA1, 0x01,        // Collection (Application)
    0x85, REPORT_ID_MOUSE, //   Report ID
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
    "Gamepad + Mouse",     // 4: HID Interface
    "USB Serial",          // 5: CDC Interface
};

enum {
    ITF_NUM_CDC = 0,
    ITF_NUM_CDC_DATA,
    ITF_NUM_HID,
    ITF_NUM_TOTAL
};

enum {
    EPNUM_CDC_NOTIF = 0x81,
    EPNUM_CDC_OUT   = 0x02,
    EPNUM_CDC_IN    = 0x82,
    EPNUM_HID_IN    = 0x83,
};

// 1 configuration, 3 interfaces (CDC control + CDC data + HID).
// The HID interface uses multiple report IDs (gamepad + mouse) in one report descriptor.
static const uint8_t hid_configuration_descriptor[] = {
    TUD_CONFIG_DESCRIPTOR(1, ITF_NUM_TOTAL, 0, TUSB_DESC_TOTAL_LEN, TUSB_DESC_CONFIG_ATT_REMOTE_WAKEUP, 100),
    TUD_CDC_DESCRIPTOR(ITF_NUM_CDC, 5, EPNUM_CDC_NOTIF, 8, EPNUM_CDC_OUT, EPNUM_CDC_IN, 64),
    TUD_HID_DESCRIPTOR(ITF_NUM_HID, 4, false, sizeof(hid_report_descriptor), EPNUM_HID_IN, 16, 1),
};

// TinyUSB callbacks (minimal).
uint8_t const *tud_hid_descriptor_report_cb(uint8_t instance) {
    (void)instance;
    return hid_report_descriptor;
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

    // Bring up CDC ACM so we can see logs and debug BLE behavior.
    tinyusb_config_cdcacm_t acm_cfg = {0}; // defaults
    err = tusb_cdc_acm_init(&acm_cfg);
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "tusb_cdc_acm_init failed err=0x%x", (unsigned int)err);
        return;
    }
    // Redirect ESP_LOG / stdout / stderr to CDC.
    (void)esp_tusb_init_console(TINYUSB_CDC_ACM_0);
}

void usb_hid_gamepad_send(const usb_gamepad_report_t *report) {
    if (!tud_hid_ready() || !report) {
        return;
    }
    uint8_t buf[8];
    buf[0] = (uint8_t)(report->buttons & 0xFF);
    buf[1] = (uint8_t)((report->buttons >> 8) & 0xFF);
    buf[2] = (uint8_t)((report->buttons >> 16) & 0xFF);
    buf[3] = (uint8_t)(report->hat & 0x0F);
    buf[4] = (uint8_t)report->lx;
    buf[5] = (uint8_t)report->ly;
    buf[6] = (uint8_t)report->rx;
    buf[7] = (uint8_t)report->ry;
    tud_hid_report(REPORT_ID_GAMEPAD, buf, sizeof(buf));
}

void usb_hid_mouse_send(const usb_mouse_report_t *report) {
    if (!tud_hid_ready() || !report) {
        return;
    }
    uint8_t buf[4];
    buf[0] = report->buttons;
    buf[1] = (uint8_t)report->x;
    buf[2] = (uint8_t)report->y;
    buf[3] = (uint8_t)report->wheel;
    tud_hid_report(REPORT_ID_MOUSE, buf, sizeof(buf));
}
