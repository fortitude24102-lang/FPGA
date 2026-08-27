<script setup lang="ts">
import { ref } from 'vue'
import { askSocratic } from '../utils/api'

type Message = { role: 'user' | 'agent'; text: string; hintLevel?: string; reveal?: boolean }
const question = ref('为什么分子对接打分高，不一定代表药物一定有效？')
const context = ref('分子对接与 ADMET 综合判断')
const background = ref('chemistry')
const turn = ref(1)
const messages = ref<Message[]>([])
const loading = ref(false)


  async function send() {
  if (!question.value.trim() || turn.value > 5) return
  messages.value.push({ role: 'user', text: question.value })
  loading.value = true
      try {
    const raw = await askSocratic({ user_id: 'anonymous', question: question.value, context: context.value, background: background.value, turn: turn.value })
    const payload = (raw as Record<string, unknown>).data as Record<string, unknown>
    messages.value.push({ role: 'agent', text: String(payload.reply || payload.response || payload.answer || payload.hint || ''), hintLevel: String(payload.hint_level || '引导'), reveal: Boolean(payload.should_reveal) })
  } catch  {
    const reveal = turn.value >= 5
    messages.value.push({ role: 'agent', hintLevel: turn.value < 4 ? '引导' : turn.value === 4 ? '提示' : '揭示答案', reveal, text: reveal ? '因为对接只描述结合可能性，还需要 ADMET、安全性、选择性和实验验证共同支撑。' : '你可以先想一想：钥匙能插进锁孔，是否就等于这扇门一定能安全打开？' })
  } finally {
    turn.value += 1
    loading.value = false
  }
}
</script>

<template>
  <section class="chat-page">
    <el-card shadow="never">
      <template #header><div class="section-title"><span>苏格拉底追问 Agent</span><el-tag>{{ Math.min(turn - 1, 5) }}/5 轮</el-tag></div></template>
      <div class="chat-log tall">
        <article v-for="(msg, index) in messages" :key="index" class="chat-bubble" :class="msg.role">
          <small>{{ msg.role === 'agent' ? `AI · ${msg.hintLevel}` : '我' }}</small>
          <p>{{ msg.text }}</p>
          <el-tag v-if="msg.reveal" type="success">第5轮揭示答案</el-tag>
        </article>
        <el-empty v-if="!messages.length" description="输入问题后，AI 会用追问引导你思考" />
      </div>
    </el-card>
    <el-card shadow="never">
      <el-input v-model="context" placeholder="上下文" class="mt-12" />
      <el-select v-model="background" class="mt-12"><el-option label="化学" value="chemistry" /><el-option label="计算机" value="cs" /><el-option label="生物" value="biology" /><el-option label="交叉" value="cross" /></el-select>
      <el-input v-model="question" type="textarea" :rows="5" class="mt-12" @keyup.ctrl.enter="send" />
      <el-button type="primary" class="mt-12" :loading="loading" :disabled="turn > 5" @click="send">发送追问</el-button>
    </el-card>
  </section>
</template>
