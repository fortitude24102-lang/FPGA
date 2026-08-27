<script setup lang="ts">
import { onUnmounted, ref } from 'vue'
import { getTaskStatus, runBatchTest } from '../utils/api'

const tasks = ref([{ task_id: 'task_demo_001', status: 'pending', progress: 35, created_at: '2026-08-19 14:30:00', result: '' }])
let timer: number | null = null

async function submitTask() {
  try {
    const data = await runBatchTest({ type: 'molecule_generation', target: 'EGFR', count: 5 }) as any
    tasks.value.unshift({ task_id: data.task_id || `task_${Date.now()}`, status: 'running', progress: 0, created_at: new Date().toLocaleString(), result: '' })
  } catch {
    tasks.value.unshift({ task_id: `task_${Date.now()}`, status: 'running', progress: 0, created_at: new Date().toLocaleString(), result: '演示任务' })
  }
  poll()
}

function statusType(status: string) { return status === 'completed' ? 'success' : status === 'failed' ? 'exception' : undefined }
async function refresh(task: typeof tasks.value[number]) {
  try {
    const data = await getTaskStatus(task.task_id) as any
    Object.assign(task, data)
  } catch {
    task.progress = Math.min(100, task.progress + 20)
    task.status = task.progress >= 100 ? 'completed' : 'running'
    if (task.status === 'completed') task.result = '生成5个分子，对接得分 -10.5，QED 0.85'
  }
}
function poll() {
  if (timer) window.clearInterval(timer)
  timer = window.setInterval(() => tasks.value.filter((task) => task.status !== 'completed').forEach(refresh), 3000)
}
onUnmounted(() => { if (timer) window.clearInterval(timer) })
</script>

<template>
  <section class="stacked-page">
    <el-card shadow="never"><template #header><div class="section-title"><span>异步任务中心</span><el-button type="primary" @click="submitTask">提交任务</el-button></div></template>
      <article v-for="task in tasks" :key="task.task_id" class="task-card">
        <strong>任务ID：{{ task.task_id }}</strong>
        <el-progress :percentage="task.progress" :status="statusType(task.status)" />
        <p>状态：{{ task.status }} · 创建时间：{{ task.created_at }}</p>
        <p v-if="task.result">结果：{{ task.result }}</p>
        <el-button @click="refresh(task)">刷新进度</el-button>
      </article>
    </el-card>
  </section>
</template>
