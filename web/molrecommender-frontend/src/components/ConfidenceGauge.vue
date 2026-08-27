<script setup lang="ts">
defineProps<{
  label: string
  value: number
  color?: string
}>()
</script>

<template>
  <div class="confidence-gauge" :style="{ '--gauge-value': `${Math.min(value, 100)}%`, '--gauge-color': color || '#2D6A5F' }">
    <div class="gauge-arc">
      <strong>{{ value }}%</strong>
    </div>
    <span>{{ label }}</span>
  </div>
</template>
