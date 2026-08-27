import './assets/main.css'
import 'element-plus/dist/index.css'
import 'vue-virtual-scroller/dist/vue-virtual-scroller.css'

import { createApp } from 'vue'
import ElementPlus from 'element-plus'
import { ElMessage } from 'element-plus'
import * as Sentry from '@sentry/vue'
import App from './App.vue'
import router from './router'

const app = createApp(App)

if (import.meta.env.VITE_SENTRY_DSN) {
  Sentry.init({
    app,
    dsn: import.meta.env.VITE_SENTRY_DSN,
    tracesSampleRate: 0.2,
  })
}

app.config.errorHandler = (error) => {
  console.error('[MolRecommender UI]', error)
  Sentry.captureException(error)
  ElMessage.error('页面出现异常，已记录到浏览器控制台')
}

app.use(ElementPlus).use(router).mount('#app')
