#ifndef LIGHTPANDA_CURL_H3_NGTCP2_H
#define LIGHTPANDA_CURL_H3_NGTCP2_H

#include_next <ngtcp2/ngtcp2.h>

typedef struct ngtcp2_transport_params_raw {
    const uint8_t *base;
    size_t len;
} ngtcp2_transport_params_raw;

int ngtcp2_conn_set_local_transport_params_raw(
    ngtcp2_conn *conn,
    const ngtcp2_transport_params_raw *params);

#endif
