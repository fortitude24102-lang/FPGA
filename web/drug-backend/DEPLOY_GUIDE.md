# 🚀 后端部署运行指南

## 一、环境准备

### 1. 确认Python版本
```bash
python --version
# 需要 Python 3.8+
```

### 2. 创建虚拟环境（推荐）
```bash
# 进入项目目录
cd drug-backend/

# 创建虚拟环境
python -m venv venv

# 激活虚拟环境
# Windows:
venv\Scripts\activate
# macOS/Linux:
source venv/bin/activate
```

## 二、安装依赖

```bash
pip install -r requirements.txt
```

如果安装较慢，使用国内镜像：
```bash
pip install -r requirements.txt -i https://pypi.tuna.tsinghua.edu.cn/simple
```

## 三、启动后端服务

### 方式1：直接启动（开发模式）
```bash
python main.py
```

### 方式2：使用uvicorn直接启动
```bash
uvicorn main:app --reload --host 0.0.0.0 --port 8000
```

### 方式3：生产模式启动
```bash
uvicorn main:app --host 0.0.0.0 --port 8000 --workers 4
```

启动成功后你会看到：
```
============================================================
AI药物分子智能决策辅助系统 后端服务 v2.0
5-Agent协同架构: Analyzer -> Planner -> Generator -> Reviewer -> Learner
============================================================
服务地址: http://0.0.0.0:8000
API文档: http://0.0.0.0:8000/docs
============================================================
```

## 四、验证服务

### 1. 浏览器访问API文档
打开浏览器访问：`http://localhost:8000/docs`

你应该能看到Swagger UI界面，里面有所有API接口的说明。

### 2. 运行测试脚本
```bash
python test.py
```

如果全部通过，显示：
```
🎉 所有测试通过！后端服务运行正常！
```

### 3. 手动测试核心接口

使用curl或Postman测试：

```bash
curl -X POST http://localhost:8000/api/v1/pipeline   -H "Content-Type: application/json"   -d '{
    "name": "张三",
    "institution": "某某大学",
    "research_field": "抗肿瘤药物",
    "target_protein": "EGFR",
    "experience_level": "中级"
  }'
```

## 五、与前端联调

### 1. 确认后端地址
前端需要连接：`http://localhost:8000`

### 2. 确认CORS已开启
代码中已配置 `allow_origins=["*"]`，前端可以直接调用。

### 3. 前端调用示例

把 `frontend_examples/api.js` 复制到前端项目的 `src/` 目录下：

```javascript
import { api } from './api.js';

// 执行Pipeline
const result = await api.runPipeline({
  name: "张三",
  institution: "某某大学",
  research_field: "抗肿瘤药物",
  target_protein: "EGFR",
  experience_level: "中级"
});

console.log(result.data);
```

## 六、常见问题

### Q1: RDKit安装失败
**解决**：RDKit在某些系统上安装较复杂，可以尝试：
```bash
# 使用conda安装（推荐）
conda install -c conda-forge rdkit

# 或者只安装纯Python依赖（会回退到模拟数据）
pip install fastapi uvicorn pydantic
```

### Q2: 端口被占用
**解决**：
```bash
# 查找占用8000端口的进程
lsof -i :8000
# 或者修改main.py中的端口
```

### Q3: 前端无法连接
**解决**：
1. 确认后端服务已启动
2. 确认前端请求的地址正确 `http://localhost:8000`
3. 检查浏览器控制台是否有CORS错误

## 七、文件说明

| 文件 | 说明 |
|------|------|
| `main.py` | FastAPI主入口，所有API路由 |
| `config.py` | 配置文件 |
| `requirements.txt` | Python依赖列表 |
| `test.py` | 测试脚本 |
| `agents/analyzer.py` | 需求分析Agent |
| `agents/planner.py` | 策略规划Agent |
| `agents/generator.py` | 分子生成Agent |
| `agents/reviewer.py` | 审核裁判Agent |
| `agents/learner.py` | 反馈学习Agent |
| `agents/orchestrator.py` | 调度中枢 + FPGA客户端 |
| `frontend_examples/api.js` | 前端API封装 |
| `frontend_examples/*.vue` | Vue3组件示例 |

## 八、下一步

1. ✅ 确保后端能正常启动
2. ✅ 运行test.py全部通过
3. ➡️ 把 `api.js` 发给前端同学
4. ➡️ 前端同学按 `FRONTEND_INTEGRATION.md` 对接
5. ➡️ 联调测试
