<script setup lang="ts">
defineProps<{ loading?: boolean; rows?: number }>()
</script>

<template>
  <div class="skeleton-card">
    <el-skeleton v-if="loading" animated :rows="rows || 4" />
    <slot v-else />
  </div>
</template>
