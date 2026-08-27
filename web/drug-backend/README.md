# MolRecommender 后端服务

> AI 药物分子设计平台 —— FastAPI 后端  
> 版本：v4.5 Ready-Fix Edition  
> 基于 v4.4 评审对齐版修复生产就绪问题

---

## 目录

- [项目结构](#项目结构)
- [快速开始](#快速开始)
- [环境配置](#环境配置)
- [核心功能](#核心功能)
- [API 文档](#api-文档)
- [生产部署](#生产部署)
- [开发指南](#开发指南)
- [故障排查](#故障排查)
- [版本历史](#版本历史)

---

## 项目结构

```
backend/
├── main.py                      # 主入口（当前为 main_v45_readyfix.py）
├── .env                         # 环境变量（从 .env.example 复制）
├── .env.example                 # 配置模板
├── requirements.txt             # Python 依赖
├── data/                        # 本地数据存储（JSON 文件）
│   ├── users.json
│   ├── users.json.lock          # 文件锁
│   ├── quiz_results.json
│   ├── tasks.json
│   ├── exports.json
│   ├── credentials.json
│   ├── learning_paths.json
│   └── audit.json
├── logs/                        # 日志目录
│   └── molrec.log
├── test_api.py                  # 回归测试脚本
├── llm_enhanced_patch.py        # LLM 增强补丁（已合并入主文件）
├── fpga_client.py               # FPGA 客户端（可选）
└── README.md                    # 本文件
```

---

## 快速开始

### 1. 环境要求

- Python 3.10+
- pip

### 2. 安装依赖

```bash
cd backend
pip install -r requirements.txt
```

**requirements.txt：**
```
fastapi>=0.110.0
uvicorn[standard]>=0.29.0
pydantic>=2.0.0
cryptography>=42.0.0
cachetools>=5.3.0
httpx>=0.27.0
numpy>=1.26.0
```

### 3. 配置环境

```bash
cp .env.example .env
# 编辑 .env，按需填写配置
```

**本地开发最小配置：**
```env
DEBUG=true
ENABLE_FPGA=false
```

其他配置项保持留空即可，后端会自动降级到模拟模式。

### 4. 启动服务

```bash
# 方式一：直接运行
python main.py

# 方式二：使用 uvicorn（推荐生产环境）
uvicorn main:app --host 0.0.0.0 --port 8000 --reload
```

服务启动后访问：
- API 文档：`http://127.0.0.1:8000/docs`
- 健康检查：`http://127.0.0.1:8000/api/v1/health`
- 就绪检查：`http://127.0.0.1:8000/ready`

---

## 环境配置

### 完整配置说明

| 变量 | 必填 | 默认值 | 说明 |
|------|------|--------|------|
| `HOST` | 否 | `0.0.0.0` | 服务监听地址 |
| `PORT` | 否 | `8000` | 服务端口 |
| `DEBUG` | 否 | `false` | 调试模式（影响日志级别、文档页、自动密钥） |
| `CORS_ORIGINS` | 否 | 见下方 | 前端跨域白名单，逗号分隔 |
| `LLM_API_KEY` | 否 | - | 大模型 API 密钥 |
| `LLM_BASE_URL` | 否 | - | 大模型 API 地址 |
| `LLM_MODEL` | 否 | - | 模型名称 |
| `LLM_MOCK_MODE` | 否 | `auto` | `auto`/`force_mock`/`force_real` |
| `ENCRYPTION_KEY` | 生产必填 | - | Fernet 加密密钥（32 字节 base64） |
| `ENABLE_FPGA` | 否 | `false` | 是否启用 FPGA |
| `FPGA_SERVICE_URL` | 条件必填 | - | FPGA 服务地址（ENABLE_FPGA=true 时必填） |
| `DATABASE_URL` | 否 | - | 数据库连接（预留） |
| `REDIS_URL` | 否 | - | Redis 连接（预留） |
| `RATE_LIMIT_RPS` | 否 | `10.0` | 每秒请求限流 |
| `MAX_BODY_MB` | 否 | `10` | 最大请求体（MB） |
| `LOG_FILE` | 否 | - | 日志文件路径 |

### CORS 白名单

```env
# 本地开发
CORS_ORIGINS=http://localhost:5173,http://127.0.0.1:5173

# 生产环境
CORS_ORIGINS=https://your-domain.com,https://www.your-domain.com
```

### LLM 配置示例

**DeepSeek：**
```env
LLM_API_KEY=sk-xxxxxxxxxxxxxxxx
LLM_BASE_URL=https://api.deepseek.com/v1
LLM_MODEL=deepseek-chat
```

**通义千问：**
```env
LLM_API_KEY=sk-xxxxxxxxxxxxxxxx
LLM_BASE_URL=https://dashscope.aliyuncs.com/compatible-mode/v1
LLM_MODEL=qwen-turbo
```

**本地 Ollama：**
```env
LLM_API_KEY=ollama
LLM_BASE_URL=http://localhost:11434/v1
LLM_MODEL=llama3
```

**无网络环境（强制 Mock）：**
```env
LLM_MOCK_MODE=force_mock
```

### 加密密钥生成

生产环境必须手动生成强随机密钥：

```bash
python -c "from cryptography.fernet import Fernet; print(Fernet.generate_key().decode())"
```

将输出填入 `.env`：
```env
ENCRYPTION_KEY=your-generated-key-here
```

> ⚠️ 开发环境（`DEBUG=true`）留空会自动生成派生密钥，但**不可用于生产**。

---

## 核心功能

### 六大核心模块（P0）

| 模块 | 接口 | 说明 |
|------|------|------|
| 辩论系统 | `POST /api/debate/start` | 启动辩论，LLM 生成正方观点 |
| | `POST /api/debate/{id}/respond` | 反方/正方交替回应 |
| | `POST /api/debate/{id}/verdict` | LLM 裁决 |
| 学情画像 | `GET /api/profile/radar` | 六维能力雷达图 |
| | `POST /api/profile/radar/llm` | LLM 智能分析建议 |
| 动态难度 | `GET /api/adapt/difficulty` | 基于历史表现推荐难度 |
| 苏格拉底问答 | `POST /api/socrates/ask` | 苏格拉底式引导 |
| 知识图谱 | `GET /api/kg/graph` | 获取图谱结构 |
| | `POST /api/kg/activate` | 节点激活与传播 |
| 测评系统 | `GET /api/quiz/questions` | 获取 54 题题库 |
| | `POST /api/quiz/submit` | 提交测评，自动颁发微证书 |

### 九大扩展功能（P1）

| 功能 | 接口 | 说明 |
|------|------|------|
| 幻觉检测 | `POST /api/hallucination/check` | 检测文本中的过度自信表述 |
| Agent 监控 | `GET /api/agents/status` | 查看各 Agent 状态 |
| 批量测试 | `POST /api/batch/test` | 批量处理接口 |
| 异步任务 | `POST /api/tasks/create` | 创建后台任务 |
| | `GET /api/tasks/{id}` | 查询任务进度 |
| | `POST /api/tasks/{id}/retry` | 失败任务重试 |
| 微证书 | `GET /api/credentials` | 查看已获证书 |
| 学习档案 | `GET /api/profile/archive` | 汇总所有学习数据 |
| 路径回溯 | `POST /api/profile/path` | 保存学习路径版本 |
| | `GET /api/profile/path/versions` | 查看历史版本 |
| 效果预测 | `GET /api/predict/performance` | 基于趋势预测下次得分 |
| 传播推荐 | `GET /api/recommend/peers` | 推荐学习伙伴 |

### 系统功能（P2）

| 功能 | 接口 | 说明 |
|------|------|------|
| 数据导出 | `POST /api/export` | 创建导出任务（JSON/CSV/Markdown） |
| | `GET /api/export/download/{file}` | 下载导出文件 |
| 隐私删除 | `POST /api/privacy/request` | 删除/撤回个人数据 |
| | `GET /api/privacy/audit` | 查看隐私审计日志（Admin） |
| 系统监控 | `GET /api/admin/status` | 运行时状态面板（Admin） |
| 配置热加载 | `POST /api/admin/reload-config` | 重新加载 .env（Admin） |
| FPGA 状态 | `GET /api/fpga/health` | FPGA 健康检查 |
| | `POST /api/fpga/tanimoto` | Tanimoto 相似度计算 |
| WebSocket | `ws://host:port/ws` | 实时推送（心跳/任务/Agent） |

---

## API 文档

启动服务后自动生成的交互式文档：

- **Swagger UI**：`http://127.0.0.1:8000/docs`
- **ReDoc**：`http://127.0.0.1:8000/redoc`

> 生产环境（`DEBUG=false`）自动关闭文档页面。

---

## 生产部署

### 部署检查清单

- [ ] `DEBUG=false`
- [ ] `ENCRYPTION_KEY` 已配置（手动生成，非自动）
- [ ] `ENABLE_FPGA=true` 且 `FPGA_SERVICE_URL` 可访问
- [ ] `LLM_API_KEY`、`LLM_BASE_URL`、`LLM_MODEL` 已配置真实服务
- [ ] `CORS_ORIGINS` 仅包含生产前端域名
- [ ] `LOG_FILE` 已配置
- [ ] `RATE_LIMIT_RPS` 根据服务器能力调整

### Docker 部署示例

```dockerfile
FROM python:3.11-slim

WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY . .
EXPOSE 8000

CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8000"]
```

```bash
docker build -t molrecommender-backend .
docker run -d -p 8000:8000 --env-file .env molrecommender-backend
```

### 使用 Gunicorn + Uvicorn Workers

```bash
gunicorn main:app -w 4 -k uvicorn.workers.UvicornWorker --bind 0.0.0.0:8000
```

---

## 开发指南

### 认证方式

当前为演示阶段，使用简单 Token 机制：

```bash
# 登录获取 token
curl -X POST http://localhost:8000/api/auth/login \
  -H "Content-Type: application/json" \
  -d '{"username":"test","role":"student"}'

# 返回：{"token": "student:test", "user": {...}}

# 后续请求携带 Header
X-User-Token: student:test
```

角色：`admin` / `teacher` / `student`

### WebSocket 使用

```javascript
const ws = new WebSocket('ws://127.0.0.1:8000/ws');

ws.onopen = () => {
  // 心跳
  ws.send(JSON.stringify({ action: 'ping' }));
  // 订阅任务
  ws.send(JSON.stringify({ action: 'subscribe_task', task_id: 'task-xxx' }));
  // 获取 Agent 状态
  ws.send(JSON.stringify({ action: 'agent_status' }));
};

ws.onmessage = (event) => {
  const msg = JSON.parse(event.data);
  console.log(msg.type, msg);
};
```

### 运行回归测试

```bash
python test_api.py
```

---

## 故障排查

### `/ready` 返回 503

```bash
curl http://127.0.0.1:8000/ready
```

| 失败项 | 原因 | 解决 |
|--------|------|------|
| `fpga: false` | `ENABLE_FPGA=true` 但未配置 `FPGA_SERVICE_URL` | 配置 URL 或设为 `false` |
| `encryption: false` | 生产环境未配置 `ENCRYPTION_KEY` | 生成并配置密钥 |

### CORS 报错

检查 `.env` 中的 `CORS_ORIGINS` 是否包含前端实际地址（包括协议、端口）。

### LLM 返回 Mock 响应

检查日志中的 `LLM_MOCK_MODE` 和配置状态。若处于 `auto` 模式且缺少任一配置项，会自动降级。

### `trace_id` 日志报错

v4.5 已修复。如仍出现，检查是否使用了旧版日志配置。

---

## 版本历史

| 版本 | 日期 | 主要变更 |
|------|------|----------|
| v4.5 | 2026-08-22 | 修复生产就绪检查（FPGA/加密开关、CORS、LLM Mock、trace_id 日志、WebSocket） |
| v4.4 | 2026-08-16 | 评审对齐版：学习效果预测、知识传播、独立 KG Agent、数据加密、RBAC、微证书、路径回溯、隐私删除、54 题题库 |
| v4.3 | 2026-08-15 | FPGA 接入、断点续传、健康检查增强 |
| v4.2 | 2026-08-08 | LLMClient 内联模块，辩论/画像/难度接入真实 LLM |
| v4.1 | 2026-08-15 | JSON 文件锁、trace_id、限流、热加载、数据导出、GZip、CORS 安全 |
| v4.0 | 2026-08-05 | 框架增强：原子写入、备份恢复、WebSocket 心跳、内存缓存、配置热加载 |
| v3.2 | 2026-07 | 初始版本：辩论、测评、雷达图、动态难度、苏格拉底、知识图谱 |

---

## 团队与贡献

- 后端：FastAPI + Python
- 前端：Vue3 + Element Plus + RDKit.js
- 硬件：FPGA（Verilog，Tanimoto 相似度加速）
- 算法：RDKit + LLM

---

> 项目截止：2026 年 9 月 5 日
