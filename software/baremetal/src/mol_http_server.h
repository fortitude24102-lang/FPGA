#ifndef MOL_HTTP_SERVER_H
#define MOL_HTTP_SERVER_H

#include <stddef.h>

#include "mol_service.h"

#ifdef __cplusplus
extern "C" {
#endif

#define MOL_HTTP_MAX_REQUEST 1024U
#define MOL_HTTP_MAX_RESPONSE 8192U

#define MOL_HTTP_INCOMPLETE 0
#define MOL_HTTP_READY 1
#define MOL_HTTP_ERR_ARGUMENT (-1)
#define MOL_HTTP_ERR_CAPACITY (-2)

int mol_http_respond(const char *request, size_t request_len,
                     const mol_service_snapshot_t *health,
                     const mol_benchmark_snapshot_t *benchmark,
                     char *response, size_t response_capacity,
                     size_t *response_len);

#ifdef __cplusplus
}
#endif

#endif
