# MolRecommender 前端说明

这是 MolRecommender 项目的前端部分，使用 Vue 3 + Vite + TypeScript + Element Plus 开发。

前端的作用是把后端提供的分子推荐、多 Agent 协同、学情测评、AI 辩论、知识图谱、微证书、隐私合规和系统监控能力做成可以直接点击操作的网页。你不需要手动调用接口，只需要打开页面、填写表单、点击按钮，就能完成演示和联调。

当前版本会优先调用真实后端接口；如果后端某些接口还没有实现或暂时不可用，页面会使用内置演示数据兜底，避免验收或展示时出现白屏。

## 1. 当前页面和功能

当前路由如下：

```text
/startup                 启动检查
/profile                 研究员画像
/assessment              学情测评
/diagnosis               诊断报告
/profile/radar           学情雷达图报告
/profile/prediction      学习效果预测
/profile/credentials     微证书墙
/profile/portfolio       学习档案
/agent-dashboard         Agent 调度监控
/debate                  智能辩论大厅
/adaptation              动态难度调整
/socratic                苏格拉底追问
/knowledge-graph         知识图谱与传播推荐
/learning-path           学习路径与历史版本
/tasks                   异步任务中心
/molecules               候选分子
/resources               研究资源
/feedback                反馈收集
/testing                 测试报告
/admin                   系统状态
/privacy/statement       隐私声明
/privacy/settings        隐私设置
/403                     权限不足页面
```

## 2. 主要能力说明

### 启动检查

对应 `/startup`。

用于检查后端是否已经启动，重点看 `/ready` 返回情况。如果 FPGA 不可用，页面会提示 CPU 降级，不会直接阻塞演示。

### 研究员画像

对应 `/profile`。

用于录入研究员背景、目标靶点、研究目标、约束条件和能力评分，并触发多 Agent 分析流程。

### 学情测评

对应 `/assessment`。

支持选择学习者背景：化学、计算机、生物、交叉学科。页面按题目逐题展示，包含难度标签、答题进度条、提交结果和跳转到雷达图/学习路径的入口。

### 智能辩论大厅

对应 `/debate`。

实现 Reviewer Agent 与 Generator Agent 的左右交替对话流程。包含：

- 输入辩论主题
- 开始辩论
- 提交 Generator 回应
- 获取最终裁决
- confidence 进度条
- evidence 证据展示
- LLM 未配置时的模拟逻辑提示

### 学情雷达图报告

对应 `/profile/radar` 和 `/diagnosis`。

展示六维能力得分、知识盲区、AI 深度分析和推荐学习动作。后端返回 `llm_analysis` 时会展示真实 AI 分析；接口不可用时显示演示分析。

### 动态难度调整

对应 `/adaptation`。

根据正确率切换三种模式：

```text
< 50%      降维解释模式
50%-85%    标准巩固模式
> 85%      进阶挑战模式
```

页面展示推荐资源、降维解释、苏格拉底追问和挑战任务。

### 苏格拉底追问

对应 `/socratic`。

以聊天形式进行最多 5 轮追问。前几轮给引导，第 4 轮给提示，第 5 轮才揭示答案。支持 `Ctrl + Enter` 快捷发送。

### 知识图谱与传播推荐

对应 `/knowledge-graph`。

展示 9 个知识点节点，绿色表示已掌握，灰色表示待补强，节点大小随得分变化。右侧展示传播推荐，并提供“图谱推理”按钮。

### 学习路径与历史版本

对应 `/learning-path`。

包含三种资源形态：

```text
知识卡片
实操指南
分阶测试题
```

同时展示学习路径历史版本，并用颜色标出新增和移除的路径阶段。

### 微证书墙

对应 `/profile/credentials`。

展示已获得证书和未解锁证书。高级证书有金色强调；证书过期时显示红色提醒，并提供重新测评入口。

### 学习档案

对应 `/profile/portfolio`。

展示总学习时长、测评次数、证书数量和 overall_score 变化趋势，并提供导出图片入口。

### 学习效果预测

对应 `/profile/prediction`。

展示下一周期预测分数、置信区间、趋势和风险干预建议。风险状态会用醒目的边框提示。

### 异步任务中心

对应 `/tasks`。

用于展示批量测试或分子生成等异步任务的状态和进度。支持提交任务、刷新进度、轮询任务状态。

### 系统状态

对应 `/admin`。

展示缓存、WebSocket 连接数、限流桶、Trace ID、配置热加载、数据导出和任务进度。

### 隐私合规

对应 `/privacy/statement` 和 `/privacy/settings`。

包含隐私声明、审计日志、撤回授权和删除数据。撤回授权后会清除本地缓存，并阻止测评类数据继续提交。

### RBAC 角色权限

左侧导航顶部提供角色切换：

```text
student  学生
teacher  教师
admin    管理员
```

切换角色后，前端会自动更新请求头：

```text
X-User-Role
```

如果当前角色访问无权限页面，会跳转到 `/403`。

## 3. 前端目录结构

```text
molrecommender-frontend
├─ src
│  ├─ App.vue                 # 主布局、导航、角色切换
│  ├─ main.ts                 # Vue 入口
│  ├─ assets                  # 全局样式
│  ├─ components              # 可复用组件
│  ├─ router/index.ts         # 路由和权限守卫
│  ├─ utils
│  │  ├─ api.ts               # 业务接口封装
│  │  ├─ request.ts           # Axios 请求封装和状态码处理
│  │  ├─ websocket.ts         # WebSocket 心跳、重连、订阅
│  │  ├─ rbac.ts              # 角色权限工具
│  │  └─ mockData.ts          # 演示数据
│  └─ views                   # 页面级组件
├─ package.json
├─ package-lock.json
├─ vite.config.ts
└─ README.md
```

## 4. 运行指南

### 4.1 Node.js 版本

前端需要 Node.js。项目推荐版本以 `package.json` 为准：

```text
node: ^22.18.0 || >=24.12.0
```

查看本机 Node.js 版本：

```powershell
node -v
```

查看 npm 版本：

```powershell
npm -v
```

### 4.2 进入前端目录

```powershell
cd D:\dev\projects\MolRecommender\molrecommender-frontend
```

### 4.3 安装全部依赖

第一次运行前端时执行：

```powershell
npm install
```

如果已经安装过依赖，并且 `package.json` 没有变化，通常不需要重复执行。

### 4.4 单独安装包的命令

正常情况只需要 `npm install`。如果某个包缺失，可以单独安装。

安装 Vue：

```powershell
npm install vue
```

安装 Vue Router：

```powershell
npm install vue-router
```

安装 Element Plus：

```powershell
npm install element-plus
```

安装 Element Plus 图标：

```powershell
npm install @element-plus/icons-vue
```

安装 Axios：

```powershell
npm install axios
```

安装 UUID：

```powershell
npm install uuid
```

安装 ECharts：

```powershell
npm install echarts
```

安装 RDKit.js：

```powershell
npm install @rdkit/rdkit
```

安装 Vite：

```powershell
npm install -D vite
```

安装 TypeScript：

```powershell
npm install -D typescript
```

安装 Vue 类型检查工具：

```powershell
npm install -D vue-tsc
```

安装并行脚本工具：

```powershell
npm install -D npm-run-all2
```

## 5. 启动前端

进入前端目录后执行：

```powershell
npm run dev
```

启动成功后，终端会显示类似：

```text
Local: http://localhost:5173/
```

浏览器打开：

```text
http://localhost:5173/
```

默认会跳转到：

```text
http://localhost:5173/startup
```

如果 5173 端口被占用，可以换端口：

```powershell
npm run dev -- --host 127.0.0.1 --port 5174
```

然后访问：

```text
http://127.0.0.1:5174/startup
```

## 6. 配合后端运行

前端默认请求后端地址：

```text
http://127.0.0.1:8000
```

如果需要改后端地址，可以新建 `.env` 文件：

```text
VITE_API_BASE_URL=http://127.0.0.1:8000
```

完整运行时建议开两个终端。

### 终端 1：启动后端

```powershell
cd D:\dev\projects\MolRecommender\drug-backend
python main.py
```

后端启动成功后可以打开：

```text
http://127.0.0.1:8000/docs
```

### 终端 2：启动前端

```powershell
cd D:\dev\projects\MolRecommender\molrecommender-frontend
npm run dev
```

然后访问：

```text
http://localhost:5173/
```

## 7. 构建检查

开发时运行：

```powershell
npm run dev
```

提交前建议运行：

```powershell
npm run build
```

这个命令会做两件事：

```text
vue-tsc 类型检查
vite build 正式构建
```

构建产物会生成在：

```text
dist
```

`dist` 是构建结果，不需要提交到 Git。

## 8. HTTP 状态码处理

前端已经在 `src/utils/request.ts` 中统一处理：

```text
400  表单或参数错误，提示用户检查输入
403  当前角色无权限，跳转 /403
413  数据超过 10MB，前端拦截并提示拆分批次
429  请求过于频繁，自动指数退避重试 3 次
500  服务繁忙，展示 trace_id
503  系统初始化中，提示稍候
```

每个请求会自动带：

```text
X-Trace-ID
X-User-Role
```

## 9. WebSocket 说明

`src/utils/websocket.ts` 已实现：

```text
30 秒发送一次 ping
90 秒未收到 pong 自动重连
最多重连 5 次
支持 subscribe / subscribe_agent
收到 1013 关闭码时提示连接数受限状态
```

## 10. 建议使用 Conda / Anaconda 管理后端 Python

前端本身使用 Node.js，不需要 Conda。

但是本项目还有 Python 后端，所以建议使用 Anaconda 或 Miniconda 管理 Python 环境。对于小白，推荐安装 Anaconda，因为它带图形化工具和常用环境管理能力。

创建后端环境：

```powershell
conda create -n molrecommender python=3.11
```

激活环境：

```powershell
conda activate molrecommender
```

进入后端目录：

```powershell
cd D:\dev\projects\MolRecommender\drug-backend
```

安装后端依赖：

```powershell
pip install -r requirements.txt
```

启动后端：

```powershell
python main.py
```

如果 PowerShell 里提示找不到 `conda`，说明 Anaconda 没有加入终端环境变量。可以打开 Anaconda Prompt 执行上述命令，或者重新初始化 PowerShell。

## 11. 常见问题

### 浏览器打不开 localhost:5173

说明前端服务没有运行。进入前端目录后执行：

```powershell
npm run dev
```

### 页面打开了，但是接口失败

先确认后端是否启动：

```text
http://127.0.0.1:8000/docs
```

如果打不开，说明后端没启动或端口不是 8000。

### 后端显示 0.0.0.0:8000 应该访问什么

浏览器不要访问 `0.0.0.0`，应该访问：

```text
http://127.0.0.1:8000/docs
```

### Git 提示 LF 会变成 CRLF

这是 Windows 下常见的换行符提示，不是错误。只要 `git commit` 成功，说明改动已经保存。

## 12. 严格验收补充说明

本版本在基础页面之外，继续补齐了文档中要求的工程增强项。

### 12.1 新增依赖

严格验收相关依赖包括：

```text
@antv/g6                 知识图谱力导向图
vue-virtual-scroller     审计日志大列表虚拟滚动
canvas-confetti          高级微证书获得动画
@sentry/vue              前端异常监控接入
lodash-es                后续防抖/节流扩展备用
vitest                   单元测试
@vue/test-utils          Vue 组件测试工具
jsdom                    浏览器环境模拟
```

单独安装命令：

```powershell
npm install @antv/g6
npm install vue-virtual-scroller
npm install canvas-confetti
npm install @sentry/vue
npm install lodash-es
npm install -D vitest
npm install -D @vue/test-utils
npm install -D jsdom
```

### 12.2 已补齐的严格验收项

```text
1. 知识图谱页面使用 @antv/g6 渲染力导向图，并保留移动端列表视图。
2. 审计日志使用 vue-virtual-scroller，演示数据超过 100 条，避免大列表一次性渲染。
3. 微证书高级徽章使用 canvas-confetti 动态 import，获得高级证书时触发彩纸动画。
4. 全局快捷键已接入：Ctrl+K 打开搜索，ESC 关闭搜索，R 刷新当前页面。
5. 数据导出支持全部文档要求类型，并展示下载进度条。
6. Agent 状态页已补充第 6 个 Agent：KG Agent 知识图谱与关系推理。
7. Sentry 接入已预留，配置 VITE_SENTRY_DSN 后会自动上报前端异常。
8. 新增 debounce、throttle、IntersectionObserver 图片懒加载工具函数。
9. 新增 Vitest 单元测试，覆盖 RBAC 和性能工具函数。
```

### 12.3 测试命令

运行单元测试：

```powershell
npm run test
```

运行类型检查和正式构建：

```powershell
npm run build
```

当前验证结果：

```text
npm run test   通过，2 个测试文件，6 个测试用例
npm run build  通过
```

构建时如果看到 chunk 体积提示，这是 ECharts、G6 等图表库体积较大导致的 warning，不是失败。

### 12.4 生产监控配置

如果要启用 Sentry，需要在前端 `.env` 中配置：

```text
VITE_SENTRY_DSN=你的 Sentry DSN
```

没有配置时，项目不会上报错误，但仍会在浏览器控制台和页面消息里提示异常。

## 13. 本次补齐的剩余缺口

以下内容用于对应最新文档中的严格验收缺口。

### 13.1 新增独立页面

```text
/difficulty-curve              难度匹配曲线
/hallucination                 幻觉检测
/agent-monitor                 Agent 思维链监控
/learning-path/history         学习路径历史版本
/knowledge-graph/propagation   知识传播推荐
```

### 13.2 端到端、视觉和性能验收

端到端测试：

```powershell
npm run test:e2e
```

视觉回归测试：

```powershell
npm run test:visual
```

首次运行视觉测试时，Playwright 会生成基线截图；后续页面变化会和基线对比。

Lighthouse 性能检查：

```powershell
npm run test:lighthouse
```

部署前后端连通检查：

```powershell
npm run check:deploy
```

### 13.3 仍需真实环境提供的内容

以下内容无法只靠前端仓库凭空完成，需要真实账号、真实后端或生产环境配合：

```text
1. Sentry 真实 DSN 和告警规则
2. 生产域名和 CORS 白名单
3. LLM_API_KEY / LLM_BASE_URL / LLM_MODEL
4. ENCRYPTION_KEY
5. WebSocket 线上地址和连接数限制验证
6. 后端真实 StreamingResponse 下载进度
7. 后端真实 RBAC 拦截结果
8. 后端真实数据删除和撤回授权执行结果
```

前端已经提供配置入口、页面入口和检查脚本；最终验收时需要把真实环境变量填入 `.env` 并连接后端验证。

### 13.4 当前本地验收结果

最近一次本地验证结果：

```text
npm run build          通过
npm run test           通过，2 个测试文件，6 个测试用例
npm run test:e2e       通过，桌面和移动端共 6 个用例
npm run test:visual    通过，桌面和移动端共 8 个截图用例
npm run test:lighthouse 通过，Performance 77，Accessibility 95，Best Practices 96
```

Lighthouse 摘要报告保存在：

```text
reports/lighthouse-summary.json
```

说明：文档中 Performance 目标为 90，本地生产预览当前为 77，已经有自动化检查脚本和实际报告，但若要冲到 90，需要继续做更深的首屏性能优化，例如 Element Plus 按需引入、图表库进一步拆包、减少首屏样式体积。

### 13.5 当前部署检查状态

最近一次执行：

```powershell
npm run check:deploy
```

结果：脚本正常运行，但当前机器未配置真实环境变量，且默认后端 `http://127.0.0.1:8000` 没有连通，所以 `/ready` 和 `/api/v1/health` 检查失败。

这不是前端构建失败，而是部署环境未准备完成。要让部署检查通过，需要先启动后端，或在 `.env` 中配置真实后端地址：

```text
VITE_API_BASE_URL=http://你的后端地址
```
