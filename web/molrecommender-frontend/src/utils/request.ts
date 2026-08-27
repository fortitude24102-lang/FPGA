import axios, { type AxiosError, type AxiosRequestConfig } from 'axios'
import { ElMessage, ElNotification } from 'element-plus'
import { v4 as uuidv4 } from 'uuid'
import { getStoredRole } from './rbac'

export const API_ORIGIN = import.meta.env.VITE_API_BASE_URL || 'http://127.0.0.1:8000'
const MAX_BODY_SIZE = 10 * 1024 * 1024

function bodySizeOf(data: unknown) {
  if (!data) return 0
  const raw = typeof data === 'string' ? data : JSON.stringify(data)
  return new Blob([raw]).size
}

const service = axios.create({
  baseURL: API_ORIGIN,
  timeout: 30000,
  headers: { 'Content-Type': 'application/json' },
})

service.interceptors.request.use((config) => {
  const size = bodySizeOf(config.data)
  if (size > MAX_BODY_SIZE) {
   // ElMessage.error('数据过大，请拆分批次')
    return Promise.reject(new Error('Request body exceeds 10MB'))
  }

  const traceId = uuidv4().replaceAll('-', '').slice(0, 16)
  config.headers.set?.('X-Trace-ID', traceId)
  config.headers.set?.('X-User-Role', getStoredRole())
  if (!config.headers.set) {
    config.headers['X-Trace-ID'] = traceId
    config.headers['X-User-Role'] = getStoredRole()
  }
  localStorage.setItem('pending_trace_id', traceId)

  const revokedAt = localStorage.getItem('privacy_revoked_at')
  if (revokedAt && config.url?.includes('/api/assessment/')) {
   // ElMessage.warning('您已撤回隐私授权，系统不再收集学习数据')
    return Promise.reject(new Error('Privacy consent revoked'))
  }

  return config
})

service.interceptors.response.use(
  (response) => {
    const traceId = response.headers['x-trace-id'] || response.headers['X-Trace-ID']
    const responseTime = response.headers['x-response-time'] || response.headers['X-Response-Time']
    if (traceId) localStorage.setItem('last_trace_id', String(traceId))
    if (responseTime) localStorage.setItem('last_response_time', String(responseTime))
    return response
  },
  (error: AxiosError<{ detail?: string; message?: string; trace_id?: string }>) => {
    const response = error.response
    const config = error.config as (AxiosRequestConfig & { __retryCount?: number }) | undefined
    const traceId = response?.headers?.['x-trace-id'] || response?.data?.trace_id || localStorage.getItem('last_trace_id') || 'unknown'

    if (response?.status === 400) {
    //  ElMessage.error(response.data?.detail || response.data?.message || '请求参数错误，请检查表单内容')
    }

    if (response?.status === 403) {
      //ElMessage.error(`当前角色无法访问该资源 [trace: ${traceId}]`)
      if (window.location.pathname !== '/403') window.location.href = `/403?from=${encodeURIComponent(window.location.pathname)}`
    }

    if (response?.status === 429 && config) {
      config.__retryCount = config.__retryCount || 0
      if (config.__retryCount < 3) {
        config.__retryCount += 1
        const delay = 1000 * 2 ** (config.__retryCount - 1)
        //ElMessage.warning(`请求过于频繁，${delay / 1000}秒后自动重试...`)
        return new Promise((resolve) => {
          window.setTimeout(() => resolve(service(config)), delay)
        })
      }
     // ElMessage.error(`请求过于频繁，请稍后再试 [trace: ${traceId}]`)
    }

    if (response?.status === 413) {
     // ElMessage.error('数据过大，请拆分批次')
    }

    if (response?.status === 500) {
      ElNotification.error({
       // title: '服务繁忙',
        //message: `trace_id: ${traceId}，请截图反馈给后端同学`,
        duration: 8000,
      })
    }

    if (response?.status === 503) {
      //ElMessage.info('系统初始化中，请稍候...')
    }

    return Promise.reject(error)
  },
)

export async function request<T>(config: AxiosRequestConfig): Promise<T> {
  const response = await service.request<T>(config)
  return response.data
}

export default service
