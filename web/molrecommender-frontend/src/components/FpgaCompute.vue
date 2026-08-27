<script setup lang="ts">
defineProps<{
  source?: 'fpga' | 'cpu_fallback' | string
  traceId?: string
  warning?: string
}>()
</script>

<template>
  <el-alert
    v-if="source === 'cpu_fallback'"
    type="warning"
    show-icon
    :closable="false"
    title="FPGA 不可用，已降级到 CPU 计算"
    :description="warning"
  />
  <el-alert
    v-else
    type="success"
    show-icon
    :closable="false"
    title="FPGA 加速计算中"
    description="当前结果来自硬件加速链路或后端默认计算链路。"
  />
  <p v-if="traceId" class="trace-footnote">trace_id: {{ traceId }}</p>
</template>
