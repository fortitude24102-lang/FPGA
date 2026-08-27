<script setup lang="ts">
import { ref } from 'vue'
import { request } from '../utils/request'

const taskId = ref('demo-task-001')
const status = ref<'pending' | 'running' | 'completed' | 'failed'>('pending')
const progress = ref(0)
const timeline = ref(['分子生成', '对接打分', 'Review 完成'])

async function pollTask() {
  status.value = 'running'
  const timer = window.setInterval(async () => {
    try {
      const data = await request<{ status: typeof status.value; progress?: number }>({
        url: `/api/tasks/${taskId.value}/status`,
      })
      status.value = data.status
      progress.value = data.progress || progress.value
    } catch {
      progress.value = Math.min(progress.value + 20, 100)
      if (progress.value >= 100) status.value = 'completed'
    }
    if (['completed', 'failed'].includes(status.value)) window.clearInterval(timer)
  }, 1000)
}

function downloadJson() {
  const blob = new Blob([JSON.stringify({ task_id: taskId.value, status: status.value }, null, 2)], {
    type: 'application/json',
  })
  const url = URL.createObjectURL(blob)
  const link = document.createElement('a')
  link.href = url
  link.download = `batch_result_${new Date().toISOString().slice(0, 10)}.json`
  link.click()
  URL.revokeObjectURL(url)
}
</script>

<template>
  <el-card shadow="never" class="hover-card">
    <template #header>批量任务进度</template>
    <el-input v-model="taskId" placeholder="task_id" />
    <el-button class="mt-12" type="primary" @click="pollTask">开始轮询</el-button>
    <el-progress class="mt-12" :percentage="progress" :status="status === 'failed' ? 'exception' : status === 'completed' ? 'success' : undefined" />
    <el-timeline class="mt-12">
      <el-timeline-item v-for="item in timeline" :key="item">{{ item }}</el-timeline-item>
    </el-timeline>
    <el-button v-if="status === 'completed'" @click="downloadJson">下载结果</el-button>
  </el-card>
</template>
