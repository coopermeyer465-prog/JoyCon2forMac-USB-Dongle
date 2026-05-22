#include "joycon2_ble.h"

#include <string.h>

#include "esp_log.h"
#include "nvs_flash.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"

#include "nimble/nimble_port.h"
#include "nimble/nimble_port_freertos.h"
#include "host/ble_hs.h"
#include "host/ble_gap.h"
#include "host/ble_gatt.h"
#include "host/util/util.h"
#include "os/os_mbuf.h"
#include "services/gap/ble_svc_gap.h"
#include "services/gatt/ble_svc_gatt.h"
#include "esp_nimble_hci.h"

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
static joycon2_status_cb_t s_status_cb = NULL;
static uint16_t s_conn_handle = BLE_HS_CONN_HANDLE_NONE;
static uint16_t s_write_handle = 0;
static uint16_t s_notify_handle = 0;
static uint16_t s_ack_handle = 0;
static uint16_t s_first_notify_before_cmd = 0;
static uint16_t s_first_notify_after_cmd = 0;
static uint16_t s_notify_cccd_handle = 0;
static bool s_subscribed = false;
static bool s_direct_cccd_attempted = false;
static bool s_init_task_running = false;
static uint8_t s_own_addr_type = BLE_OWN_ADDR_PUBLIC;

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

static void emit_status(joycon2_ble_status_t status) {
    if (s_status_cb) {
        s_status_cb(status);
    }
}

static void parse_stick_3b(const uint8_t *p, uint16_t *x, uint16_t *y) {
    uint32_t v = (uint32_t)p[0] | ((uint32_t)p[1] << 8) | ((uint32_t)p[2] << 16);
    *x = (uint16_t)(v & 0x0FFF);
    *y = (uint16_t)((v >> 12) & 0x0FFF);
}

static bool parse_packet(const uint8_t *data, size_t len, joycon2_state_t *out) {
    // Buttons and sticks are near the start of the report. Accept shorter
    // notifications, but default missing sticks to center so USB reports do not
    // look like a hard top-left stick deflection.
    if (!data || !out || len < 7) {
        return false;
    }

    memset(out, 0, sizeof(*out));
    out->left_x = 2047;
    out->left_y = 2047;
    out->right_x = 2047;
    out->right_y = 2047;
    out->buttons = read_le_u32(&data[3]);
    if (len > 0x3C) {
        out->trigger_l = data[0x3C];
    }
    if (len > 0x3D) {
        out->trigger_r = data[0x3D];
    }

    // Stick parse matches macOS version: 12-bit packed pairs in 3 bytes.
    if (len >= 0x0D) {
        parse_stick_3b(&data[0x0A], &out->left_x, &out->left_y);
    }
    if (len >= 0x10) {
        parse_stick_3b(&data[0x0D], &out->right_x, &out->right_y);
    }

    if (len >= 0x12) {
        out->mouse_x = read_le_i16(&data[0x10]);
    }
    if (len >= 0x14) {
        out->mouse_y = read_le_i16(&data[0x12]);
    }
    return true;
}

static const ble_uuid128_t kWriteUUID =
    BLE_UUID128_INIT(0x05, 0xF0, 0xE5, 0x4F, 0xA5, 0x1E, 0x44, 0xAF,
                     0x6C, 0x4E, 0xB7, 0x8E, 0xC9, 0x4A, 0x9D, 0x64);

static const ble_uuid128_t kNotifyUUID =
    BLE_UUID128_INIT(0xF8, 0xC0, 0xFC, 0x5F, 0x75, 0x32, 0x58, 0x82,
                     0x19, 0x46, 0x3E, 0xEC, 0x6C, 0x86, 0x92, 0x74);

static const ble_uuid128_t kNotifyUUIDAlt =
    BLE_UUID128_INIT(0xF9, 0xC0, 0xFC, 0x5F, 0x75, 0x32, 0x58, 0x82,
                     0x19, 0x46, 0x3E, 0xEC, 0x6C, 0x86, 0x92, 0x74);

static const ble_uuid128_t kNotifyUUIDMac =
    BLE_UUID128_INIT(0xD2, 0x7F, 0xDF, 0x09, 0x8F, 0x11, 0x2F, 0x81,
                     0x28, 0xAD, 0xFE, 0x49, 0xBE, 0xE9, 0x7D, 0xAB);

static void joycon2_scan_start(void);
static int joycon2_gap_event(struct ble_gap_event *event, void *arg);
static int joycon2_mtu_cb(uint16_t conn_handle, const struct ble_gatt_error *error,
                          uint16_t mtu, void *arg);
static int joycon2_chr_disc_cb(uint16_t conn_handle, const struct ble_gatt_error *error,
                               const struct ble_gatt_chr *chr, void *arg);
static int joycon2_dsc_disc_cb(uint16_t conn_handle, const struct ble_gatt_error *error,
                               uint16_t chr_val_handle, const struct ble_gatt_dsc *dsc, void *arg);
static int joycon2_cccd_write_cb(uint16_t conn_handle, const struct ble_gatt_error *error,
                                 struct ble_gatt_attr *attr, void *arg);
static void joycon2_write_cccd(uint16_t cccd_handle);

static bool adv_is_joycon2(const struct ble_gap_disc_desc *desc) {
    struct ble_hs_adv_fields fields;
    int rc = ble_hs_adv_parse_fields(&fields, desc->data, desc->length_data);
    if (rc != 0) {
        return false;
    }
    if (fields.mfg_data && fields.mfg_data_len >= 2) {
        uint16_t company_id = (uint16_t)fields.mfg_data[0] | ((uint16_t)fields.mfg_data[1] << 8);
        // Empirically Joy-Con 2 uses 0x0553 in this project, but keep Nintendo's SIG ID too
        // to reduce false negatives between models / firmware revisions.
        if (company_id == 0x0553 || company_id == 0x057e) {
            return true;
        }
    }

    // Fallback: match on advertised name when manufacturer data isn't present
    // (some devices only include mfg data in scan response, or omit it entirely).
    if (fields.name && fields.name_len > 0) {
        char name[40];
        size_t n = fields.name_len < sizeof(name) - 1 ? fields.name_len : sizeof(name) - 1;
        memcpy(name, fields.name, n);
        name[n] = '\0';

        // Case-insensitive substring match for "joy" + "con".
        for (char *p = name; *p; p++) {
            if (*p >= 'A' && *p <= 'Z') *p = (char)(*p - 'A' + 'a');
        }
        if (strstr(name, "joy") && strstr(name, "con")) {
            return true;
        }
    }

    return false;
}

static void joycon2_send_init_commands_now(void) {
    if (s_conn_handle == BLE_HS_CONN_HANDLE_NONE || s_write_handle == 0) {
        ESP_LOGW(TAG, "Cannot send init commands yet (conn=%u write_handle=%u)", s_conn_handle, s_write_handle);
        return;
    }

    static const uint8_t cmd_features_set[] = {0x0c, 0x91, 0x01, 0x02, 0x00, 0x04, 0x00, 0x00, 0xff, 0x00, 0x00, 0x00};
    static const uint8_t cmd_features_enable[] = {0x0c, 0x91, 0x01, 0x04, 0x00, 0x04, 0x00, 0x00, 0xff, 0x00, 0x00, 0x00};

    struct init_cmd {
        const uint8_t *data;
        size_t len;
    };
    static const struct init_cmd cmds[] = {
        {cmd_features_set, sizeof(cmd_features_set)},
        {cmd_features_enable, sizeof(cmd_features_enable)},
    };

    for (size_t i = 0; i < sizeof(cmds) / sizeof(cmds[0]); i++) {
        ESP_LOGI(TAG, "Sending init command %u/%u", (unsigned)(i + 1), (unsigned)(sizeof(cmds) / sizeof(cmds[0])));
        int rc = ble_gattc_write_no_rsp_flat(s_conn_handle, s_write_handle, cmds[i].data, cmds[i].len);
        if (rc != 0) {
            ESP_LOGW(TAG, "write_no_rsp init command %u failed rc=%d", (unsigned)(i + 1), rc);
        }
        vTaskDelay(pdMS_TO_TICKS(500));
    }
}

static void joycon2_init_task(void *param) {
    (void)param;

    vTaskDelay(pdMS_TO_TICKS(500));
    joycon2_send_init_commands_now();

    // Match the macOS app's "enable notifications again after a short delay"
    // behavior. This helps if the Joy-Con only starts streaming after init.
    vTaskDelay(pdMS_TO_TICKS(1500));
    if (s_conn_handle != BLE_HS_CONN_HANDLE_NONE && s_notify_handle != 0) {
        s_direct_cccd_attempted = true;
        joycon2_write_cccd(s_notify_handle + 1);
    }

    s_init_task_running = false;
    vTaskDelete(NULL);
}

static void joycon2_schedule_init_commands(void) {
    if (s_init_task_running) {
        return;
    }
    s_init_task_running = true;
    if (xTaskCreate(joycon2_init_task, "joycon_init", 4096, NULL, 5, NULL) != pdPASS) {
        s_init_task_running = false;
        ESP_LOGW(TAG, "failed to create init task");
    }
}

static void joycon2_start_descriptor_fallback(void) {
    s_notify_cccd_handle = 0;
    ESP_LOGI(TAG, "Discovering descriptors (looking for CCCD) after notify handle=%u", s_notify_handle);
    int rc = ble_gattc_disc_all_dscs(s_conn_handle, s_notify_handle + 1, 0xffff, joycon2_dsc_disc_cb, NULL);
    if (rc != 0) {
        ESP_LOGW(TAG, "disc_all_dscs failed rc=%d", rc);
    }
}

static void joycon2_write_cccd(uint16_t cccd_handle) {
    uint8_t cccd_val[2] = {0x01, 0x00}; // notifications enabled
    s_notify_cccd_handle = cccd_handle;
    ESP_LOGI(TAG, "Writing CCCD handle=%u to enable notifications", s_notify_cccd_handle);
    int rc = ble_gattc_write_flat(s_conn_handle, s_notify_cccd_handle, cccd_val, sizeof(cccd_val),
                                  joycon2_cccd_write_cb, NULL);
    if (rc != 0) {
        ESP_LOGW(TAG, "CCCD write failed rc=%d", rc);
        if (s_direct_cccd_attempted) {
            s_direct_cccd_attempted = false;
            joycon2_start_descriptor_fallback();
        }
    }
}

static void joycon2_try_finish_setup(void) {
    if (s_conn_handle == BLE_HS_CONN_HANDLE_NONE) {
        return;
    }
    if (s_notify_handle == 0) {
        s_notify_handle = s_first_notify_before_cmd ? s_first_notify_before_cmd : s_first_notify_after_cmd;
        if (s_notify_handle != 0) {
            ESP_LOGI(TAG, "Using discovered input notify fallback handle=%u", s_notify_handle);
        }
    }
    if (s_write_handle == 0 || s_notify_handle == 0) {
        return;
    }
    if (s_subscribed) {
        return;
    }

    s_direct_cccd_attempted = true;
    joycon2_write_cccd(s_notify_handle + 1);
}

static void joycon2_start_characteristic_discovery(void) {
    if (s_conn_handle == BLE_HS_CONN_HANDLE_NONE) {
        return;
    }
    ESP_LOGI(TAG, "Discovering characteristics...");
    int rc = ble_gattc_disc_all_chrs(s_conn_handle, 1, 0xffff, joycon2_chr_disc_cb, NULL);
    if (rc != 0) {
        ESP_LOGW(TAG, "disc_all_chrs failed rc=%d", rc);
    }
}

static int joycon2_mtu_cb(uint16_t conn_handle, const struct ble_gatt_error *error,
                          uint16_t mtu, void *arg) {
    (void)conn_handle;
    (void)arg;
    if (error->status == 0) {
        ESP_LOGI(TAG, "MTU exchange complete mtu=%u", mtu);
    } else {
        ESP_LOGW(TAG, "MTU exchange status=%d; continuing", error->status);
    }
    joycon2_start_characteristic_discovery();
    return 0;
}

static int joycon2_gap_event(struct ble_gap_event *event, void *arg) {
    (void)arg;
    switch (event->type) {
        case BLE_GAP_EVENT_DISC: {
            const struct ble_gap_disc_desc *desc = &event->disc;
            if (!adv_is_joycon2(desc)) {
                return 0;
            }
            emit_status(JOYCON2_BLE_STATUS_FOUND);
            ESP_LOGI(TAG, "Found Joy-Con 2; connecting...");
            ble_gap_disc_cancel();
            int rc = ble_gap_connect(s_own_addr_type, &desc->addr, 30000, NULL, joycon2_gap_event, NULL);
            if (rc != 0) {
                ESP_LOGW(TAG, "connect failed rc=%d; restarting scan", rc);
                joycon2_scan_start();
            }
            return 0;
        }
        case BLE_GAP_EVENT_CONNECT: {
            if (event->connect.status != 0) {
                ESP_LOGW(TAG, "Connect failed status=%d; restarting scan", event->connect.status);
                joycon2_scan_start();
                return 0;
            }
            s_conn_handle = event->connect.conn_handle;
            s_write_handle = 0;
            s_notify_handle = 0;
            s_ack_handle = 0;
            s_first_notify_before_cmd = 0;
            s_first_notify_after_cmd = 0;
            s_notify_cccd_handle = 0;
            s_subscribed = false;
            s_direct_cccd_attempted = false;
            s_init_task_running = false;
            emit_status(JOYCON2_BLE_STATUS_CONNECTED);
            ESP_LOGI(TAG, "Connected; exchanging MTU...");
            int rc = ble_gattc_exchange_mtu(s_conn_handle, joycon2_mtu_cb, NULL);
            if (rc != 0) {
                ESP_LOGW(TAG, "exchange_mtu failed rc=%d; continuing without it", rc);
                joycon2_start_characteristic_discovery();
            }
            return 0;
        }
        case BLE_GAP_EVENT_DISCONNECT: {
            ESP_LOGW(TAG, "Disconnected reason=%d; restarting scan", event->disconnect.reason);
            s_conn_handle = BLE_HS_CONN_HANDLE_NONE;
            s_write_handle = 0;
            s_notify_handle = 0;
            s_ack_handle = 0;
            s_first_notify_before_cmd = 0;
            s_first_notify_after_cmd = 0;
            s_notify_cccd_handle = 0;
            s_subscribed = false;
            s_direct_cccd_attempted = false;
            s_init_task_running = false;
            emit_status(JOYCON2_BLE_STATUS_DISCONNECTED);
            joycon2_scan_start();
            return 0;
        }
        case BLE_GAP_EVENT_NOTIFY_RX: {
            bool expected_handle = event->notify_rx.attr_handle == s_notify_handle ||
                                   event->notify_rx.attr_handle == s_ack_handle;
            if (!expected_handle) {
                emit_status(JOYCON2_BLE_STATUS_NOTIFY_OTHER);
            }

            if (event->notify_rx.attr_handle != s_notify_handle) {
                ESP_LOGD(TAG, "Notification on non-primary handle=%u primary=%u",
                         event->notify_rx.attr_handle, s_notify_handle);
                return 0;
            }
            uint16_t len = OS_MBUF_PKTLEN(event->notify_rx.om);
            uint8_t packet[96];
            if (len > sizeof(packet)) {
                len = sizeof(packet);
            }
            int rc = os_mbuf_copydata(event->notify_rx.om, 0, len, packet);
            if (rc != 0) {
                return 0;
            }

            joycon2_state_t st;
            if (parse_packet(packet, len, &st) && s_cb) {
                emit_status(JOYCON2_BLE_STATUS_NOTIFYING);
                s_cb(&st);
            } else {
                emit_status(JOYCON2_BLE_STATUS_PACKET_REJECTED);
            }
            return 0;
        }
        default:
            return 0;
    }
}

static int joycon2_chr_disc_cb(uint16_t conn_handle, const struct ble_gatt_error *error,
                               const struct ble_gatt_chr *chr, void *arg) {
    (void)conn_handle;
    (void)arg;
    if (error->status == BLE_HS_EDONE) {
        ESP_LOGI(TAG, "Characteristic discovery complete. write=%u notify=%u", s_write_handle, s_notify_handle);
        joycon2_try_finish_setup();
        return 0;
    }
    if (error->status != 0) {
        ESP_LOGW(TAG, "Characteristic discovery error status=%d", error->status);
        return 0;
    }
    if (!chr) {
        return 0;
    }

    if (ble_uuid_cmp(&chr->uuid.u, &kWriteUUID.u) == 0) {
        s_write_handle = chr->val_handle;
        ESP_LOGI(TAG, "Found write characteristic handle=%u", s_write_handle);
    } else if (ble_uuid_cmp(&chr->uuid.u, &kNotifyUUIDMac.u) == 0) {
        s_notify_handle = chr->val_handle;
        ESP_LOGI(TAG, "Found macOS notify characteristic handle=%u", s_notify_handle);
    } else if (s_notify_handle == 0 &&
               (ble_uuid_cmp(&chr->uuid.u, &kNotifyUUID.u) == 0 ||
                ble_uuid_cmp(&chr->uuid.u, &kNotifyUUIDAlt.u) == 0)) {
        s_notify_handle = chr->val_handle;
        ESP_LOGI(TAG, "Found notify characteristic handle=%u", s_notify_handle);
    } else {
        if (s_write_handle == 0 &&
            (chr->properties & (BLE_GATT_CHR_F_WRITE_NO_RSP | BLE_GATT_CHR_F_WRITE))) {
            s_write_handle = chr->val_handle;
            ESP_LOGI(TAG, "Using fallback write characteristic handle=%u", s_write_handle);
        }
        if (s_write_handle != 0 && s_ack_handle == 0 &&
            chr->val_handle > s_write_handle &&
            (chr->properties & BLE_GATT_CHR_F_NOTIFY)) {
            s_ack_handle = chr->val_handle;
            ESP_LOGI(TAG, "Using fallback ACK characteristic handle=%u", s_ack_handle);
        }
    }
    if (chr->properties & BLE_GATT_CHR_F_NOTIFY) {
        if (s_write_handle == 0 && s_first_notify_before_cmd == 0) {
            s_first_notify_before_cmd = chr->val_handle;
            ESP_LOGI(TAG, "Remembering pre-command notify fallback handle=%u", s_first_notify_before_cmd);
        } else if (s_write_handle != 0 && s_first_notify_after_cmd == 0) {
            s_first_notify_after_cmd = chr->val_handle;
            ESP_LOGI(TAG, "Remembering post-command notify fallback handle=%u", s_first_notify_after_cmd);
        }
    }
    return 0;
}

static int joycon2_dsc_disc_cb(uint16_t conn_handle, const struct ble_gatt_error *error,
                               uint16_t chr_val_handle, const struct ble_gatt_dsc *dsc, void *arg) {
    (void)conn_handle;
    (void)chr_val_handle;
    (void)arg;

    if (error->status == BLE_HS_EDONE) {
        if (s_notify_cccd_handle == 0) {
            ESP_LOGW(TAG, "Descriptor discovery complete but CCCD not found; cannot enable notifications");
            return 0;
        }

        s_direct_cccd_attempted = false;
        joycon2_write_cccd(s_notify_cccd_handle);
        return 0;
    }

    if (error->status != 0) {
        ESP_LOGW(TAG, "Descriptor discovery error status=%d", error->status);
        return 0;
    }
    if (!dsc) {
        return 0;
    }

    // CCCD UUID is 0x2902.
    if (s_notify_cccd_handle == 0 && ble_uuid_u16(&dsc->uuid.u) == 0x2902) {
        s_notify_cccd_handle = dsc->handle;
        ESP_LOGI(TAG, "Found CCCD descriptor handle=%u", s_notify_cccd_handle);
    }

    return 0;
}

static int joycon2_cccd_write_cb(uint16_t conn_handle, const struct ble_gatt_error *error,
                                 struct ble_gatt_attr *attr, void *arg) {
    (void)conn_handle;
    (void)attr;
    (void)arg;

    if (error->status != 0) {
        ESP_LOGW(TAG, "CCCD write cb status=%d", error->status);
        if (s_direct_cccd_attempted) {
            s_direct_cccd_attempted = false;
            joycon2_start_descriptor_fallback();
        }
        return 0;
    }

    ESP_LOGI(TAG, "Notifications enabled");
    s_subscribed = true;
    s_direct_cccd_attempted = false;
    emit_status(JOYCON2_BLE_STATUS_SUBSCRIBED);
    joycon2_schedule_init_commands();
    return 0;
}

static void joycon2_scan_start(void) {
    struct ble_gap_disc_params params;
    memset(&params, 0, sizeof(params));
    params.passive = 0;
    params.itvl = 0x0010;
    params.window = 0x0010;
    // Don't filter duplicates. Some devices (including Joy-Cons) may only expose
    // manufacturer data in the scan response, which we'd otherwise discard.
    params.filter_duplicates = 0;

    int rc = ble_gap_disc(s_own_addr_type, BLE_HS_FOREVER, &params, joycon2_gap_event, NULL);
    if (rc != 0) {
        ESP_LOGW(TAG, "ble_gap_disc failed rc=%d", rc);
    } else {
        emit_status(JOYCON2_BLE_STATUS_SCANNING);
        ESP_LOGI(TAG, "Scanning for Joy-Con 2...");
    }
}

static void joycon2_on_reset(int reason) {
    ESP_LOGE(TAG, "NimBLE reset reason=%d", reason);
}

static void joycon2_on_sync(void) {
    int rc = ble_hs_id_infer_auto(0, &s_own_addr_type);
    if (rc != 0) {
        ESP_LOGW(TAG, "ble_hs_id_infer_auto rc=%d", rc);
    }
    ESP_LOGI(TAG, "BLE sync complete; own_addr_type=%u", s_own_addr_type);
    joycon2_scan_start();
}

static void joycon2_host_task(void *param) {
    (void)param;
    nimble_port_run();
    nimble_port_freertos_deinit();
}

void joycon2_ble_start(joycon2_state_cb_t cb) {
    s_cb = cb;

    esp_err_t err = nvs_flash_init();
    if (err == ESP_ERR_NVS_NO_FREE_PAGES || err == ESP_ERR_NVS_NEW_VERSION_FOUND) {
        ESP_ERROR_CHECK(nvs_flash_erase());
        ESP_ERROR_CHECK(nvs_flash_init());
    }

    ESP_ERROR_CHECK(nimble_port_init());

    ble_svc_gap_init();
    ble_svc_gatt_init();

    ble_svc_gap_device_name_set("JoyCon2 Dongle");

    ble_hs_cfg.reset_cb = joycon2_on_reset;
    ble_hs_cfg.sync_cb = joycon2_on_sync;

    nimble_port_freertos_init(joycon2_host_task);
}

void joycon2_ble_set_status_callback(joycon2_status_cb_t cb) {
    s_status_cb = cb;
}
