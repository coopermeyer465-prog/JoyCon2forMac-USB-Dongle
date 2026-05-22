#include "joycon2_ble.h"

#include <stdio.h>
#include <string.h>

#include "esp_log.h"
#include "esp_nimble_hci.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "host/ble_gap.h"
#include "host/ble_gatt.h"
#include "host/ble_hs.h"
#include "host/util/util.h"
#include "nimble/nimble_port.h"
#include "nimble/nimble_port_freertos.h"
#include "nvs_flash.h"
#include "os/os_mbuf.h"
#include "services/gap/ble_svc_gap.h"
#include "services/gatt/ble_svc_gatt.h"

static const char *TAG = "joycon2_ble";

typedef enum {
    JOYCON_SIDE_UNKNOWN = 0,
    JOYCON_SIDE_LEFT,
    JOYCON_SIDE_RIGHT,
} joycon_side_t;

typedef struct {
    bool allocated;
    bool connecting;
    bool subscribed;
    bool notifying;
    bool direct_cccd_attempted;
    bool init_task_running;
    uint16_t conn_handle;
    uint16_t write_handle;
    uint16_t notify_handle;
    uint16_t ack_handle;
    uint16_t first_notify_before_cmd;
    uint16_t first_notify_after_cmd;
    uint16_t notify_cccd_handle;
    ble_addr_t addr;
    joycon_side_t side;
    char name[40];
} joycon_conn_t;

static joycon2_state_cb_t s_cb = NULL;
static joycon2_status_cb_t s_status_cb = NULL;
static uint8_t s_own_addr_type = BLE_OWN_ADDR_PUBLIC;
static joycon_conn_t s_conns[2];
static bool s_connecting = false;
static bool s_scanning = false;

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

static bool addr_equal(const ble_addr_t *a, const ble_addr_t *b) {
    return a->type == b->type && memcmp(a->val, b->val, sizeof(a->val)) == 0;
}

static bool any_input_flowing(void) {
    for (size_t i = 0; i < sizeof(s_conns) / sizeof(s_conns[0]); i++) {
        if (s_conns[i].allocated && s_conns[i].notifying) {
            return true;
        }
    }
    return false;
}

static void emit_status(joycon2_ble_status_t status) {
    if (!s_status_cb) {
        return;
    }
    if (status != JOYCON2_BLE_STATUS_DISCONNECTED && any_input_flowing()) {
        status = JOYCON2_BLE_STATUS_NOTIFYING;
    }
    s_status_cb(status);
}

static joycon_conn_t *ctx_for_handle(uint16_t conn_handle) {
    for (size_t i = 0; i < sizeof(s_conns) / sizeof(s_conns[0]); i++) {
        if (s_conns[i].allocated && s_conns[i].conn_handle == conn_handle) {
            return &s_conns[i];
        }
    }
    return NULL;
}

static joycon_conn_t *ctx_for_addr(const ble_addr_t *addr) {
    for (size_t i = 0; i < sizeof(s_conns) / sizeof(s_conns[0]); i++) {
        if (s_conns[i].allocated && addr_equal(&s_conns[i].addr, addr)) {
            return &s_conns[i];
        }
    }
    return NULL;
}

static joycon_conn_t *alloc_ctx(void) {
    for (size_t i = 0; i < sizeof(s_conns) / sizeof(s_conns[0]); i++) {
        if (!s_conns[i].allocated) {
            memset(&s_conns[i], 0, sizeof(s_conns[i]));
            s_conns[i].allocated = true;
            s_conns[i].conn_handle = BLE_HS_CONN_HANDLE_NONE;
            return &s_conns[i];
        }
    }
    return NULL;
}

static bool free_slot_exists(void) {
    for (size_t i = 0; i < sizeof(s_conns) / sizeof(s_conns[0]); i++) {
        if (!s_conns[i].allocated) {
            return true;
        }
    }
    return false;
}

static void release_ctx(joycon_conn_t *ctx) {
    if (ctx) {
        memset(ctx, 0, sizeof(*ctx));
        ctx->conn_handle = BLE_HS_CONN_HANDLE_NONE;
    }
}

static void parse_stick_3b(const uint8_t *p, uint16_t *x, uint16_t *y) {
    uint32_t v = (uint32_t)p[0] | ((uint32_t)p[1] << 8) | ((uint32_t)p[2] << 16);
    *x = (uint16_t)(v & 0x0FFF);
    *y = (uint16_t)((v >> 12) & 0x0FFF);
}

static void infer_side_from_buttons(joycon2_state_t *st, joycon_side_t hint) {
    const uint32_t right_mask = 0x0000FF00u | 0x00040000u | 0x00020000u | 0x00100000u | 0x00400000u;
    const uint32_t left_mask = 0xFF000000u | 0x00080000u | 0x00010000u | 0x00200000u;
    if (hint == JOYCON_SIDE_RIGHT || (st->buttons & right_mask)) {
        st->is_right = true;
    }
    if (hint == JOYCON_SIDE_LEFT || (st->buttons & left_mask)) {
        st->is_left = true;
    }
}

static bool parse_packet(const uint8_t *data, size_t len, joycon_side_t side, joycon2_state_t *out) {
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
    if (len >= 0x16) {
        out->mouse_unk = read_le_i16(&data[0x14]);
    }
    if (len >= 0x18) {
        out->mouse_distance = read_le_i16(&data[0x16]);
    }
    infer_side_from_buttons(out, side);
    return true;
}

static joycon_side_t side_from_name(const char *name) {
    if (!name) {
        return JOYCON_SIDE_UNKNOWN;
    }
    if (strstr(name, "(L)") || strstr(name, "Left") || strstr(name, "left")) {
        return JOYCON_SIDE_LEFT;
    }
    if (strstr(name, "(R)") || strstr(name, "Right") || strstr(name, "right")) {
        return JOYCON_SIDE_RIGHT;
    }
    return JOYCON_SIDE_UNKNOWN;
}

static bool adv_is_joycon2(const struct ble_gap_disc_desc *desc, char *name, size_t name_len, joycon_side_t *side) {
    struct ble_hs_adv_fields fields;
    int rc = ble_hs_adv_parse_fields(&fields, desc->data, desc->length_data);
    if (rc != 0) {
        return false;
    }

    if (name && name_len > 0) {
        name[0] = '\0';
        if (fields.name && fields.name_len > 0) {
            size_t n = fields.name_len < name_len - 1 ? fields.name_len : name_len - 1;
            memcpy(name, fields.name, n);
            name[n] = '\0';
        }
    }
    if (side) {
        *side = side_from_name(name);
    }

    bool matches = false;
    if (fields.mfg_data && fields.mfg_data_len >= 2) {
        uint16_t company_id = (uint16_t)fields.mfg_data[0] | ((uint16_t)fields.mfg_data[1] << 8);
        matches = company_id == 0x0553 || company_id == 0x057e;
    }
    if (!matches && fields.name && fields.name_len > 0) {
        char lower[40];
        size_t n = fields.name_len < sizeof(lower) - 1 ? fields.name_len : sizeof(lower) - 1;
        memcpy(lower, fields.name, n);
        lower[n] = '\0';
        for (char *p = lower; *p; p++) {
            if (*p >= 'A' && *p <= 'Z') *p = (char)(*p - 'A' + 'a');
        }
        matches = strstr(lower, "joy") && strstr(lower, "con");
    }
    return matches;
}

static void joycon2_scan_start(void);
static int joycon2_gap_event(struct ble_gap_event *event, void *arg);
static int joycon2_mtu_cb(uint16_t conn_handle, const struct ble_gatt_error *error, uint16_t mtu, void *arg);
static int joycon2_chr_disc_cb(uint16_t conn_handle, const struct ble_gatt_error *error, const struct ble_gatt_chr *chr, void *arg);
static int joycon2_dsc_disc_cb(uint16_t conn_handle, const struct ble_gatt_error *error, uint16_t chr_val_handle, const struct ble_gatt_dsc *dsc, void *arg);
static int joycon2_cccd_write_cb(uint16_t conn_handle, const struct ble_gatt_error *error, struct ble_gatt_attr *attr, void *arg);

static void joycon2_write_cccd(joycon_conn_t *ctx, uint16_t cccd_handle) {
    uint8_t cccd_val[2] = {0x01, 0x00};
    ctx->notify_cccd_handle = cccd_handle;
    ESP_LOGI(TAG, "[%s] Writing CCCD handle=%u", ctx->name, ctx->notify_cccd_handle);
    int rc = ble_gattc_write_flat(ctx->conn_handle, ctx->notify_cccd_handle, cccd_val, sizeof(cccd_val),
                                  joycon2_cccd_write_cb, ctx);
    if (rc != 0) {
        ESP_LOGW(TAG, "[%s] CCCD write failed rc=%d", ctx->name, rc);
        if (ctx->direct_cccd_attempted) {
            ctx->direct_cccd_attempted = false;
            ctx->notify_cccd_handle = 0;
            (void)ble_gattc_disc_all_dscs(ctx->conn_handle, ctx->notify_handle + 1, 0xffff, joycon2_dsc_disc_cb, ctx);
        }
    }
}

static void joycon2_send_init_commands_now(joycon_conn_t *ctx) {
    if (!ctx || ctx->conn_handle == BLE_HS_CONN_HANDLE_NONE || ctx->write_handle == 0) {
        return;
    }

    static const uint8_t cmd_features_set[] = {0x0c, 0x91, 0x01, 0x02, 0x00, 0x04, 0x00, 0x00, 0xff, 0x00, 0x00, 0x00};
    static const uint8_t cmd_features_enable[] = {0x0c, 0x91, 0x01, 0x04, 0x00, 0x04, 0x00, 0x00, 0xff, 0x00, 0x00, 0x00};
    static const struct {
        const uint8_t *data;
        size_t len;
    } cmds[] = {
        {cmd_features_set, sizeof(cmd_features_set)},
        {cmd_features_enable, sizeof(cmd_features_enable)},
    };

    for (size_t i = 0; i < sizeof(cmds) / sizeof(cmds[0]); i++) {
        int rc = ble_gattc_write_no_rsp_flat(ctx->conn_handle, ctx->write_handle, cmds[i].data, cmds[i].len);
        if (rc != 0) {
            ESP_LOGW(TAG, "[%s] init command %u failed rc=%d", ctx->name, (unsigned)(i + 1), rc);
        }
        vTaskDelay(pdMS_TO_TICKS(500));
    }
}

static void joycon2_init_task(void *param) {
    joycon_conn_t *ctx = (joycon_conn_t *)param;
    vTaskDelay(pdMS_TO_TICKS(500));
    joycon2_send_init_commands_now(ctx);
    vTaskDelay(pdMS_TO_TICKS(1500));
    if (ctx && ctx->conn_handle != BLE_HS_CONN_HANDLE_NONE && ctx->notify_handle != 0) {
        ctx->direct_cccd_attempted = true;
        joycon2_write_cccd(ctx, ctx->notify_handle + 1);
    }
    if (ctx) {
        ctx->init_task_running = false;
    }
    vTaskDelete(NULL);
}

static void joycon2_schedule_init_commands(joycon_conn_t *ctx) {
    if (!ctx || ctx->init_task_running) {
        return;
    }
    ctx->init_task_running = true;
    if (xTaskCreate(joycon2_init_task, "joycon_init", 4096, ctx, 5, NULL) != pdPASS) {
        ctx->init_task_running = false;
    }
}

static void joycon2_try_finish_setup(joycon_conn_t *ctx) {
    if (!ctx || ctx->conn_handle == BLE_HS_CONN_HANDLE_NONE || ctx->subscribed) {
        return;
    }
    if (ctx->notify_handle == 0) {
        ctx->notify_handle = ctx->first_notify_before_cmd ? ctx->first_notify_before_cmd : ctx->first_notify_after_cmd;
    }
    if (ctx->write_handle == 0 || ctx->notify_handle == 0) {
        return;
    }
    ctx->direct_cccd_attempted = true;
    joycon2_write_cccd(ctx, ctx->notify_handle + 1);
}

static void joycon2_start_characteristic_discovery(joycon_conn_t *ctx) {
    if (!ctx || ctx->conn_handle == BLE_HS_CONN_HANDLE_NONE) {
        return;
    }
    int rc = ble_gattc_disc_all_chrs(ctx->conn_handle, 1, 0xffff, joycon2_chr_disc_cb, ctx);
    if (rc != 0) {
        ESP_LOGW(TAG, "[%s] disc_all_chrs failed rc=%d", ctx->name, rc);
    }
}

static int joycon2_mtu_cb(uint16_t conn_handle, const struct ble_gatt_error *error, uint16_t mtu, void *arg) {
    joycon_conn_t *ctx = (joycon_conn_t *)arg;
    (void)conn_handle;
    if (error->status == 0) {
        ESP_LOGI(TAG, "[%s] MTU exchange complete mtu=%u", ctx ? ctx->name : "?", mtu);
    }
    joycon2_start_characteristic_discovery(ctx);
    return 0;
}

static int joycon2_chr_disc_cb(uint16_t conn_handle, const struct ble_gatt_error *error, const struct ble_gatt_chr *chr, void *arg) {
    joycon_conn_t *ctx = (joycon_conn_t *)arg;
    (void)conn_handle;
    if (!ctx) {
        return 0;
    }
    if (error->status == BLE_HS_EDONE) {
        joycon2_try_finish_setup(ctx);
        return 0;
    }
    if (error->status != 0 || !chr) {
        return 0;
    }

    if (ble_uuid_cmp(&chr->uuid.u, &kWriteUUID.u) == 0) {
        ctx->write_handle = chr->val_handle;
    } else if (ble_uuid_cmp(&chr->uuid.u, &kNotifyUUIDMac.u) == 0) {
        ctx->notify_handle = chr->val_handle;
    } else if (ctx->notify_handle == 0 &&
               (ble_uuid_cmp(&chr->uuid.u, &kNotifyUUID.u) == 0 ||
                ble_uuid_cmp(&chr->uuid.u, &kNotifyUUIDAlt.u) == 0)) {
        ctx->notify_handle = chr->val_handle;
    } else {
        if (ctx->write_handle == 0 && (chr->properties & (BLE_GATT_CHR_F_WRITE_NO_RSP | BLE_GATT_CHR_F_WRITE))) {
            ctx->write_handle = chr->val_handle;
        }
        if (ctx->write_handle != 0 && ctx->ack_handle == 0 &&
            chr->val_handle > ctx->write_handle && (chr->properties & BLE_GATT_CHR_F_NOTIFY)) {
            ctx->ack_handle = chr->val_handle;
        }
    }
    if (chr->properties & BLE_GATT_CHR_F_NOTIFY) {
        if (ctx->write_handle == 0 && ctx->first_notify_before_cmd == 0) {
            ctx->first_notify_before_cmd = chr->val_handle;
        } else if (ctx->write_handle != 0 && ctx->first_notify_after_cmd == 0) {
            ctx->first_notify_after_cmd = chr->val_handle;
        }
    }
    return 0;
}

static int joycon2_dsc_disc_cb(uint16_t conn_handle, const struct ble_gatt_error *error, uint16_t chr_val_handle, const struct ble_gatt_dsc *dsc, void *arg) {
    joycon_conn_t *ctx = (joycon_conn_t *)arg;
    (void)conn_handle;
    (void)chr_val_handle;
    if (!ctx) {
        return 0;
    }
    if (error->status == BLE_HS_EDONE) {
        if (ctx->notify_cccd_handle != 0) {
            ctx->direct_cccd_attempted = false;
            joycon2_write_cccd(ctx, ctx->notify_cccd_handle);
        }
        return 0;
    }
    if (error->status == 0 && dsc && ctx->notify_cccd_handle == 0 && ble_uuid_u16(&dsc->uuid.u) == 0x2902) {
        ctx->notify_cccd_handle = dsc->handle;
    }
    return 0;
}

static int joycon2_cccd_write_cb(uint16_t conn_handle, const struct ble_gatt_error *error, struct ble_gatt_attr *attr, void *arg) {
    joycon_conn_t *ctx = (joycon_conn_t *)arg;
    (void)conn_handle;
    (void)attr;
    if (!ctx) {
        return 0;
    }
    if (error->status != 0) {
        if (ctx->direct_cccd_attempted) {
            ctx->direct_cccd_attempted = false;
            ctx->notify_cccd_handle = 0;
            (void)ble_gattc_disc_all_dscs(ctx->conn_handle, ctx->notify_handle + 1, 0xffff, joycon2_dsc_disc_cb, ctx);
        }
        return 0;
    }

    ctx->subscribed = true;
    ctx->direct_cccd_attempted = false;
    emit_status(JOYCON2_BLE_STATUS_SUBSCRIBED);
    joycon2_schedule_init_commands(ctx);
    joycon2_scan_start();
    return 0;
}

static int joycon2_gap_event(struct ble_gap_event *event, void *arg) {
    joycon_conn_t *ctx = (joycon_conn_t *)arg;
    switch (event->type) {
        case BLE_GAP_EVENT_DISC: {
            if (s_connecting) {
                return 0;
            }
            char name[40];
            joycon_side_t side = JOYCON_SIDE_UNKNOWN;
            if (!adv_is_joycon2(&event->disc, name, sizeof(name), &side)) {
                return 0;
            }
            if (ctx_for_addr(&event->disc.addr)) {
                return 0;
            }
            joycon_conn_t *new_ctx = alloc_ctx();
            if (!new_ctx) {
                return 0;
            }
            new_ctx->addr = event->disc.addr;
            new_ctx->side = side;
            snprintf(new_ctx->name, sizeof(new_ctx->name), "%s", name[0] ? name : "Joy-Con 2");
            new_ctx->connecting = true;
            s_connecting = true;
            s_scanning = false;
            emit_status(JOYCON2_BLE_STATUS_FOUND);
            ESP_LOGI(TAG, "Found %s; connecting...", new_ctx->name);
            ble_gap_disc_cancel();
            int rc = ble_gap_connect(s_own_addr_type, &new_ctx->addr, 30000, NULL, joycon2_gap_event, new_ctx);
            if (rc != 0) {
                ESP_LOGW(TAG, "connect failed rc=%d; restarting scan", rc);
                s_connecting = false;
                release_ctx(new_ctx);
                joycon2_scan_start();
            }
            return 0;
        }
        case BLE_GAP_EVENT_CONNECT: {
            s_connecting = false;
            if (!ctx) {
                return 0;
            }
            ctx->connecting = false;
            if (event->connect.status != 0) {
                ESP_LOGW(TAG, "[%s] Connect failed status=%d", ctx->name, event->connect.status);
                release_ctx(ctx);
                joycon2_scan_start();
                return 0;
            }
            ctx->conn_handle = event->connect.conn_handle;
            emit_status(JOYCON2_BLE_STATUS_CONNECTED);
            int rc = ble_gattc_exchange_mtu(ctx->conn_handle, joycon2_mtu_cb, ctx);
            if (rc != 0) {
                joycon2_start_characteristic_discovery(ctx);
            }
            // Resume scanning immediately so both Joy-Cons can be put into
            // pairing mode at the same time; setup continues per connection.
            joycon2_scan_start();
            return 0;
        }
        case BLE_GAP_EVENT_DISCONNECT: {
            joycon_conn_t *disc_ctx = ctx_for_handle(event->disconnect.conn.conn_handle);
            if (!disc_ctx) {
                disc_ctx = ctx;
            }
            ESP_LOGW(TAG, "[%s] Disconnected reason=%d", disc_ctx ? disc_ctx->name : "?", event->disconnect.reason);
            release_ctx(disc_ctx);
            emit_status(any_input_flowing() ? JOYCON2_BLE_STATUS_NOTIFYING : JOYCON2_BLE_STATUS_DISCONNECTED);
            joycon2_scan_start();
            return 0;
        }
        case BLE_GAP_EVENT_NOTIFY_RX: {
            joycon_conn_t *notify_ctx = ctx_for_handle(event->notify_rx.conn_handle);
            if (!notify_ctx) {
                notify_ctx = ctx;
            }
            if (!notify_ctx) {
                return 0;
            }
            bool expected_handle = event->notify_rx.attr_handle == notify_ctx->notify_handle ||
                                   event->notify_rx.attr_handle == notify_ctx->ack_handle;
            if (!expected_handle) {
                emit_status(JOYCON2_BLE_STATUS_NOTIFY_OTHER);
            }
            if (event->notify_rx.attr_handle != notify_ctx->notify_handle) {
                return 0;
            }
            uint16_t len = OS_MBUF_PKTLEN(event->notify_rx.om);
            uint8_t packet[96];
            if (len > sizeof(packet)) {
                len = sizeof(packet);
            }
            if (os_mbuf_copydata(event->notify_rx.om, 0, len, packet) != 0) {
                return 0;
            }

            joycon2_state_t st;
            if (parse_packet(packet, len, notify_ctx->side, &st) && s_cb) {
                notify_ctx->notifying = true;
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

static void joycon2_scan_start(void) {
    if (s_connecting || s_scanning || !free_slot_exists()) {
        return;
    }

    struct ble_gap_disc_params params;
    memset(&params, 0, sizeof(params));
    params.passive = 0;
    params.itvl = 0x0018;
    params.window = 0x0018;
    params.filter_duplicates = 0;

    int rc = ble_gap_disc(s_own_addr_type, BLE_HS_FOREVER, &params, joycon2_gap_event, NULL);
    if (rc != 0) {
        ESP_LOGW(TAG, "ble_gap_disc failed rc=%d", rc);
    } else {
        s_scanning = true;
        emit_status(JOYCON2_BLE_STATUS_SCANNING);
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
