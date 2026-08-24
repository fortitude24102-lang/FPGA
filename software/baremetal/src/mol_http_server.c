#include "mol_http_server.h"

#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#define MOL_HTTP_HEADER_RESERVE 256U

typedef struct {
    char *data;
    size_t capacity;
    size_t length;
    int failed;
} mol_http_writer_t;

static const char dashboard_html[] =
"<!doctype html><html lang='zh-CN'><head><meta charset='utf-8'>"
"<meta name='viewport' content='width=device-width,initial-scale=1'>"
"<title>MolRecommender FPGA</title><style>"
":root{color-scheme:dark;--bg:#08111f;--card:#101d30;--line:#233650;"
"--text:#e9f2ff;--muted:#8fa6c3;--green:#22c55e;--red:#ef4444;"
"--blue:#38bdf8;--violet:#a78bfa}*{box-sizing:border-box}body{margin:0;"
"font-family:Arial,sans-serif;background:radial-gradient(circle at top,#122746,#08111f 55%);"
"color:var(--text)}main{max-width:1180px;margin:auto;padding:24px}header{display:flex;"
"justify-content:space-between;align-items:center;margin-bottom:18px}.brand{font-size:25px;"
"font-weight:700}.sub,.muted{color:var(--muted)}.status{display:flex;gap:9px;"
"align-items:center;background:var(--card);padding:10px 15px;border-radius:22px}"
".dot{width:12px;height:12px;border-radius:50%;background:#64748b;box-shadow:0 0 12px currentColor}"
".grid{display:grid;grid-template-columns:repeat(4,1fr);gap:14px}.card{background:rgba(16,29,48,.94);"
"border:1px solid var(--line);border-radius:16px;padding:17px;box-shadow:0 12px 32px #0004}"
".wide{grid-column:span 2}.label{font-size:13px;color:var(--muted)}.value{font-size:28px;"
"font-weight:700;margin-top:7px}.progress{height:15px;background:#1e293b;border-radius:9px;"
"overflow:hidden;margin-top:14px}.bar{height:100%;width:0;background:linear-gradient(90deg,var(--blue),"
"var(--violet));transition:width .4s}.bench{display:grid;gap:12px;margin-top:12px}.lane{display:grid;"
"grid-template-columns:90px 1fr 72px;align-items:center;gap:10px}.track{height:11px;background:#1e293b;"
"border-radius:7px;overflow:hidden}.speed{height:100%;background:linear-gradient(90deg,#0ea5e9,#22c55e)}"
"footer{text-align:center;color:var(--muted);margin-top:18px;font-size:12px}"
"@media(max-width:760px){.grid{grid-template-columns:1fr 1fr}.wide{grid-column:span 2}}"
"</style></head><body><main><header><div><div class='brand'>MolRecommender</div>"
"<div class='sub'>Z15 AI 药物分子加速状态面板</div></div><div class='status'>"
"<span id='dot' class='dot'></span><span id='state'>连接中</span></div></header>"
"<section class='grid'><div class='card'><div class='label'>当前任务</div><div id='task' class='value'>--</div>"
"</div><div class='card'><div class='label'>已完成任务</div><div id='done' class='value'>0</div>"
"</div><div class='card'><div class='label'>平均延迟</div><div id='lat' class='value'>0 μs</div>"
"</div><div class='card'><div class='label'>芯片温度</div><div id='temp' class='value'>-- °C</div>"
"</div><div class='card'><div class='label'>PL 时钟</div><div id='clk' class='value'>-- MHz</div>"
"</div><div class='card'><div class='label'>CPU 负载</div><div id='cpu' class='value'>-- %</div>"
"</div><div class='card'><div class='label'>VCCINT / VCCAUX</div><div id='volt' class='value'>--</div>"
"</div><div class='card'><div class='label'>失败 / 回退</div><div id='fail' class='value'>--</div>"
"</div><div class='card wide'><div class='label'>10 万分子批处理进度</div>"
"<div id='progressText' class='value'>0 / 100000</div><div class='progress'><div id='progress' class='bar'></div>"
"</div></div><div class='card wide'><div class='label'>CPU vs FPGA 加速比</div><div id='bench' class='bench'>"
"</div></div></section><footer>板卡 192.168.1.10 · 每 2 秒自动刷新 · 150 MHz 为实验超频</footer>"
"</main><script>const $=x=>document.getElementById(x);async function refresh(){try{const[h,b]=await Promise.all(["
"fetch('/api/fpga/health',{cache:'no-store'}).then(r=>r.json()),fetch('/api/fpga/benchmark',{cache:'no-store'}).then(r=>r.json())]);"
"$('state').textContent=h.status;$('dot').style.background=h.fault?'#ef4444':h.online?'#22c55e':'#64748b';"
"$('task').textContent=h.current_task;$('done').textContent=h.completed_tasks;$('lat').textContent=h.avg_latency_us+' μs';"
"$('temp').textContent=h.temperature_c+' °C';$('clk').textContent=h.clock_mhz+' MHz'+(h.overclock_experimental?' EXP':'');"
"$('cpu').textContent=h.cpu_load_percent+' %';$('volt').textContent=h.vccint_mv+' / '+h.vccaux_mv+' mV';"
"$('fail').textContent=h.failed_tasks+' / '+(h.fallback?'ON':'OFF');$('progressText').textContent=h.batch_completed+' / '+h.batch_total;"
"$('progress').style.width=h.progress_percent+'%';$('bench').innerHTML=b.lanes.map(x=>`<div class='lane'><b>${x.name}</b>"
"<div class='track'><div class='speed' style='width:${Math.min(x.speedup*2,100)}%'></div></div><span>${x.speedup}×</span></div>`).join('');"
"}catch(e){$('state').textContent='离线';$('dot').style.background='#64748b'}}refresh();setInterval(refresh,2000);"
"</script></body></html>";

static void writer_append(mol_http_writer_t *writer, const char *format, ...)
{
    int written;
    va_list args;
    if (writer->failed != 0 || writer->length >= writer->capacity) {
        writer->failed = 1;
        return;
    }
    va_start(args, format);
    written = vsnprintf(writer->data + writer->length,
                        writer->capacity - writer->length, format, args);
    va_end(args);
    if (written < 0 || (size_t)written >= writer->capacity-writer->length) {
        writer->failed = 1;
        return;
    }
    writer->length += (size_t)written;
}

static int request_complete(const char *request, size_t length)
{
    size_t index;
    for (index = 3U; index < length; ++index) {
        if (request[index-3U] == '\r' && request[index-2U] == '\n' &&
            request[index-1U] == '\r' && request[index] == '\n') {
            return 1;
        }
    }
    return 0;
}

static const char *state_name(uint8_t state)
{
    switch ((mol_service_state_t)state) {
    case MOL_INIT: return "INIT";
    case MOL_READY: return "READY";
    case MOL_BUSY: return "BUSY";
    case MOL_RELOAD: return "RELOAD";
    case MOL_ERROR: return "ERROR";
    default: return "UNKNOWN";
    }
}

static const char *task_name(uint8_t task)
{
    static const char *const names[] = {
        "Tanimoto", "GNN", "ADMET", "Pipeline", "Reload"
    };
    return task < 5U ? names[task] : "Idle";
}

static void append_health(mol_http_writer_t *writer,
                          const mol_service_snapshot_t *health)
{
    uint32_t temperature_whole = health->temperature_q8_8 >> 8;
    uint32_t temperature_fraction =
        ((health->temperature_q8_8 & 0xffU) * 100U + 128U) >> 8;
    uint32_t progress = health->batch_total == 0U ? 0U :
        (uint32_t)(((uint64_t)health->batch_completed * 100U) /
                   health->batch_total);
    if (temperature_fraction == 100U) {
        temperature_whole += 1U;
        temperature_fraction = 0U;
    }
    if (progress > 100U) {
        progress = 100U;
    }
    writer_append(writer,
        "{\"status\":\"%s\",\"online\":%s,\"fault\":%s,"
        "\"current_task\":\"%s\",\"completed_tasks\":%lu,"
        "\"failed_tasks\":%lu,\"avg_latency_us\":%lu,"
        "\"temperature_c\":%lu.%02lu,\"vccint_mv\":%u,"
        "\"vccaux_mv\":%u,\"clock_mhz\":%lu,"
        "\"cpu_load_percent\":%u.%u,\"fallback\":%s,"
        "\"overclock_experimental\":%s,\"batch_completed\":%lu,"
        "\"batch_total\":%lu,\"progress_percent\":%lu}",
        state_name(health->state), health->online ? "true" : "false",
        health->fault ? "true" : "false", task_name(health->current_task),
        (unsigned long)health->completed_count,
        (unsigned long)health->failed_count,
        (unsigned long)health->avg_latency_us,
        (unsigned long)temperature_whole,
        (unsigned long)temperature_fraction, health->vccint_mv,
        health->vccaux_mv, (unsigned long)health->clock_mhz,
        health->cpu_load_permille / 10U, health->cpu_load_permille % 10U,
        health->fallback_active ? "true" : "false",
        health->overclock_experimental ? "true" : "false",
        (unsigned long)health->batch_completed,
        (unsigned long)health->batch_total, (unsigned long)progress);
}

static void append_benchmark(mol_http_writer_t *writer,
                             const mol_benchmark_snapshot_t *benchmark)
{
    static const char *const names[4] = {
        "Tanimoto", "GNN", "ADMET", "Pipeline"
    };
    uint32_t lane;
    writer_append(writer, "{\"lanes\":[");
    for (lane = 0U; lane < 4U; ++lane) {
        uint32_t whole = benchmark->speedup_q8_8[lane] >> 8;
        uint32_t fraction =
            ((benchmark->speedup_q8_8[lane] & 0xffU) * 100U + 128U) >> 8;
        if (fraction == 100U) {
            whole += 1U;
            fraction = 0U;
        }
        writer_append(writer,
            "%s{\"name\":\"%s\",\"cpu_us\":%lu,\"fpga_us\":%lu,"
            "\"speedup\":%lu.%02lu}", lane == 0U ? "" : ",", names[lane],
            (unsigned long)benchmark->cpu_latency_us[lane],
            (unsigned long)benchmark->latest_latency_us[lane],
            (unsigned long)whole, (unsigned long)fraction);
    }
    writer_append(writer, "]}");
}

static int make_response(const char *status, const char *content_type,
                         mol_http_writer_t *body, char *response,
                         size_t response_capacity, size_t *response_len)
{
    int header_len;
    if (body->failed != 0) {
        return MOL_HTTP_ERR_CAPACITY;
    }
    header_len = snprintf(response, MOL_HTTP_HEADER_RESERVE,
        "HTTP/1.0 %s\r\nContent-Type: %s\r\nContent-Length: %lu\r\n"
        "Cache-Control: no-store\r\nConnection: close\r\n\r\n",
        status, content_type, (unsigned long)body->length);
    if (header_len < 0 || (size_t)header_len >= MOL_HTTP_HEADER_RESERVE ||
        (size_t)header_len + body->length >= response_capacity) {
        return MOL_HTTP_ERR_CAPACITY;
    }
    memmove(response + (size_t)header_len, body->data, body->length);
    *response_len = (size_t)header_len + body->length;
    return MOL_HTTP_READY;
}

int mol_http_respond(const char *request, size_t request_len,
                     const mol_service_snapshot_t *health,
                     const mol_benchmark_snapshot_t *benchmark,
                     char *response, size_t response_capacity,
                     size_t *response_len)
{
    const char *first_space;
    const char *second_space;
    const char *status = "200 OK";
    const char *content_type = "application/json; charset=utf-8";
    char path[64];
    size_t method_len;
    size_t path_len;
    mol_http_writer_t body;

    if (response_len != NULL) {
        *response_len = 0U;
    }
    if (request == NULL || health == NULL || benchmark == NULL ||
        response == NULL || response_len == NULL) {
        return MOL_HTTP_ERR_ARGUMENT;
    }
    if (request_len > MOL_HTTP_MAX_REQUEST) {
        return MOL_HTTP_ERR_CAPACITY;
    }
    if (request_complete(request, request_len) == 0) {
        return MOL_HTTP_INCOMPLETE;
    }
    if (response_capacity <= MOL_HTTP_HEADER_RESERVE) {
        return MOL_HTTP_ERR_CAPACITY;
    }

    body.data = response + MOL_HTTP_HEADER_RESERVE;
    body.capacity = response_capacity - MOL_HTTP_HEADER_RESERVE;
    body.length = 0U;
    body.failed = 0;
    first_space = (const char *)memchr(request, ' ', request_len);
    second_space = first_space == NULL ? NULL :
        (const char *)memchr(first_space + 1, ' ',
                            request_len-(size_t)(first_space+1-request));
    if (first_space == NULL || second_space == NULL) {
        status = "400 Bad Request";
        content_type = "text/plain; charset=utf-8";
        writer_append(&body, "Bad Request");
    } else {
        method_len = (size_t)(first_space-request);
        path_len = (size_t)(second_space-first_space-1);
        if (path_len >= sizeof(path)) {
            status = "404 Not Found";
            content_type = "text/plain; charset=utf-8";
            writer_append(&body, "Not Found");
        } else if (method_len != 3U || memcmp(request, "GET", 3U) != 0) {
            status = "405 Method Not Allowed";
            content_type = "text/plain; charset=utf-8";
            writer_append(&body, "Method Not Allowed");
        } else {
            memcpy(path, first_space + 1, path_len);
            path[path_len] = '\0';
            if (strcmp(path, "/") == 0) {
                content_type = "text/html; charset=utf-8";
                writer_append(&body, "%s", dashboard_html);
            } else if (strcmp(path, "/api/fpga/health") == 0) {
                append_health(&body, health);
            } else if (strcmp(path, "/api/fpga/benchmark") == 0) {
                append_benchmark(&body, benchmark);
            } else {
                status = "404 Not Found";
                content_type = "text/plain; charset=utf-8";
                writer_append(&body, "Not Found");
            }
        }
    }
    return make_response(status, content_type, &body, response,
                         response_capacity, response_len);
}
