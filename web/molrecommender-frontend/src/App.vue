<script setup lang="ts">
import { computed, onMounted, onUnmounted, ref } from 'vue'
import { RouterLink, RouterView, useRoute, useRouter } from 'vue-router'
import { ElMessage } from 'element-plus'
import { setStoredRole, getStoredRole, canAccessPath, roleLabels, type UserRole } from './utils/rbac'

const route = useRoute()
const router = useRouter()
const role = ref<UserRole>(getStoredRole())
const searchVisible = ref(false)
const searchQuery = ref('')

const navSections = [
  { title: '启动与画像', items: [
    { path: '/startup', title: '启动检查', caption: 'ready/health' },
    { path: '/profile', title: '研究员画像', caption: '能力与约束' },
    { path: '/assessment', title: '学情测评', caption: '背景适配题库' },
  ] },
  { title: 'AI 学习闭环', items: [
    { path: '/diagnosis', title: '诊断报告', caption: '知识盲区' },
    { path: '/profile/radar', title: '雷达画像', caption: 'AI 深度分析' },
    { path: '/adaptation', title: '动态难度', caption: '降维/挑战' },
    { path: '/difficulty-curve', title: '难度曲线', caption: '匹配趋势' },
    { path: '/socratic', title: '苏格拉底追问', caption: '5轮引导' },
    { path: '/learning-path', title: '学习路径', caption: '资源与版本' },
    { path: '/learning-path/history', title: '路径回溯', caption: '版本对比' },
  ] },
  { title: '图谱与成果', items: [
    { path: '/knowledge-graph', title: '知识图谱', caption: '传播推荐' },
    { path: '/knowledge-graph/propagation', title: '传播推荐', caption: '激活路径' },
    { path: '/profile/prediction', title: '效果预测', caption: '风险预警' },
    { path: '/profile/credentials', title: '微证书', caption: '徽章墙' },
    { path: '/profile/portfolio', title: '学习档案', caption: '终身累积' },
  ] },
  { title: '研发工作台', items: [
    { path: '/agent-dashboard', title: 'Agent 调度', caption: '协同过程' },
    { path: '/agent-monitor', title: '思维链监控', caption: 'Agent Monitor' },
    { path: '/debate', title: '智能辩论', caption: 'Reviewer vs Generator' },
    { path: '/molecules', title: '候选分子', caption: '结构与属性' },
    { path: '/hallucination', title: '幻觉检测', caption: 'RDKit 校验' },
    { path: '/resources', title: '研究资源', caption: '方法与工具' },
    { path: '/feedback', title: '反馈收集', caption: 'Learner Agent' },
  ] },
  { title: '治理与验收', items: [
    { path: '/tasks', title: '任务中心', caption: '异步进度' },
    { path: '/testing', title: '测试报告', caption: '严格验证' },
    { path: '/admin', title: '系统状态', caption: '导出与运维' },
    { path: '/privacy/statement', title: '隐私声明', caption: '合规说明' },
    { path: '/privacy/settings', title: '隐私设置', caption: '撤回/删除' },
  ] },
]

const visibleSections = computed(() => navSections.map((section) => ({ ...section, items: section.items.filter((item) => canAccessPath(item.path, role.value)) })).filter((section) => section.items.length))
const flatNav = computed(() => navSections.flatMap((section) => section.items))
const visibleNav = computed(() => visibleSections.value.flatMap((section) => section.items))
const filteredNav = computed(() => {
  const keyword = searchQuery.value.trim().toLowerCase()
  if (!keyword) return visibleNav.value
  return visibleNav.value.filter((item) => `${item.title} ${item.caption} ${item.path}`.toLowerCase().includes(keyword))
})
const currentItem = computed(() => flatNav.value.find((item) => item.path === route.path))
const currentTitle = computed(() => currentItem.value?.title || 'MolRecommender')
const currentCaption = computed(() => currentItem.value?.caption || '智能分子推荐')

function changeRole(nextRole: UserRole) {
  role.value = nextRole
  setStoredRole(nextRole)
  ElMessage.success(`已切换为${roleLabels[nextRole]}`)
  if (!canAccessPath(route.path, nextRole)) router.push('/403')
}

function syncRole(event: Event) {
  role.value = (event as CustomEvent<UserRole>).detail
}

function openResult(path: string) {
  searchVisible.value = false
  router.push(path)
}

function handleKeydown(event: KeyboardEvent) {
  const target = event.target as HTMLElement | null
  const typing = ['INPUT', 'TEXTAREA'].includes(target?.tagName || '') || target?.isContentEditable
  if ((event.ctrlKey || event.metaKey) && event.key.toLowerCase() === 'k') {
    event.preventDefault()
    searchVisible.value = true
    return
  }
  if (event.key === 'Escape') searchVisible.value = false
  if (!typing && event.key.toLowerCase() === 'r') {
    event.preventDefault()
    router.go(0)
  }
}

onMounted(() => {
  window.addEventListener('role-change', syncRole as EventListener)
  window.addEventListener('keydown', handleKeydown)
})
onUnmounted(() => {
  window.removeEventListener('role-change', syncRole as EventListener)
  window.removeEventListener('keydown', handleKeydown)
})
</script>

<template>
  <div class="layout-shell">
    <aside class="side-nav">
      <div class="brand-block">
        <p class="eyebrow">MolRecommender</p>
        <h1>智能分子推荐与学习决策平台</h1>
        <p>覆盖测评、AI 辩论、知识图谱、微证书、隐私合规和系统监控的前端工作台。</p>
      </div>

      <div class="role-switcher" aria-label="角色切换器">
        <span>当前角色</span>
        <el-segmented :model-value="role" :options="[
          { label: '学生', value: 'student' },
          { label: '教师', value: 'teacher' },
          { label: '管理员', value: 'admin' },
        ]" @update:model-value="changeRole($event as UserRole)" />
      </div>

      <nav class="nav-list">
        <section v-for="section in visibleSections" :key="section.title" class="nav-section">
          <small>{{ section.title }}</small>
          <RouterLink v-for="item in section.items" :key="item.path" :to="item.path" class="nav-item" :class="{ active: route.path === item.path }">
            <strong>{{ item.title }}</strong>
            <span>{{ item.caption }}</span>
          </RouterLink>
        </section>
      </nav>
    </aside>

    <main class="page-shell">
      <header class="page-header">
        <div>
          <p class="eyebrow">AI Drug Discovery Workspace</p>
          <h2>{{ currentTitle }}</h2>
          <span>{{ currentCaption }}</span>
        </div>
        <div class="inline-actions">
          <el-button @click="searchVisible = true">全局搜索</el-button>
          <el-tag effect="dark">{{ roleLabels[role] }}</el-tag>
        </div>
      </header>

      <RouterView v-slot="{ Component }">
        <Transition name="page" mode="out-in">
          <component :is="Component" />
        </Transition>
      </RouterView>
    </main>

    <el-dialog v-model="searchVisible" title="全局搜索" width="520px">
      <el-input v-model="searchQuery" autofocus placeholder="搜索靶点、药物、知识点或页面" />
      <div class="search-results">
        <button v-for="item in filteredNav" :key="item.path" @click="openResult(item.path)">
          <strong>{{ item.title }}</strong>
          <span>{{ item.caption }} · {{ item.path }}</span>
        </button>
      </div>
    </el-dialog>
  </div>
</template>
