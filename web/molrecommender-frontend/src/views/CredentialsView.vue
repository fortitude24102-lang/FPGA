<script setup lang="ts">
import { computed, onMounted, ref } from 'vue'
import { getCredentials } from '../utils/api'

const credentials = ref([
  { title: '药物化学基础认证', skill_area: '药物化学', level: '高级', score: 90, earned_at: '2026-08-18', expiry_date: '2027-08-18', earned: true },
  { title: '靶点生物学认证', skill_area: '靶点生物', level: '中级', score: 78, earned_at: '2026-08-17', expiry_date: '2027-08-17', earned: true },
  { title: 'ADMET预测认证', skill_area: 'ADMET', level: '待解锁', score: 55, earned_at: '', expiry_date: '', earned: false },
  { title: '合成路线设计认证', skill_area: '合成路线', level: '待解锁', score: 45, earned_at: '', expiry_date: '2026-01-01', earned: false },
])
const earnedCount = computed(() => credentials.value.filter((item) => item.earned).length)
function expired(date: string) { return Boolean(date) && new Date(date).getTime() < Date.now() }
async function load() {
  try {
    const data = await getCredentials('anonymous') as any
    if (Array.isArray(data.credentials)) credentials.value = data.credentials
  } catch {}
}
load()
async function celebrate(item: { earned: boolean; score: number }) {
  if (!item.earned) return
  if (item.score < 90) return
  const confetti = (await import('canvas-confetti')).default
  confetti({ particleCount: 120, spread: 70, origin: { y: 0.68 } })
}

onMounted(() => {
  const hasPremium = credentials.value.some((item) => item.earned && item.score >= 90)
  if (hasPremium) window.setTimeout(() => celebrate({ earned: true, score: 90 }), 500)
})
</script>

<template>
  <section class="stacked-page">
    <el-card shadow="never"><template #header><div class="section-title"><span>我的微证书</span><el-tag>{{ earnedCount }}/{{ credentials.length }}</el-tag></div></template>
      <div class="credential-grid">
        <article v-for="item in credentials" @mouseenter="celebrate(item)" :key="item.title" class="credential-card" :class="{ locked: !item.earned, premium: item.score >= 90, expired: expired(item.expiry_date) }">
          <strong>{{ item.earned ? '勋章' : '锁定' }}</strong>
          <h3>{{ item.title }}</h3>
          <p>{{ item.skill_area }} · {{ item.level }}</p>
          <span>得分：{{ item.score }}</span>
          <el-tag v-if="expired(item.expiry_date)" type="danger">证书已过期，需复训</el-tag>
          <el-button v-if="!item.earned || expired(item.expiry_date)" type="primary" plain @click="$router.push('/assessment')">重新测评</el-button>
        </article>
      </div>
    </el-card>
  </section>
</template>

