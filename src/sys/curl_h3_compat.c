#include <stdatomic.h>
#include <string.h>

#include <ngtcp2/ngtcp2.h>

typedef struct raw_transport_params_slot {
    ngtcp2_conn *conn;
    const uint8_t *base;
    size_t len;
} raw_transport_params_slot;

static raw_transport_params_slot raw_transport_params[128];
static atomic_flag raw_transport_params_lock = ATOMIC_FLAG_INIT;

static void lock_raw_transport_params(void) {
    while (atomic_flag_test_and_set_explicit(
        &raw_transport_params_lock,
        memory_order_acquire)) {}
}

static void unlock_raw_transport_params(void) {
    atomic_flag_clear_explicit(&raw_transport_params_lock, memory_order_release);
}

ngtcp2_ssize lightpanda_ngtcp2_conn_encode_local_transport_params(
    ngtcp2_conn *conn,
    uint8_t *dest,
    size_t destlen);

void lightpanda_ngtcp2_conn_del(ngtcp2_conn *conn);

int ngtcp2_conn_set_local_transport_params_raw(
    ngtcp2_conn *conn,
    const ngtcp2_transport_params_raw *params) {
    ngtcp2_transport_params decoded;
    int rv = ngtcp2_transport_params_decode(&decoded, params->base, params->len);
    if (rv != 0) {
        return rv;
    }
    lock_raw_transport_params();
    raw_transport_params_slot *empty = NULL;
    for (size_t i = 0; i < sizeof(raw_transport_params) / sizeof(raw_transport_params[0]); ++i) {
        raw_transport_params_slot *slot = &raw_transport_params[i];
        if (slot->conn == conn) {
            slot->base = params->base;
            slot->len = params->len;
            unlock_raw_transport_params();
            return 0;
        }
        if (empty == NULL && slot->conn == NULL) {
            empty = slot;
        }
    }
    if (empty != NULL) {
        *empty = (raw_transport_params_slot){conn, params->base, params->len};
    }
    unlock_raw_transport_params();
    return empty == NULL ? NGTCP2_ERR_NOMEM : 0;
}

ngtcp2_ssize ngtcp2_conn_encode_local_transport_params(
    ngtcp2_conn *conn,
    uint8_t *dest,
    size_t destlen) {
    const uint8_t *base = NULL;
    size_t len = 0;

    lock_raw_transport_params();
    for (size_t i = 0; i < sizeof(raw_transport_params) / sizeof(raw_transport_params[0]); ++i) {
        if (raw_transport_params[i].conn == conn) {
            base = raw_transport_params[i].base;
            len = raw_transport_params[i].len;
            break;
        }
    }
    unlock_raw_transport_params();

    if (base == NULL) {
        return lightpanda_ngtcp2_conn_encode_local_transport_params(conn, dest, destlen);
    }
    if (destlen < len) {
        return NGTCP2_ERR_NOBUF;
    }
    memcpy(dest, base, len);
    return (ngtcp2_ssize)len;
}

void ngtcp2_conn_del(ngtcp2_conn *conn) {
    lock_raw_transport_params();
    for (size_t i = 0; i < sizeof(raw_transport_params) / sizeof(raw_transport_params[0]); ++i) {
        if (raw_transport_params[i].conn == conn) {
            raw_transport_params[i] = (raw_transport_params_slot){0};
            break;
        }
    }
    unlock_raw_transport_params();
    lightpanda_ngtcp2_conn_del(conn);
}
