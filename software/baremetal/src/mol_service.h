#ifndef MOL_SERVICE_H
#define MOL_SERVICE_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define MOL_SERVICE_OK 0
#define MOL_SERVICE_ERR_ARGUMENT (-1)
#define MOL_SERVICE_ERR_BUSY (-2)
#define MOL_SERVICE_ERR_IO (-3)

#define MOL_SERVICE_TASK_NONE 7U
#define MOL_SERVICE_TASK_RELOAD 0xfeU

typedef enum {
    MOL_INIT = 0,
    MOL_READY = 1,
    MOL_BUSY = 2,
    MOL_RELOAD = 3,
    MOL_ERROR = 4
} mol_service_state_t;

typedef struct {
    void *context;
    uint64_t (*timer_now)(void *context);
    int (*clock_set)(void *context, uint32_t mhz);
    int (*xadc_read)(void *context, uint16_t *temperature_q8_8,
                     uint16_t *vccint_mv, uint16_t *vccaux_mv);
    int (*mmio_write)(void *context, uintptr_t address, uint32_t value);
    void (*watchdog_kick)(void *context);
    void (*idle)(void *context);
} mol_service_hooks_t;

typedef struct {
    uint8_t online;
    uint8_t fault;
    uint8_t state;
    uint8_t current_task;
    uint8_t fallback_active;
    uint8_t overclock_experimental;
    uint16_t temperature_q8_8;
    uint16_t vccint_mv;
    uint16_t vccaux_mv;
    uint16_t cpu_load_permille;
    uint32_t clock_mhz;
    uint32_t completed_count;
    uint32_t failed_count;
    uint32_t avg_latency_us;
    uint32_t batch_completed;
    uint32_t batch_total;
    uint32_t error_detail;
} mol_service_snapshot_t;

typedef struct {
    uint32_t latest_latency_us[4];
    uint32_t cpu_latency_us[4];
    uint16_t speedup_q8_8[4];
} mol_benchmark_snapshot_t;

typedef struct {
    mol_service_hooks_t hooks;
    mol_service_state_t state;
    uint8_t current_task;
    uint8_t fallback_active;
    uint8_t overclock_experimental;
    uint8_t reserved;
    uint32_t clock_mhz;
    uint32_t active_items;
    uint32_t completed_count;
    uint32_t failed_count;
    uint32_t avg_latency_us;
    uint64_t total_latency_us;
    uint64_t started_ticks;
    uint64_t deadline_ticks;
    uint64_t boot_ticks;
    uint64_t busy_ticks;
    uint64_t watchdog_mark;
    uint64_t sensor_mark;
    uint32_t ticks_per_second;
    uintptr_t display_base;
    uint16_t temperature_q8_8;
    uint16_t vccint_mv;
    uint16_t vccaux_mv;
    uint16_t cpu_load_permille;
    uint32_t batch_completed;
    uint32_t batch_total;
    uint32_t error_detail;
    mol_benchmark_snapshot_t benchmark;
} mol_service_t;

void mol_service_init(mol_service_t *service,
                      const mol_service_hooks_t *hooks,
                      uint32_t ticks_per_second, uintptr_t display_base);
int mol_service_mark_ready(mol_service_t *service);
int mol_service_recover(mol_service_t *service);
int mol_service_set_clock(mol_service_t *service, uint32_t mhz);
int mol_service_begin(mol_service_t *service, uint8_t task_id,
                      uint32_t items);
void mol_service_complete(mol_service_t *service, int success,
                          uint32_t latency_us);
void mol_service_set_batch(mol_service_t *service, uint32_t completed,
                           uint32_t total);
void mol_service_poll(mol_service_t *service, uint64_t now_ticks);
void mol_service_idle(mol_service_t *service);
void mol_service_snapshot(const mol_service_t *service,
                          mol_service_snapshot_t *snapshot);
void mol_service_benchmark_snapshot(const mol_service_t *service,
                                    mol_benchmark_snapshot_t *snapshot);
const char *mol_service_state_name(mol_service_state_t state);

#ifdef __cplusplus
}
#endif

#endif
