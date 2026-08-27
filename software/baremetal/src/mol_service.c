#include "mol_service.h"

#include <string.h>

#define MOL_AXI_RETRIES 3U
#define MOL_PL_TIMEOUT_US_PER_ITEM 2000U
#define MOL_SENSOR_INTERVAL_SECONDS 1U
#define MOL_WATCHDOG_KICK_SECONDS 1U
#define MOL_MAX_TEMPERATURE_Q8_8 (80U << 8)
#define MOL_TANIMOTO_CORE_SPEEDUP_Q8_8 (120U << 8)

static const uint32_t cpu_us_per_item[4] = {6U, 13471U, 32U, 13509U};
static const uint32_t measured_items[4] = {64U, 2U, 64U, 3U};
static const uint32_t measured_fpga_us[4] = {33U, 797U, 99U, 1088U};

#define LCD_STATUS_OFFSET 0x500U
#define LCD_TEMP_OFFSET 0x504U
#define LCD_VOLTAGE_OFFSET 0x508U
#define LCD_DONE_OFFSET 0x50cU
#define LCD_FAIL_OFFSET 0x510U
#define LCD_AVG_LAT_OFFSET 0x514U
#define LCD_LAT0_OFFSET 0x518U
#define LCD_SPEED0_OFFSET 0x528U
#define LCD_BATCH_DONE_OFFSET 0x538U
#define LCD_BATCH_TOTAL_OFFSET 0x53cU

static uint64_t service_now(const mol_service_t *service)
{
    if (service->hooks.timer_now == NULL) {
        return 0U;
    }
    return service->hooks.timer_now(service->hooks.context);
}

static uint8_t display_task(uint8_t task_id)
{
    return task_id == MOL_SERVICE_TASK_RELOAD ? 4U :
           task_id <= 3U ? task_id : MOL_SERVICE_TASK_NONE;
}

static uint16_t ratio_q8_8(uint32_t cpu_us, uint32_t fpga_us)
{
    uint64_t value;
    if (fpga_us == 0U) {
        return 0U;
    }
    value = ((uint64_t)cpu_us * 256U + fpga_us/2U) / fpga_us;
    return value > 0xffffU ? 0xffffU : (uint16_t)value;
}

static int write_retry(mol_service_t *service, uintptr_t address,
                       uint32_t value)
{
    uint32_t attempt;
    if (service->hooks.mmio_write == NULL) {
        return MOL_SERVICE_OK;
    }
    for (attempt = 0U; attempt < MOL_AXI_RETRIES; ++attempt) {
        if (service->hooks.mmio_write(service->hooks.context,
                                      address, value) == 0) {
            return MOL_SERVICE_OK;
        }
    }
    return MOL_SERVICE_ERR_IO;
}

static void publish_display(mol_service_t *service)
{
    uint32_t status = (uint32_t)service->state |
        ((service->clock_mhz == 50U ? 0U :
          service->clock_mhz == 100U ? 1U : 2U) << 3) |
        ((uint32_t)display_task(service->current_task) << 5) |
        ((uint32_t)service->activity_toggle << 8);
    uint32_t voltage = (uint32_t)service->vccint_mv |
                       ((uint32_t)service->vccaux_mv << 16);
    uint32_t lane;

    (void)write_retry(service, service->display_base + LCD_STATUS_OFFSET,
                      status);
    (void)write_retry(service, service->display_base + LCD_TEMP_OFFSET,
                      service->temperature_q8_8);
    (void)write_retry(service, service->display_base + LCD_VOLTAGE_OFFSET,
                      voltage);
    (void)write_retry(service, service->display_base + LCD_DONE_OFFSET,
                      service->completed_count);
    (void)write_retry(service, service->display_base + LCD_FAIL_OFFSET,
                      service->failed_count);
    (void)write_retry(service, service->display_base + LCD_AVG_LAT_OFFSET,
                      service->avg_latency_us);
    for (lane = 0U; lane < 4U; ++lane) {
        (void)write_retry(service,
                          service->display_base + LCD_LAT0_OFFSET + lane*4U,
                          service->benchmark.latest_latency_us[lane]);
        (void)write_retry(service,
                          service->display_base + LCD_SPEED0_OFFSET + lane*4U,
                          service->benchmark.speedup_q8_8[lane]);
    }
    (void)write_retry(service, service->display_base + LCD_BATCH_DONE_OFFSET,
                      service->batch_completed);
    (void)write_retry(service, service->display_base + LCD_BATCH_TOTAL_OFFSET,
                      service->batch_total);
}

void mol_service_init(mol_service_t *service,
                      const mol_service_hooks_t *hooks,
                      uint32_t ticks_per_second, uintptr_t display_base)
{
    if (service == NULL) {
        return;
    }
    memset(service, 0, sizeof(*service));
    if (hooks != NULL) {
        service->hooks = *hooks;
    }
    service->state = MOL_INIT;
    service->current_task = MOL_SERVICE_TASK_NONE;
    service->clock_mhz = 100U;
    service->ticks_per_second = ticks_per_second == 0U ? 1U : ticks_per_second;
    service->display_base = display_base;
    service->batch_total = 0U;
    for (uint32_t lane = 0U; lane < 4U; ++lane) {
        service->benchmark.latest_latency_us[lane] = measured_fpga_us[lane];
        service->benchmark.cpu_latency_us[lane] =
            cpu_us_per_item[lane] * measured_items[lane];
        service->benchmark.end_to_end_speedup_q8_8[lane] = ratio_q8_8(
            service->benchmark.cpu_latency_us[lane], measured_fpga_us[lane]);
        service->benchmark.speedup_q8_8[lane] =
            service->benchmark.end_to_end_speedup_q8_8[lane];
    }
    service->benchmark.speedup_q8_8[0] = MOL_TANIMOTO_CORE_SPEEDUP_Q8_8;
    service->boot_ticks = service_now(service);
    service->watchdog_mark = service->boot_ticks;
    service->sensor_mark = service->boot_ticks;
}

int mol_service_mark_ready(mol_service_t *service)
{
    if (service == NULL || service->state != MOL_INIT) {
        return MOL_SERVICE_ERR_ARGUMENT;
    }
    service->state = MOL_READY;
    publish_display(service);
    return MOL_SERVICE_OK;
}

int mol_service_recover(mol_service_t *service)
{
    if (service == NULL || service->state != MOL_ERROR) {
        return MOL_SERVICE_ERR_ARGUMENT;
    }
    service->state = MOL_READY;
    service->current_task = MOL_SERVICE_TASK_NONE;
    service->error_detail = 0U;
    publish_display(service);
    return MOL_SERVICE_OK;
}

int mol_service_set_clock(mol_service_t *service, uint32_t mhz)
{
    uint32_t attempt;
    if (service == NULL || (mhz != 50U && mhz != 100U && mhz != 150U)) {
        return MOL_SERVICE_ERR_ARGUMENT;
    }
    if (service->state != MOL_READY) {
        return MOL_SERVICE_ERR_BUSY;
    }
    if (service->hooks.clock_set != NULL) {
        for (attempt = 0U; attempt < MOL_AXI_RETRIES; ++attempt) {
            if (service->hooks.clock_set(service->hooks.context, mhz) == 0) {
                service->clock_mhz = mhz;
                service->overclock_experimental = mhz == 150U;
                publish_display(service);
                return MOL_SERVICE_OK;
            }
        }
        service->state = MOL_ERROR;
        service->error_detail = 1U;
        publish_display(service);
        return MOL_SERVICE_ERR_IO;
    }
    service->clock_mhz = mhz;
    service->overclock_experimental = mhz == 150U;
    publish_display(service);
    return MOL_SERVICE_OK;
}

int mol_service_begin(mol_service_t *service, uint8_t task_id,
                      uint32_t items)
{
    uint64_t timeout_ticks;
    if (service == NULL || items == 0U || items > 128U) {
        return MOL_SERVICE_ERR_ARGUMENT;
    }
    if (service->state != MOL_READY) {
        return MOL_SERVICE_ERR_BUSY;
    }
    service->state = task_id == MOL_SERVICE_TASK_RELOAD ? MOL_RELOAD : MOL_BUSY;
    service->current_task = task_id;
    service->activity_toggle ^= 1U;
    service->active_items = items;
    service->fallback_active = 0U;
    service->started_ticks = service_now(service);
    timeout_ticks = ((uint64_t)MOL_PL_TIMEOUT_US_PER_ITEM * items *
                     service->ticks_per_second) / 1000000U;
    service->deadline_ticks = service->started_ticks +
                              (timeout_ticks == 0U ? 1U : timeout_ticks);
    publish_display(service);
    return MOL_SERVICE_OK;
}

void mol_service_complete(mol_service_t *service, int success,
                          uint32_t latency_us)
{
    uint64_t now;
    uint8_t task;
    if (service == NULL ||
        (service->state != MOL_BUSY && service->state != MOL_RELOAD)) {
        return;
    }
    now = service_now(service);
    service->busy_ticks += now - service->started_ticks;
    task = service->current_task;
    if (success != 0) {
        if (task < 4U) {
            service->completed_count += 1U;
            service->total_latency_us += latency_us;
            service->avg_latency_us = (uint32_t)(service->total_latency_us /
                                      service->completed_count);
            service->benchmark.latest_latency_us[task] = latency_us;
            service->benchmark.cpu_latency_us[task] =
                cpu_us_per_item[task] * service->active_items;
            service->benchmark.end_to_end_speedup_q8_8[task] = ratio_q8_8(
                service->benchmark.cpu_latency_us[task], latency_us);
            if (task != 0U) {
                service->benchmark.speedup_q8_8[task] =
                    service->benchmark.end_to_end_speedup_q8_8[task];
            }
        }
    } else {
        service->failed_count += 1U;
    }
    service->state = MOL_READY;
    service->active_items = 0U;
    // Publish the completed task once so sub-frame jobs remain visible on
    // the LCD.  The service/API state is idle immediately afterwards.
    publish_display(service);
    service->current_task = MOL_SERVICE_TASK_NONE;
}

void mol_service_set_batch(mol_service_t *service, uint32_t completed,
                           uint32_t total)
{
    if (service == NULL) {
        return;
    }
    service->batch_completed = completed;
    service->batch_total = total;
    publish_display(service);
}

void mol_service_poll(mol_service_t *service, uint64_t now_ticks)
{
    uint64_t interval;
    uint64_t elapsed;
    if (service == NULL) {
        return;
    }
    if ((service->state == MOL_BUSY || service->state == MOL_RELOAD) &&
        now_ticks >= service->deadline_ticks) {
        service->busy_ticks += service->deadline_ticks-service->started_ticks;
        service->failed_count += 1U;
        service->fallback_active = 1U;
        service->error_detail = 2U;
        service->state = MOL_READY;
        service->current_task = MOL_SERVICE_TASK_NONE;
        service->active_items = 0U;
    }

    interval = service->ticks_per_second * MOL_WATCHDOG_KICK_SECONDS;
    if (now_ticks-service->watchdog_mark >= interval) {
        if (service->hooks.watchdog_kick != NULL) {
            service->hooks.watchdog_kick(service->hooks.context);
        }
        service->watchdog_mark = now_ticks;
    }

    interval = service->ticks_per_second * MOL_SENSOR_INTERVAL_SECONDS;
    if (now_ticks-service->sensor_mark >= interval) {
        if (service->hooks.xadc_read != NULL &&
            service->hooks.xadc_read(service->hooks.context,
                                     &service->temperature_q8_8,
                                     &service->vccint_mv,
                                     &service->vccaux_mv) != 0) {
            service->state = MOL_ERROR;
            service->error_detail = 3U;
        }
        if (service->temperature_q8_8 > MOL_MAX_TEMPERATURE_Q8_8) {
            service->state = MOL_ERROR;
            service->error_detail = 4U;
        }
        elapsed = now_ticks-service->boot_ticks;
        service->cpu_load_permille = elapsed == 0U ? 0U :
            (uint16_t)((service->busy_ticks * 1000U) / elapsed);
        service->sensor_mark = now_ticks;
        publish_display(service);
    }
}

void mol_service_idle(mol_service_t *service)
{
    if (service != NULL && service->state == MOL_READY &&
        service->hooks.idle != NULL) {
        service->hooks.idle(service->hooks.context);
    }
}

void mol_service_snapshot(const mol_service_t *service,
                          mol_service_snapshot_t *snapshot)
{
    if (service == NULL || snapshot == NULL) {
        return;
    }
    memset(snapshot, 0, sizeof(*snapshot));
    snapshot->online = service->state != MOL_INIT;
    snapshot->fault = service->state == MOL_ERROR;
    snapshot->state = (uint8_t)service->state;
    snapshot->current_task = display_task(service->current_task);
    snapshot->fallback_active = service->fallback_active;
    snapshot->overclock_experimental = service->overclock_experimental;
    snapshot->temperature_q8_8 = service->temperature_q8_8;
    snapshot->vccint_mv = service->vccint_mv;
    snapshot->vccaux_mv = service->vccaux_mv;
    snapshot->cpu_load_permille = service->cpu_load_permille;
    snapshot->clock_mhz = service->clock_mhz;
    snapshot->completed_count = service->completed_count;
    snapshot->failed_count = service->failed_count;
    snapshot->avg_latency_us = service->avg_latency_us;
    snapshot->batch_completed = service->batch_completed;
    snapshot->batch_total = service->batch_total;
    snapshot->error_detail = service->error_detail;
}

void mol_service_benchmark_snapshot(const mol_service_t *service,
                                    mol_benchmark_snapshot_t *snapshot)
{
    if (service != NULL && snapshot != NULL) {
        *snapshot = service->benchmark;
    }
}

const char *mol_service_state_name(mol_service_state_t state)
{
    switch (state) {
    case MOL_INIT: return "INIT";
    case MOL_READY: return "READY";
    case MOL_BUSY: return "BUSY";
    case MOL_RELOAD: return "RELOAD";
    case MOL_ERROR: return "ERROR";
    default: return "UNKNOWN";
    }
}
