<script setup lang="ts">
import { useRoute, useRouter } from 'vue-router'
const route = useRoute()
const router = useRouter()
</script>

<template>
  <section class="stacked-page">
    <el-card shadow="never" class="empty-state danger-zone">
      <h3>当前角色无法访问该资源</h3>
      <p>你正在访问：{{ route.query.from || '受限页面' }}。请切换到教师或管理员角色后重试。</p>
      <el-button type="primary" @click="router.push('/startup')">返回启动检查</el-button>
    </el-card>
  </section>
</template>
