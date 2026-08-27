<script setup lang="ts">
import { computed, ref } from 'vue'
import { adjustAdaptation } from '../utils/api'

const userId = ref('anonymous')
const correctRate = ref(35)
const currentLevel = ref('standard')
const result = ref<Record<string, unknown> | null>(null)
const mode = computed(() => correctRate.value < 50 ? '降维解释模式' : correctRate.value > 85 ? '进阶挑战模式' : '标准巩固模式')
const modeClass = computed(() => correctRate.value < 50 ? 'low' : correctRate.value > 85 ? 'high' : 'normal')

async function adjust() {
  try {
    result.value = await adjustAdaptation({ user_id: userId.value, correct_rate: correctRate.value / 100, current_level: currentLevel.value }) as Record<string, unknown>
  } catch {
    result.value = {
      strategy: mode.value,
      reason: `正确率 ${correctRate.value}%，系统建议切换学习策略。`,
      downgrade_explanation: '可以把分子对接理解为钥匙和锁：配体是钥匙，靶点是锁，打分就是判断钥匙是否适合这把锁。',
      socratic_question: '你能用生活中的例子说明分子和靶点为什么需要形状互补吗？',
      recommended_resources: ['分子对接入门卡片', 'ADMET 基础练习', '案例复盘清单'],
      challenge_tasks: ['解释 hERG 风险来源', '设计一个降低 logP 的结构修改方案'],
    }
  }
}
</script>

<template>
  <section class="stacked-page">
    <el-card shadow="never">
      <template #header><div class="section-title"><span>动态难度调整</span><el-tag>{{ mode }}</el-tag></div></template>
      <div class="control-grid">
        <label>用户 ID<el-input v-model="userId" /></label>
        <label>当前难度<el-select v-model="currentLevel"><el-option label="基础" value="basic" /><el-option label="标准" value="standard" /><el-option label="进阶" value="advanced" /></el-select></label>
        <label>当前正确率<el-slider v-model="correctRate" :min="0" :max="100" show-input /></label>
      </div>
      <el-button type="primary" @click="adjust">获取建议</el-button>
    </el-card>
    <el-card v-if="result" shadow="never" class="mode-card" :class="modeClass">
      <h3>{{ result.strategy || mode }}</h3>
      <p>{{ result.reason }}</p>
      <blockquote>{{ result.downgrade_explanation || '保持当前学习节奏，继续通过案例练习巩固知识。' }}</blockquote>
      <div class="tag-cloud"><el-tag v-for="item in (result.recommended_resources as string[] || [])" :key="item">{{ item }}</el-tag></div>
      <h4>进阶挑战</h4>
      <ul><li v-for="task in (result.challenge_tasks as string[] || [])" :key="task">{{ task }} <el-button link type="primary">接受挑战</el-button></li></ul>
    </el-card>
  </section>
</template>
