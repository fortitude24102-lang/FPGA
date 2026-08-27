<script setup lang="ts">
import { onMounted, ref } from 'vue'
import { RefreshRight } from '@element-plus/icons-vue'
import { ElMessage } from 'element-plus'
import { adminStatus, reloadConfig } from '../utils/api'
import BatchTaskProgress from '../components/BatchTaskProgress.vue'
import DataExport from '../components/DataExport.vue'

const loading = ref(false)
const status = ref<Record<string, unknown> & { rate_limit_buckets?: number; cache_hit_rate?: number }>({
  version: 'demo-frontend',
  cache_size: '演示缓存',
  websocket_connections: 0,
  rate_limit_buckets: 12,
  cache_hit_rate: 0.82,
  trace_id: '暂无',
})

async function loadStatus() {
  loading.value = true
  try {
    status.value = await adminStatus()
  } catch {
    status.value = {
      version: 'demo-frontend',
      cache_size: '使用浏览器临时数据',
      websocket_connections: 0,
      rate_limit_buckets: 12,
      cache_hit_rate: 0.82,
      trace_id: localStorage.getItem('last_trace_id') || '暂无',
    }
  } finally {
    loading.value = false
  }
}

async function reload() {
  try {
    await reloadConfig()
    ElMessage.success('配置已请求重新加载')
    await loadStatus()
  } catch {
    //ElMessage.warning('后端暂不可用，已保留当前配置展示')
  }
}

onMounted(loadStatus)
</script>

<template>
  <section class="stacked-page">
    <el-card shadow="never">
      <template #header>
        <div class="section-title">
          <span>系统运行状态</span>
          <el-button :icon="RefreshRight" :loading="loading" @click="loadStatus">刷新</el-button>
        </div>
      </template>
      <section class="admin-status-grid">
        <el-descriptions :column="2" border>
          <el-descriptions-item label="版本">{{ status.version }}</el-descriptions-item>
          <el-descriptions-item label="缓存大小">{{ status.cache_size }}</el-descriptions-item>
          <el-descriptions-item label="WebSocket 连接数">{{ status.websocket_connections }}</el-descriptions-item>
          <el-descriptions-item label="限流桶数">
            <span :class="{ dangerText: Number(status.rate_limit_buckets) > 80 }">{{ status.rate_limit_buckets }}</span>
          </el-descriptions-item>
          <el-descriptions-item label="Trace ID">{{ status.trace_id }}</el-descriptions-item>
        </el-descriptions>
        <div class="cache-ring">
          <el-progress type="circle" :percentage="Math.round(Number(status.cache_hit_rate || 0) * 100)" :width="126" />
          <strong>缓存命中率</strong>
        </div>
      </section>
      <el-button class="mt-12" type="primary" @click="reload">重新加载配置</el-button>
    </el-card>

    <section class="content-grid two-columns">
      <DataExport />
      <BatchTaskProgress />
    </section>
  </section>
</template>
