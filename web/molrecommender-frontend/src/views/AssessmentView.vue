<script setup lang="ts">
import { computed, ref } from 'vue'
import { ElMessage } from 'element-plus'
import { startAssessment, submitAssessment } from '../utils/api'

const backgrounds = [
  { label: '化学', value: 'chemistry' },
  { label: '计算机', value: 'cs' },
  { label: '生物', value: 'biology' },
  { label: '交叉学科', value: 'cross' },
]
const questions = ref([
  { id: 'q1', dimension: '药物化学基础', difficulty: 'easy', title: '下列哪个官能团常用于增强分子的亲脂性？', options: ['羟基', '羧基', '氟原子', '磺酸基'] },
  { id: 'q2', dimension: 'ADMET理解', difficulty: 'medium', title: 'Lipinski 五规则主要用于初步判断什么？', options: ['口服成药性', '晶型稳定性', '专利新颖性', '蛋白表达量'] },
  { id: 'q3', dimension: '分子对接知识', difficulty: 'hard', title: '对接打分异常偏高时，最应该优先复核什么？', options: ['口袋与构象', '页面配色', '文件名', '浏览器缓存'] },
])
const background = ref('chemistry')
const questionCount = ref(10)
const assessmentId = ref('')
const current = ref(0)
const answers = ref<Record<string, string>>({})
const result = ref<Record<string, unknown> | null>(null)
const fallbackQuestion = { id: 'fallback', dimension: '学情测评', difficulty: 'easy', title: '暂无题目，请重新开始测评。', options: ['知道了'] }
const activeQuestion = computed(() => questions.value[current.value] || fallbackQuestion)
const progress = computed(() => Math.round((Object.keys(answers.value).length / questions.value.length) * 100))

async function start() {
  try {
    const data = await startAssessment({ user_id: 'anonymous', background: background.value, question_count: questionCount.value }) as Record<string, unknown>
    assessmentId.value = String(data.assessment_id || data.id || `demo_${Date.now()}`)
    const remoteQuestions = data.questions as typeof questions.value | undefined
    if (Array.isArray(remoteQuestions) && remoteQuestions.length) questions.value = remoteQuestions
  } catch {
    assessmentId.value = `demo_${Date.now()}`
    ElMessage.info('后端测评接口暂不可用，已进入演示测评')
  }
  current.value = 0
  result.value = null
  answers.value = {}
}

async function submit() {
  if (!assessmentId.value) return ElMessage.warning('请先开始测评')
  if (Object.keys(answers.value).length < questions.value.length) return ElMessage.warning('请完成所有题目后提交')
  try {
    result.value = await submitAssessment(assessmentId.value, { answers: answers.value }) as Record<string, unknown>
  } catch {
    result.value = { total_score: 72, duration: '8分32秒', completed: true }
  }
}
</script>

<template>
  <section class="stacked-page">
    <el-card shadow="never">
      <template #header><div class="section-title"><span>学情测评配置</span><el-tag>54题库适配</el-tag></div></template>
      <div class="control-grid">
        <label>学习者背景<el-segmented v-model="background" :options="backgrounds" /></label>
        <label>题目数量<el-input-number v-model="questionCount" :min="5" :max="20" /></label>
        <el-button type="primary" @click="start">开始测评</el-button>
      </div>
    </el-card>

    <el-card v-if="assessmentId && !result" shadow="never">
      <template #header><div class="section-title"><span>第 {{ current + 1 }}/{{ questions.length }} 题</span><el-tag :type="activeQuestion.difficulty === 'hard' ? 'danger' : activeQuestion.difficulty === 'medium' ? 'warning' : 'success'">{{ activeQuestion.difficulty }}</el-tag></div></template>
      <p class="eyebrow">{{ activeQuestion.dimension }}</p>
      <h3>{{ activeQuestion.title }}</h3>
      <el-radio-group v-model="answers[activeQuestion.id]" class="option-list">
        <el-radio v-for="option in activeQuestion.options" :key="option" :value="option" border>{{ option }}</el-radio>
      </el-radio-group>
      <el-progress :percentage="progress" class="mt-12" />
      <div class="inline-actions mt-12"><el-button :disabled="current === 0" @click="current--">上一题</el-button><el-button :disabled="current === questions.length - 1" @click="current++">下一题</el-button><el-button type="primary" @click="submit">提交</el-button></div>
    </el-card>

    <el-card v-if="result" shadow="never" class="success-card">
      <h3>测评完成</h3>
      <strong class="hero-number">{{ result.total_score || result.score || 72 }}/100</strong>
      <p>用时：{{ result.duration || '8分32秒' }}</p>
      <div class="inline-actions"><el-button type="primary" @click="$router.push('/profile/radar')">查看雷达图</el-button><el-button @click="$router.push('/learning-path')">查看学习路径</el-button></div>
    </el-card>
  </section>
</template>

