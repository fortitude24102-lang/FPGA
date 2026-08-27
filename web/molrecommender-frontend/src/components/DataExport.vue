<script setup lang="ts">
import { reactive, ref } from 'vue'
import service from '../utils/request'

const dataTypes = [
  'debates',
  'assessments',
  'radars',
  'learning_paths',
  'hallucination_results',
  'adaptations',
  'batch_reports',
  'agent_thoughts',
  'async_tasks',
  'socratic_logs',
  'audit_logs',
  'micro_credentials',
  'portfolios',
  'all',
]
const form = reactive({ data_type: 'all', format: 'json', user_id: 'researcher-demo-001' })
const exporting = ref(false)
const progress = ref(0)

async function exportData() {
  exporting.value = true
  progress.value = 0
  try {
    const response = await service.post('/api/export', form, {
      responseType: 'blob',
      onDownloadProgress(event) {
        if (event.total) progress.value = Math.round((event.loaded / event.total) * 100)
        else progress.value = Math.min(95, progress.value + 12)
      },
    })
    progress.value = 100
    download(response.data, form.format)
  } catch {
    const text = form.format === 'csv' ? 'id,name,type\n1,demo,frontend-fallback' : form.format === 'md' ? '# Demo Export\n\n后端导出接口暂不可用，已生成演示文件。' : JSON.stringify(form, null, 2)
    progress.value = 100
    download(new Blob([text]), form.format)
  } finally {
    window.setTimeout(() => {
      exporting.value = false
      progress.value = 0
    }, 700)
  }
}

function download(blob: Blob, ext: string) {
  const url = URL.createObjectURL(blob)
  const link = document.createElement('a')
  link.href = url
  link.download = `export_${form.data_type}_${new Date().toISOString().slice(0, 10)}.${ext}`
  link.click()
  URL.revokeObjectURL(url)
}
</script>

<template>
  <el-card shadow="never" class="hover-card">
    <template #header>数据导出</template>
    <el-form label-position="top">
      <el-form-item label="数据类型">
        <el-select v-model="form.data_type" filterable>
          <el-option v-for="item in dataTypes" :key="item" :label="item" :value="item" />
        </el-select>
      </el-form-item>
      <el-form-item label="格式">
        <el-radio-group v-model="form.format">
          <el-radio-button label="json" />
          <el-radio-button label="csv" />
          <el-radio-button label="md" />
        </el-radio-group>
      </el-form-item>
      <el-progress v-if="exporting" :percentage="progress" class="mt-12" />
      <el-button type="primary" :loading="exporting" @click="exportData">导出</el-button>
    </el-form>
  </el-card>
</template>
