const apiBase = process.env.VITE_API_BASE_URL || 'http://127.0.0.1:8000'
const required = ['VITE_API_BASE_URL']
const optional = ['VITE_SENTRY_DSN', 'LLM_API_KEY', 'LLM_BASE_URL', 'LLM_MODEL', 'ENCRYPTION_KEY']

for (const key of required) {
  if (!process.env[key]) console.warn(`[warn] ${key} 未配置，将使用默认值`)
}
for (const key of optional) {
  if (!process.env[key]) console.warn(`[warn] ${key} 未配置，对应能力需要真实环境补充`)
}

async function check(path) {
  try {
    const res = await fetch(`${apiBase}${path}`)
    console.log(`${path}: ${res.status}`)
    return res.ok
  } catch (error) {
    console.warn(`${path}: ${error.message}`)
    return false
  }
}

const ready = await check('/ready')
const health = await check('/api/v1/health')
if (!ready || !health) process.exitCode = 1
