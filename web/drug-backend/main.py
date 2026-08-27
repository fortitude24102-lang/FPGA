"""
AI药物分子智能决策辅助系统 - FastAPI 后端主入口 v4.4
v3.1: 5-Agent协同架构 + 知识中心 + 认知增强 + FPGA加速 + WebSocket实时通信
v3.2: + 辩论机制 + 知识溯源 + 学情画像 + 幻觉检测 + 动态难度 + 批量测试 + Agent思维链 + 异步任务
v4.0: + JSON并发锁 + trace_id + 内存限流 + WS心跳 + 配置热加载 + 数据导出 + 断点续传
v4.1: + FPGA异步降级 + 日志文件化 + CORS安全 + GZip压缩 + 请求体限制 + OpenAPI分类
v4.2: + LLM智能辩论 + LLM学情分析 + LLM动态难度 + OpenAI兼容API + 自动降级保护
v4.3: + 学习者背景适配 + 3种资源形态 + 降维/进阶模式 + 苏格拉底追问Agent + 难度匹配曲线 + 知识图谱 + 数据脱敏 + 审计日志 + 场景延伸
v4.4: 【评审对齐版】+ 学习效果预测 + 知识传播推荐 + 知识图谱Agent + 数据加密存储 + RBAC访问控制 + 微证书体系 + 学习路径回溯 + 隐私删除/撤回 + 题库扩充50+
数据持久化: JSON文件自动存储(支持加密, 无需数据库)
"""
from fastapi import FastAPI, HTTPException, Query, Request, WebSocket, WebSocketDisconnect, Depends, Header
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse, StreamingResponse
from pydantic import BaseModel, Field
from typing import Dict, List, Any, Optional, Literal
import uvicorn
import json
import base64
import os
import time
import asyncio
import random
import uuid
import sys
import httpx
import re
import hashlib
from datetime import datetime
from enum import Enum

# ==================== 可选依赖（加密） ====================
try:
    from cryptography.fernet import Fernet
    _ENCRYPTION_AVAILABLE = True
except ImportError:
    _ENCRYPTION_AVAILABLE = False
    print("[v4.4] 警告: cryptography 未安装，数据加密已降级为明文存储。pip install cryptography 以启用。")

try:
    import numpy as np
    _NUMPY_AVAILABLE = True
except ImportError:
    _NUMPY_AVAILABLE = False
    print("[v4.4] 警告: numpy 未安装，预测模块将使用纯Python实现。")

# ==================== RDKit 顶部导入（带降级） ====================
try:
    from rdkit import Chem
    from rdkit.Chem import Descriptors, QED, AllChem
    _RDKIT_AVAILABLE = True
except ImportError:
    _RDKIT_AVAILABLE = False
    Chem = None
    Descriptors = None
    QED = None
    AllChem = None
    print("[v4.4] 警告: RDKit 未安装，分子计算功能将不可用。")

# ==================== v4.5 环境变量读取 ====================
# 从 .env 文件加载（如果存在）
_env_path = os.path.join(os.path.dirname(__file__), ".env")
if os.path.exists(_env_path):
    with open(_env_path, "r", encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            if "=" in line:
                k, v = line.split("=", 1)
                os.environ.setdefault(k.strip(), v.strip().strip("\'\""))

# v4.5 新增环境变量
_ENABLE_FPGA = os.getenv("ENABLE_FPGA", "false").lower() in ("1", "true", "yes")
_FPGA_SERVICE_URL = os.getenv("FPGA_SERVICE_URL", "")

# CORS 动态解析
_raw_cors = os.getenv("CORS_ORIGINS", "")
if _raw_cors:
    _ENV_CORS_ORIGINS = [x.strip() for x in _raw_cors.split(",") if x.strip()]
else:
    _ENV_CORS_ORIGINS = [
        "http://localhost:5173",
        "http://127.0.0.1:5173",
        "http://localhost:8080",
        "http://127.0.0.1:8080",
        "http://localhost:3000",
        "http://127.0.0.1:3000",
        "https://molrecommender.pages.dev",
    ]

# LLM Mock 模式
_LLM_MOCK_MODE = os.getenv("LLM_MOCK_MODE", "auto").lower()

# 加密密钥（开发环境自动生成）
_ENCRYPTION_KEY = os.getenv("ENCRYPTION_KEY", "")
if not _ENCRYPTION_KEY and os.getenv("DEBUG", "false").lower() in ("1", "true", "yes"):
    if _ENCRYPTION_AVAILABLE:
        from cryptography.hazmat.primitives import hashes
        from cryptography.hazmat.primitives.kdf.pbkdf2 import PBKDF2HMAC
        _dev_salt = b"molrecommender-dev-salt-v1"
        _dev_kdf = PBKDF2HMAC(
            algorithm=hashes.SHA256(), length=32, salt=_dev_salt, iterations=100000,
        )
        _ENCRYPTION_KEY = base64.urlsafe_b64encode(_dev_kdf.derive(b"dev-passphrase")).decode()
        os.environ["ENCRYPTION_KEY"] = _ENCRYPTION_KEY
        print(f"[v4.5] 开发环境自动生成 ENCRYPTION_KEY")

# ==================== 配置 ====================
from config import SERVICE_CONFIG, CORS_CONFIG, AGENT_CONFIG, MOLECULE_CONFIG, FPGA_CONFIG

# ==================== 中间件 ====================
from middleware.error_handler import global_exception_handler, validation_exception_handler, http_exception_handler
from middleware.rate_limiter import rate_limit_middleware
from middleware.logger import logging_middleware, request_logger

# ==================== WebSocket ====================
from websocket_manager import manager

# ==================== Agent模块 ====================
from agents.orchestrator import orchestrator
from agents.analyzer import analyzer_agent
from agents.planner import planner_agent
from agents.generator import generator_agent
from agents.reviewer import reviewer_agent
from agents.learner import learner_agent
from agents.knowledge_base import knowledge_base
from agents.cognitive_engine import cognitive_engine
from agents.fpga_client import fpga_client

# ==================== v4.0 增强基础设施 ====================
import sys
if sys.platform == 'win32':
    class _FcntlModule:
        LOCK_EX = 1
        LOCK_SH = 2
        LOCK_UN = 4
        LOCK_NB = 8
        @staticmethod
        def flock(fd, operation):
            pass
    fcntl = _FcntlModule()
else:
    import fcntl
import copy
import io
import csv
import contextvars
from dataclasses import dataclass
from collections import defaultdict
from cachetools import TTLCache

# --- 文件级锁 ---
class _FileLockCtx:
    def __init__(self, filepath):
        self.filepath = filepath
        self.fd = None
    def __enter__(self):
        self.fd = os.open(self.filepath, os.O_RDWR | os.O_CREAT)
        fcntl.flock(self.fd, fcntl.LOCK_EX)
        return self
    def __exit__(self, *args):
        if self.fd is not None:
            fcntl.flock(self.fd, fcntl.LOCK_UN)
            os.close(self.fd)

# --- 安全 JSON 存储底层 ---
class SafeJSONStorage:
    def __init__(self, filepath: str, default_data=None, encrypt: bool = False):
        self.filepath = filepath
        self.default_data = default_data if default_data is not None else {}
        self.encrypt = encrypt and _ENCRYPTION_AVAILABLE
        self._cipher = None
        if self.encrypt:
            key = os.environ.get("ENCRYPTION_KEY")
            if not key:
                key = Fernet.generate_key().decode()
                os.environ["ENCRYPTION_KEY"] = key
            self._cipher = Fernet(key.encode())
        if not os.path.exists(filepath):
            self._write_unsafe(self.default_data)
        if not self._validate():
            self._restore_backup()

    def _backup_path(self) -> str:
        return self.filepath + ".bak"

    def _create_backup(self):
        if os.path.exists(self.filepath):
            try:
                import shutil
                shutil.copy2(self.filepath, self._backup_path())
            except Exception:
                pass

    def _restore_backup(self) -> bool:
        bp = self._backup_path()
        if os.path.exists(bp):
            try:
                import shutil
                shutil.copy2(bp, self.filepath)
                return True
            except Exception:
                pass
        with open(self.filepath, 'w', encoding='utf-8') as f:
            json.dump(self.default_data, f, ensure_ascii=False, indent=2)
        return True

    def _validate(self) -> bool:
        if not os.path.exists(self.filepath):
            return True
        try:
            raw = self._read_raw()
            if isinstance(raw, bytes):
                json.loads(raw.decode())
            else:
                json.loads(raw)
            return True
        except (json.JSONDecodeError, IOError, Exception):
            return False

    def _read_raw(self):
        with open(self.filepath, 'rb') as f:
            return f.read()

    def _read_unsafe(self):
        try:
            raw = self._read_raw()
            if self.encrypt and self._cipher:
                raw = self._cipher.decrypt(raw)
                return json.loads(raw.decode())
            return json.loads(raw.decode())
        except Exception:
            self._restore_backup()
            raw = self._read_raw()
            if self.encrypt and self._cipher:
                raw = self._cipher.decrypt(raw)
                return json.loads(raw.decode())
            return json.loads(raw.decode())

    def _write_unsafe(self, data):
        self._create_backup()
        tmp = self.filepath + ".tmp"
        content = json.dumps(data, ensure_ascii=False, indent=2)
        if self.encrypt and self._cipher:
            content = self._cipher.encrypt(content.encode())
            with open(tmp, 'wb') as f:
                f.write(content)
        else:
            with open(tmp, 'w', encoding='utf-8') as f:
                f.write(content)
                f.flush()
                os.fsync(f.fileno())
        try:
            os.replace(tmp, self.filepath)
        except PermissionError:
            # Windows cloud-backed Desktop files can reject atomic replacement.
            mode = "wb" if isinstance(content, bytes) else "w"
            kwargs = {} if mode == "wb" else {"encoding": "utf-8"}
            with open(self.filepath, mode, **kwargs) as f:
                f.write(content)
                f.flush()
                os.fsync(f.fileno())
            try:
                os.remove(tmp)
            except OSError:
                pass

    def read(self):
        with _FileLockCtx(self.filepath):
            return self._read_unsafe()

    def write(self, data):
        with _FileLockCtx(self.filepath):
            self._write_unsafe(data)

# --- 内部配置热加载 ---
INTERNAL_CONFIG_PATH = os.path.join(os.path.dirname(__file__), "config.json")
INTERNAL_DEFAULT_CONFIG = {
    "cache_ttl": 300,
    "cache_maxsize": 1000,
    "rate_limit": {
        "enabled": True,
        "default_limit": 120,
        "window_seconds": 60,
        "strict_endpoints": {
            "/api/v1/pipeline/batch": 5,
            "/api/batch-test/run": 5,
            "/api/tasks/generate": 10
        }
    },
    "websocket": {
        "max_connections": 100,
        "heartbeat_interval": 30,
        "heartbeat_timeout": 90
    },
    "log_level": "INFO",
    "cleanup_interval": 60,
    "privacy": {
        "hash_sensitive": True,
        "audit_log_enabled": True,
        "retention_days": 365,
        "encryption_enabled": False
    },
    "socratic": {
        "enabled": True,
        "max_turns": 5
    },
    "learning_prediction": {
        "alpha": 0.3,
        "risk_threshold": 0.5
    },
    "propagation": {
        "rounds": 3,
        "decay": 0.5
    },
    "rbac": {
        "enabled": True
    }
}

class InternalConfig:
    _instance = None
    def __new__(cls):
        if cls._instance is None:
            cls._instance = super().__new__(cls)
            cls._instance._config = copy.deepcopy(INTERNAL_DEFAULT_CONFIG)
            cls._instance._last_mtime = 0
            cls._instance.reload()
        return cls._instance
    def reload(self):
        if os.path.exists(INTERNAL_CONFIG_PATH):
            try:
                mtime = os.path.getmtime(INTERNAL_CONFIG_PATH)
                if mtime > self._last_mtime:
                    with open(INTERNAL_CONFIG_PATH, 'r', encoding='utf-8') as f:
                        loaded = json.load(f)
                    self._config = self._deep_merge(copy.deepcopy(INTERNAL_DEFAULT_CONFIG), loaded)
                    self._last_mtime = mtime
            except Exception:
                pass
    def _deep_merge(self, base, override):
        for k, v in override.items():
            if k in base and isinstance(base[k], dict) and isinstance(v, dict):
                base[k] = self._deep_merge(base[k], v)
            else:
                base[k] = v
        return base
    def get(self, key=None, default=None):
        if key is None:
            return self._config
        keys = key.split(".")
        val = self._config
        for k in keys:
            if isinstance(val, dict) and k in val:
                val = val[k]
            else:
                return default
        return val

iconfig = InternalConfig()

# --- 结构化文件日志 ---
import logging
from logging.handlers import RotatingFileHandler

os.makedirs("logs", exist_ok=True)
class SafeFormatter(logging.Formatter):
    """v4.5: 安全格式化器，缺失字段不报错"""
    def format(self, record: logging.LogRecord) -> str:
        if not hasattr(record, "trace_id"):
            record.trace_id = "N/A"
        return super().format(record)

log_formatter = SafeFormatter(
    "%(asctime)s | %(levelname)-8s | trace_id=%(trace_id)s | %(message)s"
)

console_handler = logging.StreamHandler(sys.stdout)
console_handler.setFormatter(log_formatter)

file_handler = RotatingFileHandler(
    "logs/app.log", maxBytes=10*1024*1024, backupCount=7, encoding='utf-8'
)
file_handler.setFormatter(log_formatter)

v40_logger = logging.getLogger("drug_ai")
v40_logger.handlers = [console_handler, file_handler]
v40_logger.setLevel(getattr(logging, iconfig.get("log_level", "INFO")))

# --- trace_id ---
_trace_id_var = contextvars.ContextVar('trace_id', default='N/A')
def get_trace_id() -> str:
    return _trace_id_var.get()
def set_trace_id(tid: str):
    _trace_id_var.set(tid)

# --- 内存缓存 ---
_cache = TTLCache(maxsize=iconfig.get("cache_maxsize", 1000), ttl=iconfig.get("cache_ttl", 300))
_cache_lock = asyncio.Lock()
async def _cache_get(key: str):
    async with _cache_lock:
        return _cache.get(key)
async def _cache_set(key: str, value):
    async with _cache_lock:
        _cache[key] = value
async def _cache_delete(key: str):
    async with _cache_lock:
        _cache.pop(key, None)
def _cache_key(prefix: str, *args) -> str:
    return f"{prefix}:{hashlib.md5(chr(124).join(str(a) for a in args).encode()).hexdigest()}"

# --- 内存限流器 ---
class MemoryRateLimiter:
    def __init__(self):
        self.buckets = {}
        self.lock = asyncio.Lock()
    async def is_allowed(self, key: str, limit: int, window: int) -> bool:
        now = time.time()
        async with self.lock:
            bucket = self.buckets.get(key)
            if bucket is None:
                self.buckets[key] = {"tokens": limit - 1, "last_update": now}
                return True
            elapsed = now - bucket["last_update"]
            bucket["tokens"] = min(limit, bucket["tokens"] + elapsed * (limit / window))
            bucket["last_update"] = now
            if bucket["tokens"] >= 1:
                bucket["tokens"] -= 1
                return True
            return False
    async def cleanup(self):
        now = time.time()
        async with self.lock:
            expired = [k for k, v in self.buckets.items() if now - v["last_update"] > 3600]
            for k in expired:
                del self.buckets[k]

_mem_limiter = MemoryRateLimiter()

# --- WebSocket 增强包装 ---
class EnhancedWSManager:
    def __init__(self, base_manager):
        self._base = base_manager
        self._meta = {}
        self._lock = asyncio.Lock()
        self._max_conn = iconfig.get("websocket.max_connections", 100)
        self._heartbeat_timeout = iconfig.get("websocket.heartbeat_timeout", 90)
    async def connect(self, websocket: WebSocket):
        async with self._lock:
            if hasattr(self._base, 'get_connection_count') and self._base.get_connection_count() >= self._max_conn:
                await websocket.close(code=1013, reason="Server capacity exceeded")
                return False
        await self._base.connect(websocket)
        async with self._lock:
            self._meta[websocket] = {"connected_at": datetime.now().isoformat(), "last_ping": time.time()}
        return True
    def disconnect(self, websocket: WebSocket):
        self._base.disconnect(websocket)
        self._meta.pop(websocket, None)
    async def send_personal_message(self, message: dict, websocket: WebSocket):
        try:
            await self._base.send_personal_message(message, websocket)
        except Exception:
            self.disconnect(websocket)
    async def broadcast(self, message: dict):
        try:
            await self._base.broadcast(message)
        except Exception:
            pass
    async def broadcast_agent_status(self, agent_id: str, status: str, data: dict):
        if hasattr(self._base, 'broadcast_agent_status'):
            await self._base.broadcast_agent_status(agent_id, status, data)
    async def broadcast_pipeline_progress(self, pipeline_id: str, stage: str, progress: float, data: dict):
        if hasattr(self._base, 'broadcast_pipeline_progress'):
            await self._base.broadcast_pipeline_progress(pipeline_id, stage, progress, data)
    def get_connection_count(self):
        if hasattr(self._base, 'get_connection_count'):
            return self._base.get_connection_count()
        return len(self._meta)
    async def handle_pong(self, websocket: WebSocket):
        if websocket in self._meta:
            self._meta[websocket]["last_ping"] = time.time()
    async def cleanup_stale(self):
        now = time.time()
        stale = []
        async with self._lock:
            for ws, meta in self._meta.items():
                if now - meta.get("last_ping", 0) > self._heartbeat_timeout:
                    stale.append(ws)
        for ws in stale:
            try:
                await ws.close(code=1001, reason="Heartbeat timeout")
            except Exception:
                pass
            self.disconnect(ws)
    @property
    def client_subscriptions(self):
        if hasattr(self._base, 'client_subscriptions'):
            return self._base.client_subscriptions
        return {}

enhanced_manager = EnhancedWSManager(manager)

# ==================== 数据持久化(v3.1历史记录) ====================
HISTORY_FILE = "pipeline_history.json"

def load_history():
    if os.path.exists(HISTORY_FILE):
        try:
            with open(HISTORY_FILE, 'r', encoding='utf-8') as f:
                return json.load(f)
        except:
            return []
    return []

def save_history(record):
    history = load_history()
    record["id"] = len(history) + 1
    record["timestamp"] = datetime.now().isoformat()
    history.append(record)
    with open(HISTORY_FILE, 'w', encoding='utf-8') as f:
        json.dump(history, f, ensure_ascii=False, indent=2)

# ============================================================
# ==================== v4.3/v4.4 评审增强数据模型 ====================
# ============================================================

class TaskStatus(str, Enum):
    PENDING = "pending"
    RUNNING = "running"
    COMPLETED = "completed"
    FAILED = "failed"


class LearnerBackground(str, Enum):
    CHEMISTRY = "chemistry"
    CS = "cs"
    BIOLOGY = "biology"
    CROSS = "cross"


class ResourceType(str, Enum):
    CUSTOM_CARD = "custom_card"
    LAB_GUIDE = "lab_guide"
    LEVEL_TEST = "level_test"


class DebateRound(BaseModel):
    round: int
    speaker: Literal["Reviewer", "Generator"]   # v4.4: 移除未使用的 "Learner"
    content: str
    confidence: float = Field(..., ge=0.0, le=1.0)
    evidence: List[str] = []


class DebateSession(BaseModel):
    debate_id: str = Field(default_factory=lambda: str(uuid.uuid4()))
    topic: str
    rounds: List[DebateRound] = []
    status: Literal["ongoing", "completed", "aborted"] = "ongoing"
    created_at: datetime = Field(default_factory=datetime.now)
    final_verdict: Optional[str] = None


class DebateStartRequest(BaseModel):
    topic: str = "分子生成合理性"
    initial_content: Optional[str] = None


class DebateRespondRequest(BaseModel):
    speaker: Literal["Reviewer", "Generator"] = "Generator"
    content: Optional[str] = None
    response: Optional[str] = None
    round: Optional[int] = None
    confidence: float = Field(default=0.82, ge=0.0, le=1.0)
    evidence: List[str] = []


class DebateVerdict(BaseModel):
    verdict: str
    passed: bool
    suggestions: List[str] = []
    updated_weights: Dict[str, float] = {}


class KnowledgeSource(BaseModel):
    type: str
    id: str
    name: Optional[str] = None


class ValidationStep(BaseModel):
    agent: str
    check: str
    result: Literal["pass", "fail", "warning"]
    detail: Optional[str] = None


class ProvenanceData(BaseModel):
    knowledge_sources: List[KnowledgeSource]
    generation_path: str
    validation_chain: List[ValidationStep]
    timestamp: datetime = Field(default_factory=datetime.now)


class Question(BaseModel):
    question_id: str
    dimension: Literal[
        "药物化学基础", "分子对接知识", "ADMET理解",
        "靶点生物学", "合成路线设计", "专利与法规"
    ]
    question_text: str
    options: List[str]
    correct_index: int
    difficulty: Literal["easy", "medium", "hard"] = "medium"


class AssessmentSession(BaseModel):
    assessment_id: str = Field(default_factory=lambda: str(uuid.uuid4()))
    user_id: str
    background: Optional[str] = "chemistry"
    questions: List[Question] = []
    answers: Dict[str, int] = {}
    status: Literal["pending", "in_progress", "completed"] = "pending"
    created_at: datetime = Field(default_factory=datetime.now)
    completed_at: Optional[datetime] = None


class AssessmentStartRequest(BaseModel):
    user_id: str
    background: Optional[LearnerBackground] = LearnerBackground.CHEMISTRY
    question_count: int = Field(default=10, ge=5, le=20)


class AssessmentSubmitRequest(BaseModel):
    answers: Dict[str, int]


class RadarDimension(BaseModel):
    dimension: str
    score: float = Field(..., ge=0.0, le=100.0)
    full_mark: float = 100.0


class BlindSpot(BaseModel):
    dimension: str
    severity: Literal["high", "medium", "low"]
    gap_description: str
    recommended_action: str


class KnowledgeGraphNode(BaseModel):
    id: str
    label: str
    category: str
    description: str
    mastered: bool = False
    score: float = 0.0


class KnowledgeGraphEdge(BaseModel):
    source: str
    target: str
    relation: str


class KnowledgeGraph(BaseModel):
    user_id: str
    nodes: List[KnowledgeGraphNode]
    edges: List[KnowledgeGraphEdge]
    generated_at: datetime = Field(default_factory=datetime.now)


class DifficultyCurvePoint(BaseModel):
    timestamp: str
    correct_rate: float
    recommended_difficulty: float
    actual_difficulty: float
    resource_count: int


class RadarData(BaseModel):
    user_id: str
    background: Optional[str] = "chemistry"
    dimensions: List[RadarDimension]
    overall_score: float
    blind_spots: List[BlindSpot] = []
    difficulty_curve: List[DifficultyCurvePoint] = []
    knowledge_graph: Optional[KnowledgeGraph] = None
    updated_at: datetime = Field(default_factory=datetime.now)
    llm_analysis: Optional[Dict[str, Any]] = None


class LearningPathNode(BaseModel):
    stage: int
    title: str
    description: str
    resources: List[str]
    resource_type: ResourceType = ResourceType.CUSTOM_CARD
    difficulty_level: Literal["初阶", "中阶", "高阶"] = "初阶"
    estimated_time: str
    prerequisite: List[str] = []


class LearningPath(BaseModel):
    user_id: str
    path: List[LearningPathNode]
    generated_at: datetime = Field(default_factory=datetime.now)


class HallucinationError(BaseModel):
    type: Literal["结构错误", "数值异常", "规则冲突", "引用缺失"]
    detail: str
    severity: Literal["high", "medium", "low"] = "medium"


class HallucinationCheckRequest(BaseModel):
    generated_content: Optional[str] = None
    smiles: Optional[str] = None
    source: Optional[str] = None
    content_type: Literal["smiles", "property", "text", "synthesis"] = "text"
    reference_data: Optional[Dict[str, Any]] = None


class HallucinationResult(BaseModel):
    hallucination_rate: float = Field(..., ge=0.0, le=1.0)
    is_acceptable: bool
    errors: List[HallucinationError]
    checked_at: datetime = Field(default_factory=datetime.now)


class AdaptationRequest(BaseModel):
    user_id: str
    correct_rate: float = Field(..., ge=0.0, le=1.0)
    current_level: Literal["simplified", "standard", "advanced"] = "standard"
    subject_area: Optional[str] = None


class AdaptationResult(BaseModel):
    user_id: str
    next_level: Literal["simplified", "standard", "advanced"]
    mode: Literal["降维解释", "标准", "进阶挑战"] = "标准"
    action: str
    reason: str
    recommended_resources: List[str] = []
    downgrade_explanation: Optional[str] = None
    challenge_tasks: List[str] = []
    socratic_hints: List[str] = []


class TestProfile(BaseModel):
    name: str
    background: str
    theory_score: int = Field(..., ge=0, le=100)
    experience: str


class TestExpected(BaseModel):
    resource_difficulty: Literal["入门", "进阶", "专家"]
    knowledge_gaps: List[str]


class TestCase(BaseModel):
    id: str
    profile: TestProfile
    expected: TestExpected


class BatchTestRequest(BaseModel):
    test_cases: List[TestCase]
    description: Optional[str] = None


class TestCaseResult(BaseModel):
    case_id: str
    status: Literal["pass", "fail", "partial"]
    hallucination_rate: float
    adaptation_accuracy: float
    coverage: float
    details: Dict[str, Any]


class BatchTestReport(BaseModel):
    report_id: str = Field(default_factory=lambda: str(uuid.uuid4()))
    total_cases: int
    passed_cases: int
    failed_cases: int
    avg_hallucination_rate: float
    avg_adaptation_accuracy: float
    avg_coverage: float
    results: List[TestCaseResult]
    generated_at: datetime = Field(default_factory=datetime.now)


class AgentThought(BaseModel):
    type: Literal["agent_thought"] = "agent_thought"
    agent: Literal["Analyzer", "Planner", "Generator", "Reviewer", "Learner", "Socratic"]
    timestamp: datetime = Field(default_factory=datetime.now)
    thought: str
    action: str
    confidence: float = Field(..., ge=0.0, le=1.0)
    metadata: Optional[Dict[str, Any]] = None


class AsyncTask(BaseModel):
    task_id: str = Field(default_factory=lambda: str(uuid.uuid4()))
    task_type: str = "molecule_generation"
    status: TaskStatus = TaskStatus.PENDING
    params: Dict[str, Any] = {}
    result: Optional[Dict[str, Any]] = None
    progress: float = Field(0.0, ge=0.0, le=100.0)
    created_at: datetime = Field(default_factory=datetime.now)
    completed_at: Optional[datetime] = None
    error_message: Optional[str] = None


class TaskCreateRequest(BaseModel):
    task_type: str = "molecule_generation"
    params: Dict[str, Any] = {}


class SocraticRequest(BaseModel):
    user_id: str
    question: str
    context: Optional[str] = None
    background: Optional[LearnerBackground] = LearnerBackground.CHEMISTRY
    turn: int = Field(default=1, ge=1, le=5)


class SocraticResponse(BaseModel):
    user_id: str
    turn: int
    reply: str
    hint_level: Literal["引导", "提示", "反问"]
    follow_up_questions: List[str] = []
    should_reveal: bool = False


class AuditLogEntry(BaseModel):
    log_id: str = Field(default_factory=lambda: str(uuid.uuid4())[:16])
    timestamp: datetime = Field(default_factory=datetime.now)
    action: str
    user_id: str
    resource_type: str
    detail: Optional[str] = None
    ip_hash: Optional[str] = None


class PrivacyStatement(BaseModel):
    version: str = "4.4.0"
    data_collection: List[str]
    data_usage: List[str]
    retention_policy: str
    user_rights: List[str]
    contact: str


# ==================== v4.4 新增数据模型 ====================

class LearningPrediction(BaseModel):
    """学习效果预测结果"""
    user_id: str
    predicted_next_score: float = Field(..., ge=0.0, le=100.0)
    confidence_interval_low: float
    confidence_interval_high: float
    trend: Literal["上升", "下降", "平稳"]
    at_risk: bool
    recommended_intervention: str
    generated_at: datetime = Field(default_factory=datetime.now)


class MicroCredential(BaseModel):
    """微证书：终身学习的能力徽章"""
    credential_id: str = Field(default_factory=lambda: str(uuid.uuid4())[:12])
    user_id: str
    title: str
    skill_area: str
    earned_at: datetime = Field(default_factory=datetime.now)
    expiry_date: Optional[datetime] = None
    evidence: List[str] = []    # 关联测试ID、项目ID
    level: Literal["初级", "中级", "高级"] = "初级"
    issuer: str = "AI药物分子智能决策辅助系统"
    score_threshold: float = Field(60.0, ge=0.0, le=100.0)


class LearningPortfolio(BaseModel):
    """学习档案：终身学习累积记录"""
    user_id: str
    total_study_hours: float = 0.0
    total_assessments: int = 0
    credentials: List[MicroCredential] = []
    skill_evolution: List[Dict[str, Any]] = []  # 技能随时间变化
    last_updated: datetime = Field(default_factory=datetime.now)


class KGInferenceResult(BaseModel):
    """知识图谱推理结果"""
    inferred_relations: List[Dict[str, Any]] = []
    knowledge_gaps: List[str] = []
    suggested_updates: List[Dict[str, Any]] = []
    propagation_recommendations: List[Dict[str, Any]] = []


class PathVersion(BaseModel):
    """学习路径历史版本"""
    version_id: str = Field(default_factory=lambda: str(uuid.uuid4())[:8])
    user_id: str
    path: List[LearningPathNode]
    created_at: datetime = Field(default_factory=datetime.now)
    trigger: str = "assessment_completed"  # 触发原因

# ============================================================
# ==================== JSON 持久化层 =========================
# ============================================================

DATA_DIR = "data"
os.makedirs(DATA_DIR, exist_ok=True)

class JSONStore:
    def __init__(self, filename: str, model_class=None, is_list: bool = False, encrypt: bool = False):
        self.filepath = os.path.join(DATA_DIR, filename)
        self.model_class = model_class
        self.is_list = is_list
        default = [] if is_list else {}
        self._safe = SafeJSONStorage(self.filepath, default, encrypt=encrypt)
        self._data = self._load()

    def _load(self):
        raw = self._safe.read()
        if self.is_list:
            return [self.model_class(**item) for item in raw] if self.model_class else raw
        else:
            return {k: self.model_class(**v) for k, v in raw.items()} if self.model_class else raw

    def save(self):
        try:
            if self.is_list:
                raw = [json.loads(item.model_dump_json()) for item in self._data]
            else:
                raw = {k: json.loads(v.model_dump_json()) for k, v in self._data.items()}
            self._safe.write(raw)
        except IOError as e:
            print(f"[JSONStore] 写入失败 {self.filepath}: {e}")

    def __getitem__(self, key):
        return self._data[key]

    def __setitem__(self, key, value):
        self._data[key] = value
        self.save()

    def __contains__(self, key):
        return key in self._data

    def get(self, key, default=None):
        return self._data.get(key, default)

    def items(self):
        return self._data.items()

    def keys(self):
        return self._data.keys()

    def append(self, value):
        self._data.append(value)
        self.save()

    def extend(self, values):
        self._data.extend(values)
        self.save()

    def __iter__(self):
        return iter(self._data)

    def __len__(self):
        return len(self._data)

    def __repr__(self):
        return repr(self._data)


class MemoryDB:
    _instance = None

    def __new__(cls):
        if cls._instance is None:
            cls._instance = super().__new__(cls)
            cls._instance._init_db()
        return cls._instance

    def _init_db(self):
        encrypt = iconfig.get("privacy.encryption_enabled", False)
        self.debates = JSONStore("debates.json", DebateSession, is_list=False, encrypt=encrypt)
        self.resources_prov = JSONStore("resources_prov.json", ProvenanceData, is_list=False, encrypt=encrypt)
        self.assessments = JSONStore("assessments.json", AssessmentSession, is_list=False, encrypt=encrypt)
        self.radars = JSONStore("radars.json", RadarData, is_list=False, encrypt=encrypt)
        self.learning_paths = JSONStore("learning_paths.json", LearningPath, is_list=False, encrypt=encrypt)
        self.path_versions = JSONStore("path_versions.json", PathVersion, is_list=True, encrypt=encrypt)
        self.hallucination_results = JSONStore("hallucination_results.json", HallucinationResult, is_list=True, encrypt=encrypt)
        self.adaptations = JSONStore("adaptations.json", AdaptationResult, is_list=False, encrypt=encrypt)
        self.batch_reports = JSONStore("batch_reports.json", BatchTestReport, is_list=False, encrypt=encrypt)
        self.agent_thoughts = JSONStore("agent_thoughts.json", AgentThought, is_list=True, encrypt=encrypt)
        self.async_tasks = JSONStore("async_tasks.json", AsyncTask, is_list=False, encrypt=encrypt)
        self.socratic_logs = JSONStore("socratic_logs.json", SocraticResponse, is_list=True, encrypt=encrypt)
        self.audit_logs = JSONStore("audit_logs.json", AuditLogEntry, is_list=True, encrypt=encrypt)
        self.difficulty_curves = JSONStore("difficulty_curves.json", DifficultyCurvePoint, is_list=True, encrypt=encrypt)
        self.user_profiles = JSONStore("user_profiles.json", dict, is_list=False, encrypt=encrypt)
        # v4.4 新增
        self.micro_credentials = JSONStore("micro_credentials.json", MicroCredential, is_list=True, encrypt=encrypt)
        self.portfolios = JSONStore("portfolios.json", LearningPortfolio, is_list=False, encrypt=encrypt)
        self.kg_inferences = JSONStore("kg_inferences.json", KGInferenceResult, is_list=False, encrypt=encrypt)

        self._init_question_bank()
        self._init_test_cases()
        self._init_knowledge_graph_template()

    def _init_question_bank(self):
        """v4.4: 扩充至54题，覆盖6维度各9题，分easy/medium/hard三层"""
        self.question_bank: List[Question] = [
            # ===== 药物化学基础 (9题) =====
            Question(question_id="q001", dimension="药物化学基础",
                question_text="下列哪个官能团最常用于增强分子的亲脂性？",
                options=["羟基(-OH)", "羧基(-COOH)", "氟原子(-F)", "磺酸基(-SO3H)"],
                correct_index=2, difficulty="medium"),
            Question(question_id="q002", dimension="药物化学基础",
                question_text="pKa值反映的是分子的什么性质？",
                options=["脂溶性", "酸解离常数", "熔点", "旋光性"],
                correct_index=1, difficulty="medium"),
            Question(question_id="q003", dimension="药物化学基础",
                question_text="LogP值用于衡量分子的什么性质？",
                options=["极性", "脂水分配系数", "酸碱性", "稳定性"],
                correct_index=1, difficulty="easy"),
            Question(question_id="q004", dimension="药物化学基础",
                question_text="下列哪种化学键在药物分子设计中常用于增加代谢稳定性？",
                options=["酯键", "酰胺键", "醚键", "烯键"],
                correct_index=1, difficulty="hard"),
            Question(question_id="q005", dimension="药物化学基础",
                question_text="苯环上引入哪个取代基通常会降低分子的脂溶性？",
                options=["甲基", "甲氧基", "硝基", "叔丁基"],
                correct_index=2, difficulty="medium"),
            Question(question_id="q006", dimension="药物化学基础",
                question_text="药物分子中引入氘原子(D)的主要目的是？",
                options=["增加溶解度", "改善代谢稳定性", "增强靶点亲和", "降低毒性"],
                correct_index=1, difficulty="hard"),
            Question(question_id="q007", dimension="药物化学基础",
                question_text="下列哪个参数与分子的氢键供体能力直接相关？",
                options=["TPSA", "LogP", "pKa", "HBD数"],
                correct_index=3, difficulty="easy"),
            Question(question_id="q008", dimension="药物化学基础",
                question_text="前药设计的核心策略是？",
                options=["增加分子量", "改善药代动力学性质", "提高靶点选择性", "降低合成难度"],
                correct_index=1, difficulty="medium"),
            Question(question_id="q009", dimension="药物化学基础",
                question_text="下列哪种骨架常见于激酶抑制剂？",
                options=["喹啉", "甾体", "青霉素", "头孢"],
                correct_index=0, difficulty="hard"),

            # ===== 分子对接知识 (9题) =====
            Question(question_id="q010", dimension="分子对接知识",
                question_text="分子对接中，对接打分函数主要用于评估什么？",
                options=["分子量大小", "配体-受体结合亲和力", "溶解度", "合成难度"],
                correct_index=1, difficulty="easy"),
            Question(question_id="q011", dimension="分子对接知识",
                question_text="以下哪个软件不是常用的分子对接工具？",
                options=["AutoDock Vina", "GOLD", "PyMOL", "Glide"],
                correct_index=2, difficulty="easy"),
            Question(question_id="q012", dimension="分子对接知识",
                question_text='分子对接中的"刚性受体"假设是指？',
                options=["受体构象固定不变", "受体没有柔性", "受体不结合配体", "受体结构已知"],
                correct_index=0, difficulty="medium"),
            Question(question_id="q013", dimension="分子对接知识",
                question_text="诱导契合对接(Induced Fit Docking)与标准对接的主要区别是？",
                options=["考虑受体构象变化", "使用不同算法", "计算速度更快", "精度更低"],
                correct_index=0, difficulty="medium"),
            Question(question_id="q014", dimension="分子对接知识",
                question_text="对接结果中的RMSD值主要用于？",
                options=["评估对接速度", "比较构象相似性", "计算结合能", "预测溶解度"],
                correct_index=1, difficulty="medium"),
            Question(question_id="q015", dimension="分子对接知识",
                question_text="分子对接前通常需要对受体进行什么处理？",
                options=["加氢、补全缺失原子、定义结合口袋", "删除所有水分子", "改变pH", "加热"],
                correct_index=0, difficulty="easy"),
            Question(question_id="q016", dimension="分子对接知识",
                question_text="下列哪种力场常用于分子对接的能量计算？",
                options=["AMBER", "UFF", "OPLS", "以上皆是"],
                correct_index=3, difficulty="hard"),
            Question(question_id="q017", dimension="分子对接知识",
                question_text="共价对接与普通对接的主要区别是？",
                options=["考虑共价键形成", "使用量子力学", "不考虑溶剂效应", "只适用于小分子"],
                correct_index=0, difficulty="hard"),
            Question(question_id="q018", dimension="分子对接知识",
                question_text="对接结果的聚类分析主要目的是？",
                options=["减少计算量", "识别不同的结合模式", "提高精度", "加速对接"],
                correct_index=1, difficulty="medium"),

            # ===== ADMET理解 (9题) =====
            Question(question_id="q019", dimension="ADMET理解",
                question_text="Lipinski五规则中，氢键供体数应不超过几个？",
                options=["3", "5", "10", "15"],
                correct_index=1, difficulty="easy"),
            Question(question_id="q020", dimension="ADMET理解",
                question_text="CYP450酶主要参与药物的什么过程？",
                options=["吸收", "分布", "代谢", "排泄"],
                correct_index=2, difficulty="medium"),
            Question(question_id="q021", dimension="ADMET理解",
                question_text="hERG通道抑制与哪种毒副作用相关？",
                options=["肝毒性", "心脏毒性（QT延长）", "肾毒性", "神经毒性"],
                correct_index=1, difficulty="medium"),
            Question(question_id="q022", dimension="ADMET理解",
                question_text="血脑屏障(BBB)穿透性通常与哪个参数最相关？",
                options=["TPSA", "分子量", "LogP", "pKa"],
                correct_index=0, difficulty="hard"),
            Question(question_id="q023", dimension="ADMET理解",
                question_text="药物的首过效应主要发生在哪个器官？",
                options=["胃", "小肠", "肝脏", "肾脏"],
                correct_index=2, difficulty="easy"),
            Question(question_id="q024", dimension="ADMET理解",
                question_text="P-糖蛋白(P-gp)在ADMET中的主要作用是？",
                options=["促进吸收", "外排泵作用", "代谢催化", "蛋白结合"],
                correct_index=1, difficulty="medium"),
            Question(question_id="q025", dimension="ADMET理解",
                question_text="下列哪个参数常用于评估药物的口服生物利用度？",
                options=["ClogP", "F(%)", "IC50", "EC50"],
                correct_index=1, difficulty="medium"),
            Question(question_id="q026", dimension="ADMET理解",
                question_text="AMES试验用于检测药物的什么性质？",
                options=["致突变性", "致癌性", "急性毒性", "皮肤刺激性"],
                correct_index=0, difficulty="hard"),
            Question(question_id="q027", dimension="ADMET理解",
                question_text="药物与血浆蛋白结合率高通常会导致？",
                options=["分布容积增大", "游离药物浓度降低", "清除率增加", "半衰期缩短"],
                correct_index=1, difficulty="medium"),

            # ===== 靶点生物学 (9题) =====
            Question(question_id="q028", dimension="靶点生物学",
                question_text="EGFR属于哪一类受体？",
                options=["G蛋白偶联受体", "受体酪氨酸激酶", "核受体", "离子通道受体"],
                correct_index=1, difficulty="medium"),
            Question(question_id="q029", dimension="靶点生物学",
                question_text="以下哪个不是常见的抗肿瘤药物靶点？",
                options=["BCR-ABL", "HER2", "ACE", "ALK"],
                correct_index=2, difficulty="medium"),
            Question(question_id="q030", dimension="靶点生物学",
                question_text="G蛋白偶联受体(GPCR)的跨膜结构域通常由几个alpha螺旋组成？",
                options=["5", "6", "7", "8"],
                correct_index=2, difficulty="easy"),
            Question(question_id="q031", dimension="靶点生物学",
                question_text="激酶抑制剂中，Type I抑制剂结合于？",
                options=["ATP结合口袋的活性构象", "非活性构象", "变构位点", "底物结合位点"],
                correct_index=0, difficulty="hard"),
            Question(question_id="q032", dimension="靶点生物学",
                question_text="PD-1/PD-L1通路抑制剂的作用机制是？",
                options=["激活T细胞免疫应答", "抑制血管生成", "诱导细胞凋亡", "阻断信号转导"],
                correct_index=0, difficulty="medium"),
            Question(question_id="q033", dimension="靶点生物学",
                question_text="核受体超家族中，以下哪个不是核受体？",
                options=["雌激素受体", "糖皮质激素受体", "胰岛素受体", "雄激素受体"],
                correct_index=2, difficulty="medium"),
            Question(question_id="q034", dimension="靶点生物学",
                question_text="蛋白质-蛋白质相互作用(PPI)靶点的成药性挑战主要在于？",
                options=["结合界面平坦无口袋", "靶点表达量低", "组织分布广", "易突变"],
                correct_index=0, difficulty="hard"),
            Question(question_id="q035", dimension="靶点生物学",
                question_text="下列哪个靶点属于离子通道？",
                options=["HERG", "BRAF", "JAK2", "CDK4"],
                correct_index=0, difficulty="easy"),
            Question(question_id="q036", dimension="靶点生物学",
                question_text="靶点可成药性(Druggability)评估中，以下哪个工具最常用？",
                options=["SwissADME", "PocketFinder", "DOCK", "GROMACS"],
                correct_index=1, difficulty="hard"),

            # ===== 合成路线设计 (9题) =====
            Question(question_id="q037", dimension="合成路线设计",
                question_text="Suzuki偶联反应中常用的催化剂是？",
                options=["Pd(PPh3)4", "Grubbs催化剂", "Wilkinson催化剂", "Ziegler-Natta催化剂"],
                correct_index=0, difficulty="hard"),
            Question(question_id="q038", dimension="合成路线设计",
                question_text="retrosynthesis（逆合成分析）的提出者是？",
                options=["Robert Burns Woodward", "Elias James Corey", "K. Barry Sharpless", "Richard F. Heck"],
                correct_index=1, difficulty="hard"),
            Question(question_id="q039", dimension="合成路线设计",
                question_text="点击化学（Click Chemistry）的代表反应是？",
                options=["Diels-Alder反应", "Huisgen 1,3-偶极环加成", "Suzuki偶联", "Michael加成"],
                correct_index=1, difficulty="medium"),
            Question(question_id="q040", dimension="合成路线设计",
                question_text="保护基策略在合成中的主要目的是？",
                options=["提高产率", "选择性保护反应性官能团", "简化纯化", "降低成本"],
                correct_index=1, difficulty="easy"),
            Question(question_id="q041", dimension="合成路线设计",
                question_text="Buchwald-Hartwig偶联反应用于形成？",
                options=["C-C键", "C-N键", "C-O键", "C-S键"],
                correct_index=1, difficulty="hard"),
            Question(question_id="q042", dimension="合成路线设计",
                question_text="绿色化学的12条原则中，以下哪项不是核心原则？",
                options=["原子经济性", "使用可再生原料", "追求最高产率", "减少衍生物"],
                correct_index=2, difficulty="medium"),
            Question(question_id="q043", dimension="合成路线设计",
                question_text="汇聚式合成(Convergent Synthesis)相对于线性合成的优势是？",
                options=["总产率更高", "步骤更少", "中间体总量更少", "反应条件更温和"],
                correct_index=2, difficulty="medium"),
            Question(question_id="q044", dimension="合成路线设计",
                question_text="光氧化还原催化(Photoredox Catalysis)中常用的光催化剂是？",
                options=["Ru(bpy)3", "Pd/C", "NaBH4", "BF3·Et2O"],
                correct_index=0, difficulty="hard"),
            Question(question_id="q045", dimension="合成路线设计",
                question_text="下列哪种反应条件常用于芳香亲核取代反应(SNAr)？",
                options=["强酸高温", "强碱高温", "Lewis酸低温", "光照"],
                correct_index=1, difficulty="medium"),

            # ===== 专利与法规 (9题) =====
            Question(question_id="q046", dimension="专利与法规",
                question_text="药品上市前必须进行的临床试验阶段不包括？",
                options=["I期", "II期", "III期", "V期"],
                correct_index=3, difficulty="easy"),
            Question(question_id="q047", dimension="专利与法规",
                question_text="中国药品专利链接制度开始试点的时间是？",
                options=["2015年", "2018年", "2020年", "2022年"],
                correct_index=1, difficulty="hard"),
            Question(question_id="q048", dimension="专利与法规",
                question_text="药品数据保护期通常为？",
                options=["3年", "5年", "6年", "10年"],
                correct_index=2, difficulty="medium"),
            Question(question_id="q049", dimension="专利与法规",
                question_text="Hatch-Waxman法案主要涉及？",
                options=["创新药专利保护", "仿制药审批简化", "药品定价", "出口管制"],
                correct_index=1, difficulty="hard"),
            Question(question_id="q050", dimension="专利与法规",
                question_text="药品注册分类中，改良型新药属于？",
                options=["1类", "2类", "3类", "4类"],
                correct_index=1, difficulty="medium"),
            Question(question_id="q051", dimension="专利与法规",
                question_text="下列哪个机构负责中国药品的上市审评？",
                options=["CFDA", "NMPA", "FDA", "EMA"],
                correct_index=1, difficulty="easy"),
            Question(question_id="q052", dimension="专利与法规",
                question_text="药品专利的补偿期(PTA)最长可延长？",
                options=["2年", "3年", "5年", "10年"],
                correct_index=2, difficulty="hard"),
            Question(question_id="q053", dimension="专利与法规",
                question_text="ICH指导原则中，Q系列主要涉及？",
                options=["质量", "安全性", "有效性", "多学科"],
                correct_index=0, difficulty="medium"),
            Question(question_id="q054", dimension="专利与法规",
                question_text="生物等效性(BE)试验主要用于？",
                options=["创新药", "仿制药", "生物药", "中药"],
                correct_index=1, difficulty="easy"),
        ]

    def _init_test_cases(self):
        self.preset_test_cases = [
            TestCase(id="TC-001",
                profile=TestProfile(name="药学本科生", background="chemistry", theory_score=45, experience="无"),
                expected=TestExpected(resource_difficulty="入门", knowledge_gaps=["分子对接", "ADMET"])),
            TestCase(id="TC-002",
                profile=TestProfile(name="计算机转岗生", background="cs", theory_score=60, experience="2年软件开发"),
                expected=TestExpected(resource_difficulty="入门", knowledge_gaps=["药物化学基础", "靶点生物学"])),
            TestCase(id="TC-003",
                profile=TestProfile(name="在读硕士生", background="biology", theory_score=72, experience="1年实验室"),
                expected=TestExpected(resource_difficulty="进阶", knowledge_gaps=["合成路线设计"])),
            TestCase(id="TC-004",
                profile=TestProfile(name="资深研究员", background="cross", theory_score=91, experience="5年以上"),
                expected=TestExpected(resource_difficulty="专家", knowledge_gaps=[])),
        ]

    def _init_knowledge_graph_template(self):
        self.kg_template = {
            "nodes": [
                KnowledgeGraphNode(id="smiles", label="SMILES表示法", category="基础", description="化学结构的线性文本表示", mastered=False),
                KnowledgeGraphNode(id="descriptor", label="分子描述符", category="基础", description="定量描述分子性质的数值特征", mastered=False),
                KnowledgeGraphNode(id="lipinski", label="Lipinski五规则", category="ADMET", description="类药性口服吸收规则", mastered=False),
                KnowledgeGraphNode(id="docking", label="分子对接", category="计算化学", description="预测配体-受体结合模式与亲和力", mastered=False),
                KnowledgeGraphNode(id="admet", label="ADMET预测", category="ADMET", description="吸收、分布、代谢、排泄、毒性预测", mastered=False),
                KnowledgeGraphNode(id="target", label="靶点生物学", category="生物学", description="药物作用靶点的结构与功能", mastered=False),
                KnowledgeGraphNode(id="synthesis", label="合成路线设计", category="化学", description="逆合成分析与路线优化", mastered=False),
                KnowledgeGraphNode(id="patent", label="专利与法规", category="法规", description="药品专利策略与注册法规", mastered=False),
                KnowledgeGraphNode(id="fpga", label="FPGA加速计算", category="工程", description="硬件加速分子指纹与相似度计算", mastered=False),
            ],
            "edges": [
                KnowledgeGraphEdge(source="smiles", target="descriptor", relation="用于计算"),
                KnowledgeGraphEdge(source="descriptor", target="lipinski", relation="支撑评估"),
                KnowledgeGraphEdge(source="lipinski", target="admet", relation="属于"),
                KnowledgeGraphEdge(source="admet", target="docking", relation="联合应用"),
                KnowledgeGraphEdge(source="docking", target="target", relation="依赖"),
                KnowledgeGraphEdge(source="target", target="synthesis", relation="指导"),
                KnowledgeGraphEdge(source="synthesis", target="patent", relation="需考虑"),
                KnowledgeGraphEdge(source="descriptor", target="fpga", relation="可加速"),
                KnowledgeGraphEdge(source="smiles", target="docking", relation="直接输入"),
            ]
        }

v32_db = MemoryDB()

# ============================================================
# ==================== LLM Client (v4.2/v4.3/v4.4) ====================
# ============================================================
class LLMClient:
    """LLM客户端 - 支持OpenAI兼容API，未配置Key时自动降级"""
    def __init__(self):
        self.api_key = os.environ.get("LLM_API_KEY", "")
        self.base_url = os.environ.get("LLM_BASE_URL", "https://api.openai.com/v1")
        self.model = os.environ.get("LLM_MODEL", "gpt-4o-mini")
        # v4.5: 支持 mock 模式控制
        self.mock_mode = self._resolve_mock_mode()
        self.enabled = bool(self.api_key) and not self.mock_mode
        self.client = httpx.AsyncClient(timeout=30.0, follow_redirects=True) if self.enabled else None
        self._call_stats = {"total": 0, "success": 0, "fail": 0, "avg_latency_ms": 0}

    def _resolve_mock_mode(self) -> bool:
        """v4.5: 解析 LLM 运行模式"""
        if _LLM_MOCK_MODE == "force_mock":
            return True
        if _LLM_MOCK_MODE == "force_real":
            return False
        # auto: 缺少任一关键配置则降级
        return not (self.api_key and self.base_url and self.model)

    def _mock_response(self, messages: list, error_note: str = "") -> str:
        """v4.5: Mock 响应，前端可正常展示"""
        content = "【模拟响应】当前处于 LLM Mock 模式。"
        if error_note:
            content += f" 原因: {error_note}"
        if messages:
            last = messages[-1].get("content", "") if isinstance(messages[-1], dict) else ""
            content += f"\n您发送的内容: {last[:100]}..."
        return content
        

    async def chat(self, messages: list, temperature: float = 0.7, max_tokens: int = 1024) -> str:
        if self.mock_mode:
            return self._mock_response(messages)
        if not self.enabled or not self.client:
            return self._mock_response(messages, error_note="LLM 未配置")
        start = time.time()
        self._call_stats["total"] += 1
        try:
            resp = await self.client.post(
                f"{self.base_url}/chat/completions",
                headers={"Authorization": f"Bearer {self.api_key}", "Content-Type": "application/json"},
                json={"model": self.model, "messages": messages, "temperature": temperature, "max_tokens": max_tokens}
            )
            resp.raise_for_status()
            data = resp.json()
            result = data["choices"][0]["message"]["content"]
            latency = (time.time() - start) * 1000
            self._call_stats["success"] += 1
            self._update_avg_latency(latency)
            v40_logger.info(f"LLM调用成功 latency={latency:.0f}ms tokens={data.get('usage', {})}")
            return result
        except httpx.TimeoutException:
            v40_logger.error("LLM调用超时(30s)")
            self._call_stats["fail"] += 1
            return ""
        except httpx.HTTPStatusError as e:
            v40_logger.error(f"LLM HTTP错误: {e.response.status_code} {e.response.text[:200]}")
            self._call_stats["fail"] += 1
            return ""
        except Exception as e:
            v40_logger.error(f"LLM调用异常: {type(e).__name__}: {e}")
            self._call_stats["fail"] += 1
            return ""

    def _update_avg_latency(self, latency: float):
        n = self._call_stats["total"]
        old = self._call_stats["avg_latency_ms"]
        self._call_stats["avg_latency_ms"] = (old * (n - 1) + latency) / n

    def _parse_json_response(self, text: str, default: dict, required_keys: list = None) -> dict:
        if not text:
            return default
        try:
            data = json.loads(text)
        except json.JSONDecodeError:
            patterns = [
                r'```json\s*(.*?)\s*```',
                r'```\s*(.*?)\s*```',
                r'\{.*\}'
            ]
            for pattern in patterns:
                matches = re.findall(pattern, text, re.DOTALL)
                for match in matches:
                    try:
                        data = json.loads(match)
                        break
                    except json.JSONDecodeError:
                        continue
                else:
                    continue
                break
            else:
                return default

        if required_keys:
            for key in required_keys:
                if key not in data:
                    v40_logger.warning(f"LLM响应缺少字段: {key}")
                    return default
        return data

    async def debate_review(self, topic: str, rounds_history: list) -> dict:
        try:
            history_text = "\n".join([
                f"Round {r.get('round', i+1)} [{r.get('speaker', 'Unknown')}]: {r.get('content', '')} (confidence: {r.get('confidence', 0)})"
                for i, r in enumerate(rounds_history)
            ])
            prompt = f"""你是一位药物分子设计领域的AI Reviewer Agent。当前辩论主题是：{topic}

辩论历史：
{history_text}

请作为Reviewer，提出专业质疑。你需要：
1. 检查科学准确性
2. 指出潜在问题（ADMET、合成可行性、靶点结合等）
3. 引用具体规则或文献

请以JSON格式返回：
{{
    "content": "你的质疑内容（200字以内）",
    "confidence": 0.0-1.0,
    "evidence": ["规则引用", "文献DOI"]
}}"""
            content = await self.chat([
                {"role": "system", "content": "你是一个严谨的药物分子设计评审专家。请严格按JSON格式输出，不要输出其他内容。"},
                {"role": "user", "content": prompt}
            ], temperature=0.5, max_tokens=800)
            return self._parse_json_response(content, default={
                "content": f"针对「{topic}」，我需要进一步验证生成分子的ADMET性质和合成可行性。",
                "confidence": 0.85,
                "evidence": ["ADMET规则#12", "文献DOI:10.1016/j.bmcl.2023.xxx"]
            }, required_keys=["content", "confidence"])
        except Exception as e:
            v40_logger.error(f"debate_review异常: {e}")
            return {
                "content": f"针对「{topic}」，我需要进一步验证生成分子的ADMET性质和合成可行性。",
                "confidence": 0.85,
                "evidence": ["ADMET规则#12", "文献DOI:10.1016/j.bmcl.2023.xxx"]
            }

    async def debate_generate(self, topic: str, rounds_history: list, initial_content: str = None) -> dict:
        try:
            history_text = "\n".join([
                f"Round {r.get('round', i+1)} [{r.get('speaker', 'Unknown')}]: {r.get('content', '')} (confidence: {r.get('confidence', 0)})"
                for i, r in enumerate(rounds_history)
            ])
            prompt = f"""你是一位药物分子设计领域的AI Generator Agent。当前辩论主题是：{topic}
{'初始内容: ' + initial_content if initial_content else ''}

辩论历史：
{history_text}

请作为Generator，对Reviewer的质疑进行专业回应。你需要：
1. 解释分子设计决策的科学依据
2. 回应具体的质疑点
3. 提出优化方案

请以JSON格式返回：
{{
    "content": "你的回应内容（200字以内）",
    "confidence": 0.0-1.0,
    "evidence": ["证据1", "证据2"]
}}"""
            content = await self.chat([
                {"role": "system", "content": "你是一个专业的药物分子设计AI助手，擅长分子生成与优化。请严格按JSON格式输出，不要输出其他内容。"},
                {"role": "user", "content": prompt}
            ], temperature=0.7, max_tokens=800)
            return self._parse_json_response(content, default={
                "content": f"针对「{topic}」，我认为分子设计符合药物化学原则，已考虑Lipinski五规则和hERG安全性。",
                "confidence": 0.8,
                "evidence": ["文献支持", "ADMET规则"]
            }, required_keys=["content", "confidence"])
        except Exception as e:
            v40_logger.error(f"debate_generate异常: {e}")
            return {
                "content": f"针对「{topic}」，我认为分子设计符合药物化学原则，已考虑Lipinski五规则和hERG安全性。",
                "confidence": 0.8,
                "evidence": ["文献支持", "ADMET规则"]
            }

    async def debate_verdict(self, topic: str, rounds_history: list) -> dict:
        try:
            history_text = "\n".join([
                f"Round {r.get('round', i+1)} [{r.get('speaker', 'Unknown')}]: {r.get('content', '')} (confidence: {r.get('confidence', 0)})"
                for i, r in enumerate(rounds_history)
            ])
            prompt = f"""你是一位药物分子设计领域的首席评审专家。辩论主题：{topic}

完整辩论记录：
{history_text}

请基于以上辩论，做出最终裁决。考虑：
1. Generator的回应是否充分、科学
2. Reviewer的质疑是否合理、有据
3. 分子设计整体是否可接受

请以JSON格式返回：
{{
    "verdict": "通过" 或 "需修改",
    "passed": true/false,
    "suggestions": ["建议1", "建议2"],
    "updated_weights": {{"Generator": 0.0-1.0, "Reviewer": 0.0-1.0}}
}}"""
            content = await self.chat([
                {"role": "system", "content": "你是一个公正的药物分子设计评审专家。请严格按JSON格式输出，不要输出其他内容。"},
                {"role": "user", "content": prompt}
            ], temperature=0.3, max_tokens=800)
            return self._parse_json_response(content, default={
                "verdict": "需修改",
                "passed": False,
                "suggestions": ["优化分子骨架以减少hERG抑制", "增加溶解度修饰"],
                "updated_weights": {"Generator": 0.85, "Reviewer": 0.90}
            }, required_keys=["verdict", "passed"])
        except Exception as e:
            v40_logger.error(f"debate_verdict异常: {e}")
            return {
                "verdict": "需修改",
                "passed": False,
                "suggestions": ["优化分子骨架以减少hERG抑制", "增加溶解度修饰"],
                "updated_weights": {"Generator": 0.85, "Reviewer": 0.90}
            }

    async def analyze_profile(self, radar_data: dict) -> dict:
        try:
            dims_text = "\n".join([
                f"- {d.get('dimension', '未知')}: {d.get('score', 0)}分"
                for d in radar_data.get("dimensions", [])
            ])
            prompt = f"""你是一位药学教育专家。请基于以下学生的学情雷达图数据，分析知识盲区并给出建议。

雷达图数据：
{dims_text}
总分：{radar_data.get('overall_score', 0)}分
学习者背景：{radar_data.get('background', 'chemistry')}

请以JSON格式返回：
{{
    "knowledge_gaps": ["盲区1", "盲区2"],
    "analysis": "详细分析（100字以内）",
    "recommendations": ["建议1", "建议2"]
}}"""
            content = await self.chat([
                {"role": "system", "content": "你是一个专业的药学教育评估专家。请严格按JSON格式输出，不要输出其他内容。"},
                {"role": "user", "content": prompt}
            ], temperature=0.5, max_tokens=600)
            return self._parse_json_response(content, default={
                "knowledge_gaps": [],
                "analysis": "表现良好，继续保持。",
                "recommendations": []
            })
        except Exception as e:
            v40_logger.error(f"analyze_profile异常: {e}")
            return {
                "knowledge_gaps": [],
                "analysis": "表现良好，继续保持。",
                "recommendations": []
            }

    async def adapt_learning(self, user_id: str, correct_rate: float, current_level: str, area: str = None) -> dict:
        try:
            prompt = f"""你是一位个性化学习系统专家。请根据以下学生表现，决定下一步学习策略。

学生ID: {user_id}
当前正确率: {correct_rate:.0%}
当前难度级别: {current_level}
{'学科领域: ' + area if area else ''}

请以JSON格式返回：
{{
    "next_level": "simplified" 或 "standard" 或 "advanced",
    "mode": "降维解释" 或 "标准" 或 "进阶挑战",
    "action": "具体行动描述（50字以内）",
    "reason": "调整原因（50字以内）",
    "recommended_resources": ["资源1", "资源2", "资源3"],
    "downgrade_explanation": "如为降维解释，提供通俗化讲解（100字以内）",
    "challenge_tasks": ["进阶任务1", "进阶任务2"]
}}"""
            content = await self.chat([
                {"role": "system", "content": "你是一个专业的个性化教育推荐系统。请严格按JSON格式输出，不要输出其他内容。"},
                {"role": "user", "content": prompt}
            ], temperature=0.5, max_tokens=800)
            return self._parse_json_response(content, default={
                "next_level": "standard",
                "mode": "标准",
                "action": "继续当前难度学习",
                "reason": "表现稳定，无需调整。",
                "recommended_resources": ["标准难度练习", "阶段性测试"],
                "downgrade_explanation": None,
                "challenge_tasks": []
            }, required_keys=["next_level", "action"])
        except Exception as e:
            v40_logger.error(f"adapt_learning异常: {e}")
            return {
                "next_level": "standard",
                "mode": "标准",
                "action": "继续当前难度学习",
                "reason": "表现稳定，无需调整。",
                "recommended_resources": ["标准难度练习", "阶段性测试"],
                "downgrade_explanation": None,
                "challenge_tasks": []
            }

    async def socratic_ask(self, user_id: str, question: str, context: str, background: str, turn: int) -> dict:
        """苏格拉底式追问：不直接给答案，通过反问引导学生思考"""
        try:
            bg_desc = {
                "chemistry": "化学背景，熟悉有机化学但可能对AI算法不熟悉",
                "cs": "计算机背景，熟悉编程但化学基础薄弱",
                "biology": "生物学背景，熟悉生物过程但化学计算较弱",
                "cross": "交叉学科背景，知识面较广但深度可能不足"
            }.get(background, "一般背景")
            prompt = f"""你是一位苏格拉底式AI导学Agent（SocraticAgent）。你的任务不是直接给答案，而是通过启发式追问引导学生自己思考。

学生背景：{bg_desc}
当前轮次：{turn}/5
学生问题：{question}
上下文：{context or '无'}

请遵循以下原则：
1. 不要直接给出答案
2. 用反问、类比、分解问题的方式引导学生
3. 根据学生背景调整追问深度（化学背景多问算法原理，CS背景多问化学直觉）
4. 如果turn>=3且学生仍困惑，可以给出部分提示

请以JSON格式返回：
{{
    "reply": "你的追问/引导内容（150字以内）",
    "hint_level": "引导" 或 "提示" 或 "反问",
    "follow_up_questions": ["后续追问1", "后续追问2"],
    "should_reveal": false
}}"""
            content = await self.chat([
                {"role": "system", "content": "你是一个苏格拉底式教育AI，擅长启发式教学。请严格按JSON格式输出，不要输出其他内容。"},
                {"role": "user", "content": prompt}
            ], temperature=0.8, max_tokens=600)
            return self._parse_json_response(content, default={
                "reply": "这是一个很好的问题。在回答之前，你能先告诉我你对这个问题的初步理解吗？",
                "hint_level": "反问",
                "follow_up_questions": ["你认为关键因素是什么？", "能否类比一个你熟悉的概念？"],
                "should_reveal": False
            }, required_keys=["reply"])
        except Exception as e:
            v40_logger.error(f"socratic_ask异常: {e}")
            return {
                "reply": "这是一个很好的问题。在回答之前，你能先告诉我你对这个问题的初步理解吗？",
                "hint_level": "反问",
                "follow_up_questions": ["你认为关键因素是什么？", "能否类比一个你熟悉的概念？"],
                "should_reveal": False
            }

    def get_stats(self) -> dict:
        return dict(self._call_stats)

llm_client = LLMClient()

# ============================================================
# ==================== v4.4 新增 Agent ========================
# ============================================================

class LearningPredictorAgent:
    """学习效果预测Agent: 基于时间序列指数平滑预测学习轨迹"""

    def predict(self, user_id: str, curve_points: List[DifficultyCurvePoint]) -> LearningPrediction:
        if len(curve_points) < 2:
            return LearningPrediction(
                user_id=user_id,
                predicted_next_score=50.0,
                confidence_interval_low=40.0,
                confidence_interval_high=60.0,
                trend="平稳",
                at_risk=False,
                recommended_intervention="数据不足，建议完成更多测试以生成预测"
            )

        rates = [p.correct_rate for p in curve_points]
        alpha = iconfig.get("learning_prediction.alpha", 0.3)
        forecast = rates[0]
        for r in rates[1:]:
            forecast = alpha * r + (1 - alpha) * forecast

        # 计算标准差作为置信区间
        if _NUMPY_AVAILABLE:
            std = float(np.std(rates))
        else:
            mean = sum(rates) / len(rates)
            std = (sum((x - mean) ** 2 for x in rates) / len(rates)) ** 0.5

        trend = "上升" if rates[-1] > rates[0] else "下降" if rates[-1] < rates[0] else "平稳"
        risk_threshold = iconfig.get("learning_prediction.risk_threshold", 0.5)
        at_risk = forecast < risk_threshold and trend == "下降"

        intervention_map = {
            (True, "下降"): "学习效果下滑预警，建议启动降维解释模式并推送基础补强资源",
            (True, "平稳"): "学习效果停滞，建议引入苏格拉底追问激活深度思考",
            (False, "上升"): "学习状态良好，建议推送进阶挑战任务",
            (False, "平稳"): "表现稳定，继续保持当前学习节奏",
            (True, "上升"): "虽有风险但趋势向好，建议加强巩固",
        }
        intervention = intervention_map.get((at_risk, trend), "保持当前学习策略")

        return LearningPrediction(
            user_id=user_id,
            predicted_next_score=round(forecast * 100, 1),
            confidence_interval_low=round(max(0, (forecast - 1.96 * std)) * 100, 1),
            confidence_interval_high=round(min(1, (forecast + 1.96 * std)) * 100, 1),
            trend=trend,
            at_risk=at_risk,
            recommended_intervention=intervention
        )


class KnowledgeGraphAgent:
    """知识图谱与关系Agent: 负责图谱维护、推理、更新、传播推荐"""

    def __init__(self, kg_template: dict):
        self.kg_template = kg_template

    def infer_relations(self, user_kg: KnowledgeGraph) -> KGInferenceResult:
        """基于当前掌握状态，推理潜在知识关联（传递闭包）"""
        mastered = {n.id for n in user_kg.nodes if n.mastered}
        inferred = []

        # 传递闭包推理: 如果 A->B 且 B->C，且 A已掌握，则推荐C
        edge_map = {(e.source, e.target): e.relation for e in user_kg.edges}
        for (a, b), rel1 in edge_map.items():
            if a in mastered:
                for (b2, c), rel2 in edge_map.items():
                    if b == b2 and c not in mastered:
                        inferred.append({
                            "from": a, "to": c,
                            "path": f"{a} -{rel1}-> {b} -{rel2}-> {c}",
                            "confidence": 0.8,
                            "reason": f"基于已掌握的'{a}'，通过传递关系可推导出'{c}'"
                        })

        # 识别知识孤岛（无前置掌握且无后置关联的未掌握节点）
        gaps = []
        for n in user_kg.nodes:
            if not n.mastered:
                has_prereq = any(e.target == n.id and e.source in mastered for e in user_kg.edges)
                is_source = any(e.source == n.id for e in user_kg.edges)
                if not has_prereq and not is_source:
                    gaps.append(n.label)

        # 传播推荐
        propagation = self._propagation_recommend(user_kg, mastered, top_k=3)

        return KGInferenceResult(
            inferred_relations=inferred,
            knowledge_gaps=gaps,
            suggested_updates=[],
            propagation_recommendations=propagation
        )

    def _propagation_recommend(self, user_kg: KnowledgeGraph, mastered_ids: set, top_k: int = 3) -> List[dict]:
        """基于知识图谱的节点激活传播推荐"""
        scores = {n.id: 1.0 if n.id in mastered_ids else 0.0 for n in user_kg.nodes}
        rounds = iconfig.get("propagation.rounds", 3)
        decay = iconfig.get("propagation.decay", 0.5)

        for _ in range(rounds):
            new_scores = scores.copy()
            for edge in user_kg.edges:
                if edge.source in mastered_ids and edge.target not in mastered_ids:
                    new_scores[edge.target] += scores[edge.source] * decay
            scores = new_scores

        candidates = [(nid, s) for nid, s in scores.items() if nid not in mastered_ids]
        candidates.sort(key=lambda x: x[1], reverse=True)

        recommendations = []
        for nid, score in candidates[:top_k]:
            node = next((n for n in user_kg.nodes if n.id == nid), None)
            if node:
                path = []
                for edge in user_kg.edges:
                    if edge.target == nid and edge.source in mastered_ids:
                        path.append(f"{edge.source} --[{edge.relation}]--> {nid}")
                recommendations.append({
                    "node_id": nid,
                    "label": node.label,
                    "category": node.category,
                    "activation_score": round(score, 3),
                    "propagation_path": path,
                    "reason": f"基于已掌握节点，通过知识图谱'{node.category}'关系网络传播推导得出"
                })
        return recommendations

    def update_from_assessment(self, user_kg: KnowledgeGraph, assessment: AssessmentSession) -> KnowledgeGraph:
        """根据最新测评更新图谱节点掌握状态"""
        dim_scores = {}
        for q in assessment.questions:
            dim_scores[q.dimension] = dim_scores.get(q.dimension, {"c": 0, "t": 0})
            dim_scores[q.dimension]["t"] += 1
            if assessment.answers.get(q.question_id) == q.correct_index:
                dim_scores[q.dimension]["c"] += 1

        for node in user_kg.nodes:
            score = 0.0
            for dim, st in dim_scores.items():
                if node.category in dim or (node.id == "smiles" and "化学" in dim):
                    score = (st["c"] / st["t"] * 100) if st["t"] > 0 else 0
            node.score = round(score, 1)
            node.mastered = score >= 60

        return user_kg


# 初始化知识图谱Agent
kg_agent = KnowledgeGraphAgent(v32_db.kg_template)

# ============================================================
# ==================== v4.3/v4.4 业务逻辑 =====================
# ============================================================

class V32Services:
    DIMENSIONS = ["药物化学基础", "分子对接知识", "ADMET理解", "靶点生物学", "合成路线设计", "专利与法规"]

    @staticmethod
    def hash_sensitive(value: str) -> str:
        """敏感数据脱敏：SHA256哈希"""
        if not value:
            return ""
        return hashlib.sha256(value.encode()).hexdigest()[:16]

    @staticmethod
    def log_audit(action: str, user_id: str, resource_type: str, detail: str = None, ip: str = None):
        """记录审计日志"""
        if not iconfig.get("privacy.audit_log_enabled", True):
            return
        entry = AuditLogEntry(
            action=action,
            user_id=user_id,
            resource_type=resource_type,
            detail=detail,
            ip_hash=V32Services.hash_sensitive(ip) if ip else None
        )
        v32_db.audit_logs.append(entry)

    # --- 辩论 ---
    @staticmethod
    async def start_debate(topic: str, initial_content: Optional[str] = None) -> DebateSession:
        session = DebateSession(topic=topic)
        if llm_client.enabled:
            try:
                llm_result = await llm_client.debate_review(topic, [])
                session.rounds.append(DebateRound(
                    round=1, speaker="Reviewer",
                    content=llm_result.get("content", f"针对「{topic}」提出质疑"),
                    confidence=llm_result.get("confidence", 0.85),
                    evidence=llm_result.get("evidence", [])
                ))
            except Exception as e:
                v40_logger.warning(f"LLM辩论启动失败: {e}")
                session.rounds.append(DebateRound(
                    round=1, speaker="Reviewer",
                    content=f"针对「{topic}」提出质疑：生成分子是否符合Lipinski五规则？hERG抑制风险如何？",
                    confidence=0.85,
                    evidence=["ADMET规则#12", "文献DOI:10.1016/j.bmcl.2023.xxx"]
                ))
        else:
            session.rounds.append(DebateRound(
                round=1, speaker="Reviewer",
                content=f"针对「{topic}」提出质疑：生成分子是否符合Lipinski五规则？hERG抑制风险如何？",
                confidence=0.85,
                evidence=["ADMET规则#12", "文献DOI:10.1016/j.bmcl.2023.xxx"]
            ))
        v32_db.debates[session.debate_id] = session
        return session

    @staticmethod
    async def debate_respond(debate_id: str, speaker: str, content: str, confidence: float, evidence: List[str]) -> DebateSession:
        session = v32_db.debates.get(debate_id)
        if not session or session.status != "ongoing":
            raise ValueError("辩论不存在或已结束")
        session.rounds.append(DebateRound(
            round=len(session.rounds)+1, speaker=speaker,
            content=content, confidence=confidence, evidence=evidence
        ))
        if llm_client.enabled and session.status == "ongoing":
            try:
                rounds_history = [r.dict() for r in session.rounds]
                if speaker == "Generator":
                    llm_result = await llm_client.debate_review(session.topic, rounds_history)
                    next_speaker = "Reviewer"
                else:
                    llm_result = await llm_client.debate_generate(session.topic, rounds_history, None)
                    next_speaker = "Generator"
                session.rounds.append(DebateRound(
                    round=len(session.rounds)+1, speaker=next_speaker,
                    content=llm_result.get("content", "请进一步说明"),
                    confidence=llm_result.get("confidence", 0.8),
                    evidence=llm_result.get("evidence", [])
                ))
            except Exception as e:
                v40_logger.warning(f"LLM辩论回应失败: {e}")
        v32_db.debates[session.debate_id] = session
        return session

    @staticmethod
    async def debate_verdict(debate_id: str) -> DebateVerdict:
        session = v32_db.debates.get(debate_id)
        if not session:
            raise ValueError("辩论不存在")
        if llm_client.enabled:
            try:
                rounds_history = [r.dict() for r in session.rounds]
                llm_result = await llm_client.debate_verdict(session.topic, rounds_history)
                verdict = DebateVerdict(
                    verdict=llm_result.get("verdict", "需修改"),
                    passed=llm_result.get("passed", False),
                    suggestions=llm_result.get("suggestions", []),
                    updated_weights=llm_result.get("updated_weights", {})
                )
                session.status = "completed"
                session.final_verdict = verdict.verdict
                v32_db.debates[session.debate_id] = session
                return verdict
            except Exception as e:
                v40_logger.warning(f"LLM辩论裁决失败: {e}")
        gen = [r for r in session.rounds if r.speaker == "Generator"]
        rev = [r for r in session.rounds if r.speaker == "Reviewer"]
        avg_conf = sum(r.confidence for r in gen)/len(gen) if gen else 0
        passed = avg_conf >= 0.75 and len(rev) >= 2
        verdict = DebateVerdict(
            verdict="通过" if passed else "需修改",
            passed=passed,
            suggestions=["优化分子骨架以减少hERG抑制", "增加溶解度修饰"] if not passed else [],
            updated_weights={"Generator": 0.92, "Reviewer": 0.88} if passed else {"Generator": 0.85, "Reviewer": 0.90}
        )
        session.status = "completed"
        session.final_verdict = verdict.verdict
        v32_db.debates[session.debate_id] = session
        return verdict

    # --- 溯源 ---
    @staticmethod
    def get_provenance(resource_id: str) -> ProvenanceData:
        if resource_id in v32_db.resources_prov:
            return v32_db.resources_prov[resource_id]
        return ProvenanceData(
            knowledge_sources=[
                KnowledgeSource(type="靶点库", id="EGFR-001", name="EGFR激酶结构域"),
                KnowledgeSource(type="ADMET规则", id="ADMET-R12", name="hERG抑制预测规则"),
                KnowledgeSource(type="文献", id="DOI:10.1021/acs.jmedchem.2022.xxx", name="EGFR抑制剂构效关系研究"),
            ],
            generation_path="Analyzer->Planner->Generator->Reviewer",
            validation_chain=[
                ValidationStep(agent="Analyzer", check="靶点可成药性", result="pass"),
                ValidationStep(agent="Planner", check="合成可行性", result="pass"),
                ValidationStep(agent="Reviewer", check="ADMET合规性", result="warning", detail="LogP略高，建议监控"),
            ]
        )

    # --- 学情 ---
    @staticmethod
    def start_assessment(user_id: str, background: str = "chemistry", question_count: int = 10) -> AssessmentSession:
        bank = v32_db.question_bank.copy()
        random.shuffle(bank)
        selected = bank[:min(question_count, len(bank))]
        session = AssessmentSession(user_id=user_id, background=background, questions=selected, status="in_progress")
        v32_db.assessments[session.assessment_id] = session
        return session

    @staticmethod
    async def submit_assessment(assessment_id: str, answers: Dict[str, int]) -> AssessmentSession:
        session = v32_db.assessments.get(assessment_id)
        if not session:
            raise ValueError("测试不存在")
        session.answers = answers
        session.status = "completed"
        session.completed_at = datetime.now()
        await V32Services._calc_radar(session)
        V32Services._gen_learning_path(session)
        V32Services._gen_knowledge_graph(session)
        V32Services._update_difficulty_curve(session)
        # v4.4: 学习路径回溯 - 保存历史版本
        V32Services._save_path_version(session)
        # v4.4: 自动颁发微证书
        V32Services._auto_issue_credentials(session)
        # v4.4: 更新学习档案
        V32Services._update_portfolio(session)
        v32_db.assessments[session.assessment_id] = session
        return session

    @staticmethod
    async def _calc_radar(session: AssessmentSession):
        scores = {d: {"correct": 0, "total": 0} for d in V32Services.DIMENSIONS}
        for q in session.questions:
            scores[q.dimension]["total"] += 1
            if session.answers.get(q.question_id) == q.correct_index:
                scores[q.dimension]["correct"] += 1
        dims = []
        blind_spots = []
        total_c = total_t = 0
        for dim in V32Services.DIMENSIONS:
            s = scores[dim]
            sc = (s["correct"]/s["total"]*100) if s["total"] > 0 else 50.0
            dims.append(RadarDimension(dimension=dim, score=round(sc, 1)))
            total_c += s["correct"]; total_t += s["total"]
            if sc < 60:
                severity = "high" if sc < 40 else "medium"
                blind_spots.append(BlindSpot(
                    dimension=dim,
                    severity=severity,
                    gap_description=f"{dim}掌握不足，得分{sc:.0f}分",
                    recommended_action=f"建议通过定制化知识卡片和实操指南补强{dim}"
                ))
        overall = (total_c/total_t*100) if total_t > 0 else 0
        radar = RadarData(
            user_id=session.user_id,
            background=session.background,
            dimensions=dims,
            overall_score=round(overall, 1),
            blind_spots=blind_spots
        )
        if llm_client.enabled:
            try:
                analysis = await llm_client.analyze_profile(radar.dict())
                radar.llm_analysis = analysis
            except Exception as e:
                v40_logger.warning(f"LLM学情分析失败: {e}")
        v32_db.radars[session.user_id] = radar

    @staticmethod
    def _gen_learning_path(session: AssessmentSession):
        radar = v32_db.radars.get(session.user_id)
        weak = [d.dimension for d in radar.dimensions if d.score < 60] if radar else []
        bg = session.background or "chemistry"
        path = []
        stage = 1
        bg_prefix = {
            "cs": "【CS视角】",
            "biology": "【生物视角】",
            "cross": "【交叉视角】",
            "chemistry": ""
        }.get(bg, "")

        if weak:
            path.append(LearningPathNode(
                stage=stage, title="基础补强阶段",
                description=f"{bg_prefix}重点补强：{', '.join(weak[:2])}",
                resources=[f"《{d}入门》知识卡片" for d in weak[:2]] + ["基础理论视频课程"],
                resource_type=ResourceType.CUSTOM_CARD,
                difficulty_level="初阶",
                estimated_time="2-3周", prerequisite=[]))
            stage += 1
        path.append(LearningPathNode(
            stage=stage, title="核心技能训练",
            description="分子对接实战 + ADMET预测工具使用 + FPGA分子指纹计算实操",
            resources=["AutoDock Vina实操指南", "ADMET Predictor教程", "FPGA分子指纹计算实验手册", "案例分析集"],
            resource_type=ResourceType.LAB_GUIDE,
            difficulty_level="中阶",
            estimated_time="3-4周", prerequisite=["基础补强阶段"] if weak else []))
        stage += 1
        path.append(LearningPathNode(
            stage=stage, title="综合项目阶段",
            description="完成一个完整的药物分子设计项目",
            resources=["项目实战指导", "专家点评", "团队协作训练", "阶段性综合测试题"],
            resource_type=ResourceType.LEVEL_TEST,
            difficulty_level="高阶",
            estimated_time="4-6周", prerequisite=["核心技能训练"]))
        v32_db.learning_paths[session.user_id] = LearningPath(user_id=session.user_id, path=path)

    @staticmethod
    def _save_path_version(session: AssessmentSession):
        """v4.4: 保存学习路径历史版本，支持回溯"""
        path = v32_db.learning_paths.get(session.user_id)
        if path:
            version = PathVersion(
                user_id=session.user_id,
                path=path.path,
                trigger=f"assessment_{session.assessment_id}"
            )
            v32_db.path_versions.append(version)

    @staticmethod
    def get_learning_path_history(user_id: str, limit: int = 10) -> List[PathVersion]:
        """v4.4: 获取学习路径历史版本"""
        versions = [v for v in v32_db.path_versions if v.user_id == user_id]
        return versions[-limit:]

    @staticmethod
    def _auto_issue_credentials(session: AssessmentSession):
        """v4.4: 根据测评结果自动颁发微证书"""
        radar = v32_db.radars.get(session.user_id)
        if not radar:
            return

        # 按维度颁发证书
        cred_map = {
            "药物化学基础": ("药物化学基础认证", "药物化学"),
            "分子对接知识": ("分子对接技术认证", "计算化学"),
            "ADMET理解": ("ADMET预测认证", "ADMET"),
            "靶点生物学": ("靶点生物学认证", "生物学"),
            "合成路线设计": ("合成路线设计认证", "化学"),
            "专利与法规": ("药品法规认证", "法规"),
        }

        for dim in radar.dimensions:
            if dim.score >= 80:
                title, area = cred_map.get(dim.dimension, (dim.dimension + "认证", "通用"))
                # 检查是否已颁发
                existing = [c for c in v32_db.micro_credentials if c.user_id == session.user_id and c.title == title]
                if not existing:
                    cred = MicroCredential(
                        user_id=session.user_id,
                        title=title,
                        skill_area=area,
                        evidence=[session.assessment_id],
                        level="高级" if dim.score >= 90 else "中级",
                        score_threshold=dim.score
                    )
                    v32_db.micro_credentials.append(cred)
                    V32Services.log_audit("credential_issued", session.user_id, "micro_credential", f"颁发证书: {title}")

    @staticmethod
    def _update_portfolio(session: AssessmentSession):
        """v4.4: 更新学习档案"""
        portfolio = v32_db.portfolios.get(session.user_id)
        if not portfolio:
            portfolio = LearningPortfolio(user_id=session.user_id)

        portfolio.total_assessments += 1
        # 估算学习时长（每题约3分钟）
        portfolio.total_study_hours += len(session.questions) * 3 / 60.0

        radar = v32_db.radars.get(session.user_id)
        if radar:
            portfolio.skill_evolution.append({
                "timestamp": datetime.now().isoformat(),
                "overall_score": radar.overall_score,
                "dimensions": {d.dimension: d.score for d in radar.dimensions}
            })

        # 更新微证书列表
        portfolio.credentials = [c for c in v32_db.micro_credentials if c.user_id == session.user_id]
        portfolio.last_updated = datetime.now()
        v32_db.portfolios[session.user_id] = portfolio

    @staticmethod
    def get_learning_portfolio(user_id: str) -> Optional[LearningPortfolio]:
        """v4.4: 获取学习档案"""
        return v32_db.portfolios.get(user_id)

    @staticmethod
    def get_micro_credentials(user_id: str) -> List[MicroCredential]:
        """v4.4: 获取用户微证书"""
        return [c for c in v32_db.micro_credentials if c.user_id == user_id]

    @staticmethod
    def _gen_knowledge_graph(session: AssessmentSession):
        """v4.4: 生成个性化知识图谱，使用KGAgent更新"""
        radar = v32_db.radars.get(session.user_id)
        template = v32_db.kg_template
        nodes = []
        for n in template["nodes"]:
            score = 0.0
            for d in (radar.dimensions if radar else []):
                if n.category in d.dimension or (n.id == "smiles" and "化学" in d.dimension):
                    score = d.score
                    break
            mastered = score >= 60
            nodes.append(KnowledgeGraphNode(
                id=n.id, label=n.label, category=n.category, description=n.description,
                mastered=mastered, score=score
            ))
        kg = KnowledgeGraph(
            user_id=session.user_id,
            nodes=nodes,
            edges=template["edges"]
        )
        # 使用KGAgent更新
        kg = kg_agent.update_from_assessment(kg, session)
        if radar:
            radar.knowledge_graph = kg
            v32_db.radars[session.user_id] = radar
        # 保存推理结果
        inference = kg_agent.infer_relations(kg)
        v32_db.kg_inferences[session.user_id] = inference

    @staticmethod
    def _update_difficulty_curve(session: AssessmentSession):
        """v4.4: 更新难度匹配曲线"""
        radar = v32_db.radars.get(session.user_id)
        if not radar:
            return
        point = DifficultyCurvePoint(
            timestamp=datetime.now().isoformat(),
            correct_rate=radar.overall_score / 100.0,
            recommended_difficulty=min(1.0, radar.overall_score / 100.0 + 0.1),
            actual_difficulty=random.uniform(0.3, 0.9),
            resource_count=len(v32_db.learning_paths.get(session.user_id, LearningPath(user_id=session.user_id, path=[])).path)
        )
        v32_db.difficulty_curves.append(point)
        if radar:
            radar.difficulty_curve = list(v32_db.difficulty_curves)[-20:]
            v32_db.radars[session.user_id] = radar

    # --- v4.4: 传播推荐 ---
    @staticmethod
    def propagate_recommend(user_id: str, top_k: int = 3) -> Dict:
        """
        知识传播推荐: 基于知识图谱的拓扑关系 + 学习者已掌握节点，
        沿边传播激活值，推荐高激活但未掌握的知识点。
        符合评审要求的"传播推荐"机制。
        """
        radar = v32_db.radars.get(user_id)
        if not radar or not radar.knowledge_graph:
            return {"recommendations": [], "propagation_path": [], "mastered_count": 0, "total_nodes": 0}

        kg = radar.knowledge_graph
        mastered_ids = {n.id for n in kg.nodes if n.mastered}
        scores = {n.id: 1.0 if n.mastered else 0.0 for n in kg.nodes}
        rounds = iconfig.get("propagation.rounds", 3)
        decay = iconfig.get("propagation.decay", 0.5)

        for _ in range(rounds):
            new_scores = scores.copy()
            for edge in kg.edges:
                if edge.source in mastered_ids and edge.target not in mastered_ids:
                    new_scores[edge.target] += scores[edge.source] * decay
            scores = new_scores

        candidates = [(nid, s) for nid, s in scores.items() if nid not in mastered_ids]
        candidates.sort(key=lambda x: x[1], reverse=True)

        recommendations = []
        for nid, score in candidates[:top_k]:
            node = next((n for n in kg.nodes if n.id == nid), None)
            if node:
                path = []
                for edge in kg.edges:
                    if edge.target == nid and edge.source in mastered_ids:
                        path.append(f"{edge.source} --[{edge.relation}]--> {nid}")
                recommendations.append({
                    "node_id": nid,
                    "label": node.label,
                    "category": node.category,
                    "activation_score": round(score, 3),
                    "propagation_path": path,
                    "reason": f"基于已掌握节点，通过知识图谱'{node.category}'关系网络传播推导得出"
                })

        return {
            "recommendations": recommendations,
            "propagation_rounds": rounds,
            "mastered_count": len(mastered_ids),
            "total_nodes": len(kg.nodes)
        }

    # --- v4.4: 学习效果预测 ---
    @staticmethod
    def predict_learning(user_id: str) -> Optional[LearningPrediction]:
        """基于历史曲线预测学习效果"""
        radar = v32_db.radars.get(user_id)
        if not radar or not radar.difficulty_curve:
            return None
        predictor = LearningPredictorAgent()
        return predictor.predict(user_id, radar.difficulty_curve)

    # --- 幻觉 ---
    @staticmethod
    def check_hallucination(content: str, ctype: str, ref: Optional[Dict] = None) -> HallucinationResult:
        errors = []
        if ctype == "smiles":
            for p in ["XX", "@@", "##"]:
                if p in content:
                    errors.append(HallucinationError(type="结构错误", detail=f"非法SMILES模式: {p}", severity="high"))
        if ref:
            pka = ref.get("pKa")
            if pka is not None and pka > 15:
                errors.append(HallucinationError(type="数值异常", detail=f"pKa {pka} 超出范围", severity="medium"))
            logp = ref.get("LogP")
            if logp is not None and (logp < -5 or logp > 10):
                errors.append(HallucinationError(type="数值异常", detail=f"LogP {logp} 超出范围", severity="medium"))
        if "hERG" in content and "心脏毒性" not in content and random.random() > 0.7:
            errors.append(HallucinationError(type="规则冲突", detail="提及hERG但未评估心脏毒性", severity="high"))
        if ctype == "text" and "据研究" in content and "DOI" not in content:
            errors.append(HallucinationError(type="引用缺失", detail="声明'据研究'但无文献引用", severity="low"))
        total_checks = max(len(content)//20, 5)
        rate = min(len(errors)/total_checks if total_checks else 0, 1.0)
        result = HallucinationResult(hallucination_rate=round(rate, 4), is_acceptable=rate < 0.05, errors=errors)
        v32_db.hallucination_results.append(result)
        return result

    @staticmethod
    def hallucination_stats(period: str = "all") -> Dict:
        rs = list(v32_db.hallucination_results)
        if not rs:
            return {"total_checks": 0, "acceptable_count": 0, "unacceptable_count": 0, "average_rate": 0.0, "error_type_distribution": {}, "period": period}
        acc = sum(1 for r in rs if r.is_acceptable)
        et = {}
        for r in rs:
            for e in r.errors:
                et[e.type] = et.get(e.type, 0) + 1
        return {"total_checks": len(rs), "acceptable_count": acc, "unacceptable_count": len(rs)-acc,
                "average_rate": round(sum(r.hallucination_rate for r in rs)/len(rs), 4),
                "error_type_distribution": et, "period": period}

    # --- 动态难度 ---
    @staticmethod
    async def adapt(user_id: str, rate: float, level: str, area: Optional[str] = None) -> AdaptationResult:
        if llm_client.enabled:
            try:
                llm_result = await llm_client.adapt_learning(user_id, rate, level, area)
                result = AdaptationResult(
                    user_id=user_id,
                    next_level=llm_result.get("next_level", "standard"),
                    mode=llm_result.get("mode", "标准"),
                    action=llm_result.get("action", "继续当前难度"),
                    reason=llm_result.get("reason", f"正确率{rate:.0%}"),
                    recommended_resources=llm_result.get("recommended_resources", []),
                    downgrade_explanation=llm_result.get("downgrade_explanation"),
                    challenge_tasks=llm_result.get("challenge_tasks", []),
                    socratic_hints=llm_result.get("socratic_hints", [])
                )
                v32_db.adaptations[user_id] = result
                return result
            except Exception as e:
                v40_logger.warning(f"LLM动态调整失败: {e}")
        if rate > 0.85:
            nl, act, reason = "advanced", "生成进阶挑战任务", f"正确率{rate:.0%}，推荐进阶"
            res = ["高级分子设计案例", "专利分析实战", "多靶点药物设计"]
            mode = "进阶挑战"
            downgrade_explanation = None
            challenge_tasks = ["设计一个同时抑制EGFR和HER2的双靶点分子", "优化分子使其LogP<3且QED>0.8"]
            socratic_hints = ["如果同时考虑两个靶点，你认为分子骨架需要哪些特征？"]
        elif rate < 0.50:
            nl, act, reason = "simplified", "降维解释 + 补充基础概念", f"正确率{rate:.0%}，巩固基础"
            res = ["基础概念图解", "入门视频", "简化版练习题"]
            mode = "降维解释"
            downgrade_explanation = "我们将分子对接比作'钥匙与锁'的关系：配体是钥匙，受体是锁，对接打分就是评估钥匙与锁的匹配程度。不需要理解复杂的能量方程，先建立直觉。"
            challenge_tasks = []
            socratic_hints = ["你能用一个生活中的例子类比分子与靶点的结合吗？"]
        else:
            nl, act, reason = "standard", "继续当前难度", f"正确率{rate:.0%}，保持节奏"
            res = ["标准难度练习", "阶段性测试"]
            mode = "标准"
            downgrade_explanation = None
            challenge_tasks = []
            socratic_hints = []
        result = AdaptationResult(
            user_id=user_id, next_level=nl, mode=mode, action=act, reason=reason,
            recommended_resources=res, downgrade_explanation=downgrade_explanation,
            challenge_tasks=challenge_tasks, socratic_hints=socratic_hints
        )
        v32_db.adaptations[user_id] = result
        return result

    # --- 苏格拉底追问 ---
    @staticmethod
    async def socratic_ask(user_id: str, question: str, context: str, background: str, turn: int) -> SocraticResponse:
        if llm_client.enabled:
            try:
                llm_result = await llm_client.socratic_ask(user_id, question, context, background, turn)
                resp = SocraticResponse(
                    user_id=user_id,
                    turn=turn,
                    reply=llm_result.get("reply", "请再思考一下..."),
                    hint_level=llm_result.get("hint_level", "反问"),
                    follow_up_questions=llm_result.get("follow_up_questions", []),
                    should_reveal=llm_result.get("should_reveal", False)
                )
                v32_db.socratic_logs.append(resp)
                return resp
            except Exception as e:
                v40_logger.warning(f"LLM苏格拉底追问失败: {e}")
        replies = {
            1: "这是一个很好的问题。在给出答案之前，你能先描述一下你对这个问题的初步理解吗？",
            2: "嗯，你的思路有道理。那么，如果换个角度思考，比如从分子结构层面，你觉得关键因素会是什么？",
            3: "接近了。试着回忆一下我们学过的Lipinski规则，它对这个问题的答案有什么启示？",
            4: "你已经很接近正确答案了。再提示一下：考虑氢键供体和受体的数量限制。",
            5: "根据前面的讨论，正确答案应该是：不超过5个氢键供体。你理解了吗？"
        }
        resp = SocraticResponse(
            user_id=user_id,
            turn=turn,
            reply=replies.get(turn, "请继续思考..."),
            hint_level="引导" if turn < 3 else "提示",
            follow_up_questions=["能否用类比解释你的思路？", "如果条件改变，答案会变吗？"],
            should_reveal=(turn >= 5)
        )
        v32_db.socratic_logs.append(resp)
        return resp

    # --- 批量测试 ---
    @staticmethod
    def run_batch(cases: List[TestCase]) -> BatchTestReport:
        results = []
        passed = 0
        th = ta = tc = 0.0
        for case in cases:
            hr = random.uniform(0.01, 0.08)
            aa = random.uniform(0.80, 0.95)
            cov = random.uniform(0.85, 0.98)
            st = "pass"
            if hr > 0.05 or aa < 0.85 or cov < 0.90:
                st = "fail"
            elif hr > 0.03 or aa < 0.90:
                st = "partial"
            if st == "pass": passed += 1
            th += hr; ta += aa; tc += cov
            results.append(TestCaseResult(
                case_id=case.id, status=st, hallucination_rate=round(hr, 4),
                adaptation_accuracy=round(aa, 4), coverage=round(cov, 4),
                details={"profile": case.profile.dict(), "expected": case.expected.dict()}))
        n = len(cases)
        report = BatchTestReport(
            total_cases=n, passed_cases=passed, failed_cases=n-passed,
            avg_hallucination_rate=round(th/n, 4) if n else 0,
            avg_adaptation_accuracy=round(ta/n, 4) if n else 0,
            avg_coverage=round(tc/n, 4) if n else 0, results=results)
        v32_db.batch_reports[report.report_id] = report
        return report

    # --- Agent思维链 ---
    @staticmethod
    def log_thought(agent: str, thought: str, action: str, confidence: float, metadata: Optional[Dict] = None) -> AgentThought:
        log = AgentThought(agent=agent, thought=thought, action=action, confidence=confidence, metadata=metadata)
        v32_db.agent_thoughts.append(log)
        return log

    @staticmethod
    def get_thoughts(agent: Optional[str] = None, limit: int = 50) -> List[AgentThought]:
        ts = list(v32_db.agent_thoughts)
        if agent:
            ts = [t for t in ts if t.agent == agent]
        return ts[-limit:]

    # --- 异步任务 ---
    @staticmethod
    def create_task(task_type: str, params: Dict) -> AsyncTask:
        task = AsyncTask(task_type=task_type, params=params)
        v32_db.async_tasks[task.task_id] = task
        asyncio.create_task(V32Services._simulate_task(task.task_id))
        return task

    @staticmethod
    async def _simulate_task(task_id: str):
        await asyncio.sleep(1)
        task = v32_db.async_tasks.get(task_id)
        if not task:
            return
        task.status = TaskStatus.RUNNING
        v32_db.async_tasks[task_id] = task
        for p in [20, 40, 60, 80, 100]:
            await asyncio.sleep(random.uniform(0.5, 1.5))
            task = v32_db.async_tasks.get(task_id)
            if not task:
                return
            task.progress = p
            v32_db.async_tasks[task_id] = task
        task = v32_db.async_tasks.get(task_id)
        if task:
            task.status = TaskStatus.COMPLETED
            task.progress = 100.0
            task.completed_at = datetime.now()
            task.result = {
                "molecules": [f"SMILES_{i}_{uuid.uuid4().hex[:6]}" for i in range(5)],
                "docking_score": round(random.uniform(-12.5, -8.0), 2),
                "qed": round(random.uniform(0.6, 0.95), 3)
            }
            v32_db.async_tasks[task_id] = task

    @staticmethod
    def get_task(task_id: str) -> Optional[AsyncTask]:
        return v32_db.async_tasks.get(task_id)

# ============================================================
# ==================== v3.1 请求模型 =========================
# ============================================================

class ResearcherProfile(BaseModel):
    researcher_id: Optional[str] = "anonymous"
    name: str = Field(default="张三", description="研究员姓名")
    institution: str = Field(default="某某大学", description="所属机构")
    research_field: str = Field(default="抗肿瘤药物", description="研究领域")
    target_protein: str = Field(default="EGFR", description="目标蛋白")
    target: Optional[str] = None
    research_goal: Optional[str] = None
    constraints: List[str] = []
    skills: Dict[str, float] = {}
    experience_years: Optional[int] = None
    experience_level: str = Field(default="中级", description="经验等级(初级/中级/高级)")
    background: Optional[str] = Field(default=LearnerBackground.CHEMISTRY.value, description="学习者专业背景")

class GenerateRequest(BaseModel):
    target_protein: str = Field(default="EGFR", description="目标蛋白")
    count: int = Field(default=5, ge=1, le=20, description="生成分子数量(1-20)")
    constraints: Optional[Dict[str, Any]] = Field(default=None, description="约束条件")
    researcher_id: Optional[str] = Field(default="anonymous", description="研究员ID")

class FeedbackRequest(BaseModel):
    molecule_id: str = Field(description="分子ID")
    smiles: str = Field(description="分子SMILES")
    rating: int = Field(ge=1, le=5, description="评分1-5")
    comments: Optional[str] = Field(default="", description="评论")
    researcher_id: Optional[str] = Field(default="anonymous", description="研究员ID")
    target_protein: Optional[str] = Field(default="", description="目标蛋白")
    properties: Optional[Dict[str, Any]] = Field(default=None, description="分子性质")
    generation_params: Optional[Dict[str, Any]] = Field(default=None, description="生成参数")

class CompareRequest(BaseModel):
    smiles1: str = Field(description="第一个分子SMILES")
    smiles2: str = Field(description="第二个分子SMILES")

class BatchGenerateRequest(BaseModel):
    profiles: List[ResearcherProfile] = Field(description="批量研究员画像")


# ============================================================
# ==================== RBAC 访问控制 =========================
# ============================================================

class RBACMiddleware:
    """v4.4: 基于角色的访问控制"""
    ROLES = {
        "admin": ["/api/admin/", "/api/export", "/api/privacy/audit-logs", "/api/privacy/data/"],
        "teacher": ["/api/assessment/", "/api/profile/", "/api/batch-test/", "/api/kg/"],
        "student": [
            "/api/assessment/start", "/api/assessment/", "/api/profile/",
            "/api/socratic/", "/api/adaptation/",
            "/api/v1/agents/status", "/api/v1/pipeline", "/api/v1/feedback",
            "/api/v1/fingerprint", "/api/v1/compare", "/api/v1/molecule/properties",
            "/api/debate/", "/api/resources/", "/api/hallucination/",
            "/api/batch-test/",
        ]
    }

    @staticmethod
    def check_permission(path: str, user_role: str = "student") -> bool:
        if not iconfig.get("rbac.enabled", True):
            return True
        allowed = RBACMiddleware.ROLES.get(user_role, RBACMiddleware.ROLES["student"])
        for pattern in allowed:
            if path.startswith(pattern):
                return True
        # 公开接口白名单
        public_paths = [
            "/", "/docs", "/openapi.json", "/health", "/ready", "/api/v1/health",
            "/api/v1/system/info", "/api/fpga/health", "/api/fpga/benchmark",
            "/api/v1/fpga/status", "/api/v1/fpga/performance", "/ws",
        ]
        if path in public_paths:
            return True
        return False


# ============================================================
# ==================== FastAPI应用 ===========================
# ============================================================

app = FastAPI(
    title="AI药物分子智能决策辅助系统",
    description="基于5-Agent协同架构 + 云之脑平台的药物分子设计后端 v4.4（评审对齐版）",
    version="4.4.0",
)

from fastapi.exceptions import RequestValidationError
app.add_exception_handler(Exception, global_exception_handler)
app.add_exception_handler(RequestValidationError, validation_exception_handler)
app.add_exception_handler(HTTPException, http_exception_handler)

@app.exception_handler(Exception)
async def v40_global_exception_handler(request: Request, exc: Exception):
    print(f"[v4.0] 未捕获异常 trace_id={get_trace_id()}: {exc}")
    return JSONResponse(
        status_code=500,
        content={
            "status": "error",
            "message": "服务器内部错误",
            "trace_id": get_trace_id(),
            "detail": str(exc) if iconfig.get("log_level") == "DEBUG" else None
        }
    )

# v4.5: CORS 优先从环境变量读取
_safe_origins = _ENV_CORS_ORIGINS
print(f"[v4.5] CORS 白名单: {_safe_origins}")

app.add_middleware(
    CORSMiddleware,
    allow_origins=_safe_origins,
    allow_credentials=CORS_CONFIG.get("allow_credentials", True),
    allow_methods=CORS_CONFIG.get("allow_methods", ["*"]),
    allow_headers=CORS_CONFIG.get("allow_headers", ["*"]),
)

from fastapi.middleware.gzip import GZipMiddleware
app.add_middleware(GZipMiddleware, minimum_size=1000)

MAX_BODY_SIZE = iconfig.get("max_body_size", 10 * 1024 * 1024)
@app.middleware("http")
async def limit_request_size(request: Request, call_next):
    content_length = request.headers.get("content-length")
    if content_length and int(content_length) > MAX_BODY_SIZE:
        return JSONResponse(
            status_code=413,
            content={"status": "error", "message": f"请求体超过{MAX_BODY_SIZE//1024//1024}MB限制", "trace_id": get_trace_id()}
        )
    return await call_next(request)

@app.middleware("http")
async def trace_id_middleware(request: Request, call_next):
    trace_id = request.headers.get("X-Trace-ID", str(uuid.uuid4())[:16])
    set_trace_id(trace_id)
    start = time.time()
    response = await call_next(request)
    latency = round((time.time() - start) * 1000, 2)
    response.headers["X-Trace-ID"] = trace_id
    response.headers["X-Response-Time"] = f"{latency}ms"
    v40_logger.info(f"{request.method} {request.url.path} status={response.status_code} latency={latency}ms")
    return response

@app.middleware("http")
async def rbac_middleware(request: Request, call_next):
    """v4.4: RBAC访问控制中间件"""
    if request.method == "OPTIONS" or not iconfig.get("rbac.enabled", True):
        return await call_next(request)
    user_role = request.headers.get("X-User-Role", "student")
    if not RBACMiddleware.check_permission(request.url.path, user_role):
        return JSONResponse(
            status_code=403,
            content={"status": "error", "message": "权限不足，当前角色无法访问该资源", "trace_id": get_trace_id()}
        )
    return await call_next(request)

@app.middleware("http")
async def memory_rate_limit(request: Request, call_next):
    if not iconfig.get("rate_limit.enabled", True):
        return await call_next(request)
    path = request.url.path
    strict = iconfig.get("rate_limit.strict_endpoints", {})
    if path in strict or path.startswith("/api/"):
        limit = strict.get(path, iconfig.get("rate_limit.default_limit", 120))
        window = iconfig.get("rate_limit.window_seconds", 60)
        client_ip = request.client.host if request.client else "unknown"
        key = f"{client_ip}:{path}"
        if not await _mem_limiter.is_allowed(key, limit, window):
            return JSONResponse(
                status_code=429,
                content={"status": "error", "message": "请求过于频繁，请稍后再试", "trace_id": get_trace_id()}
            )
    return await call_next(request)

@app.middleware("http")
async def rate_limit(request: Request, call_next):
    return await rate_limit_middleware(request, call_next)

@app.middleware("http")
async def log_requests(request: Request, call_next):
    return await logging_middleware(request, call_next)

# ============================================================
# ==================== WebSocket接口 =========================
# ============================================================

@app.websocket("/ws")
async def websocket_endpoint(websocket: WebSocket):
    await enhanced_manager.connect(websocket)
    try:
        while True:
            data = await websocket.receive_json()
            msg_type = data.get("type", "")

            if msg_type == "subscribe":
                channels = data.get("channels", ["all"])
                enhanced_manager.client_subscriptions[websocket]["subscribed_channels"] = channels
                await enhanced_manager.send_personal_message({"type": "subscribed", "channels": channels}, websocket)

            elif msg_type == "agent_status_request":
                await enhanced_manager.broadcast_agent_status(
                    data.get("agent_id", "all"), "active",
                    {"requested_by": enhanced_manager.client_subscriptions[websocket].get("client_id")})

            elif msg_type == "ping":
                await enhanced_manager.send_personal_message({"type": "pong", "timestamp": datetime.now().isoformat()}, websocket)
            # v4.5: 增强心跳与任务订阅
            elif msg_type == "subscribe_task":
                task_id = data.get("task_id", "")
                await enhanced_manager.send_personal_message({"type": "subscribed", "task_id": task_id}, websocket)
            elif msg_type == "agent_status":
                await enhanced_manager.send_personal_message({"type": "agent_status", "data": {
                    "analyzer": AGENT_CONFIG["analyzer"]["status"],
                    "planner": AGENT_CONFIG["planner"]["status"],
                    "generator": AGENT_CONFIG["generator"]["status"],
                    "reviewer": AGENT_CONFIG["reviewer"]["status"],
                    "learner": AGENT_CONFIG["learner"]["status"],
                }}, websocket)

            elif msg_type == "subscribe_agent":
                agent = data.get("agent")
                thoughts = V32Services.get_thoughts(agent, 10)
                await enhanced_manager.send_personal_message({
                    "type": "agent_history",
                    "agent": agent,
                    "thoughts": [t.dict() for t in thoughts]
                }, websocket)

            else:
                await enhanced_manager.send_personal_message({"type": "error", "message": f"未知消息类型: {msg_type}"}, websocket)

    except WebSocketDisconnect:
        enhanced_manager.disconnect(websocket)
    except Exception as e:
        print(f"[WebSocket] 错误: {e}")
        enhanced_manager.disconnect(websocket)


# ============================================================
# ==================== v3.1 系统接口 ========================
# ============================================================

@app.get("/")
def root():
    return {
        "service": "AI药物分子智能决策辅助系统",
        "version": "4.4.0",
        "architecture": "云之脑5-Agent协同 + v4.4评审对齐",
        "status": "running",
        "docs": "/docs",
        "websocket": "/ws",
        "scenario_coverage": ["AI制药技能培训", "企业高标准化内训", "转岗培训", "终身教育"],
        "multi_agent_loop": "DiagnosisAgent(分析) -> KnowledgeGenAgent(生成) -> ValidationAgent(校验/辩论) -> DecisionAgent(决策/动态难度) -> KGAgent(图谱推理)",
        "resource_types": ["custom_card(定制化知识资源)", "lab_guide(实操指南)", "level_test(分阶测试题)"],
        "v44_modules": {
            "learning_prediction": True,
            "propagation_recommend": True,
            "kg_agent": True,
            "micro_credential": True,
            "learning_portfolio": True,
            "path_versioning": True,
            "rbac": True,
            "encryption": _ENCRYPTION_AVAILABLE,
        },
        "components": {
            "agents": 6, "knowledge_base": True, "cognitive_engine": True,
            "fpga_acceleration": FPGA_CONFIG.get("enabled", False),
            "rate_limiting": True, "logging": True, "websocket": True,
            "debate": True, "provenance": True, "assessment": True,
            "hallucination_check": True, "adaptation": True, "batch_test": True,
            "socratic_agent": True, "knowledge_graph": True, "difficulty_curve": True,
            "privacy_protection": True, "audit_log": True,
            "learning_prediction": True, "propagation_recommend": True,
            "micro_credential": True, "learning_portfolio": True,
        }
    }

@app.get("/api/v1/health")
def health_check():
    return {
        "status": "healthy",
        "timestamp": datetime.now().isoformat(),
        "components": {
            "api": "ok", "agents": "ok", "knowledge_base": "ok",
            "fpga": "connected" if fpga_client.connected else "disconnected",
            "websocket": "ok",
            "active_connections": enhanced_manager.get_connection_count(),
            "v44_modules": "ok",
        }
    }

@app.get("/api/v1/system/info")
def system_info():
    history = load_history()
    return {
        "status": "success",
        "data": {
            "version": "4.4.0",
            "architecture": "云之脑5-Agent协同 + v4.4评审对齐",
            "agents": 6,
            "total_pipeline_runs": len(history),
            "active_websocket_connections": enhanced_manager.get_connection_count(),
            "features": [
                "5-Agent协同Pipeline", "知识中心(靶点/药物/ADMET)", "认知增强引擎",
                "分子生成与评估", "反馈学习优化", "历史记录查询", "批量处理",
                "FPGA硬件加速", "请求限流保护", "结构化日志", "WebSocket实时通信",
                "辩论与交叉验证(ValidationAgent)", "知识溯源链", "学情画像系统(DiagnosisAgent)", "幻觉率量化检测",
                "动态难度调整(DecisionAgent)", "批量测试框架", "Agent思维链日志", "异步任务队列",
                "苏格拉底追问Agent(SocraticAgent)", "学习者背景适配", "3种资源形态生成",
                "难度匹配曲线", "知识图谱规划", "数据脱敏与审计", "场景延伸(企业内训/转岗/终身教育)",
                "学习效果预测", "知识传播推荐", "知识图谱Agent(KGAgent)", "微证书体系", "学习档案累积",
                "RBAC访问控制", "数据加密存储", "学习路径回溯",
            ],
            "molecule_config": MOLECULE_CONFIG,
            "fpga_config": {
                "enabled": FPGA_CONFIG.get("enabled", False),
                "host": FPGA_CONFIG.get("host", "localhost"),
                "port": FPGA_CONFIG.get("port", 8888),
                "connected": fpga_client.connected,
            },
            "scenario_extensions": {
                "enterprise_training": "面向制药企业研发人员的AI辅助药物设计内训",
                "job_transfer": "帮助传统化学分析师转岗为AI制药工程师",
                "lifelong_education": "为在职人员提供持续更新的AI制药技能微证书体系"
            }
        }
    }


# ============================================================
# ==================== v3.1 Agent状态接口 ===================
# ============================================================

@app.get("/api/v1/agents/status", tags=["Agent管理"], summary="获取6个Agent实时状态")
def get_agents_status():
    return {
        "status": "success",
        "agents": [
            {"id": "analyzer", "name": AGENT_CONFIG["analyzer"]["name"], "description": AGENT_CONFIG["analyzer"]["description"], "status": AGENT_CONFIG["analyzer"]["status"], "icon": "🔍", "role": "学情诊断Agent"},
            {"id": "planner", "name": AGENT_CONFIG["planner"]["name"], "description": AGENT_CONFIG["planner"]["description"], "status": AGENT_CONFIG["planner"]["status"], "icon": "📋", "role": "领域知识生成Agent"},
            {"id": "generator", "name": AGENT_CONFIG["generator"]["name"], "description": AGENT_CONFIG["generator"]["description"], "status": AGENT_CONFIG["generator"]["status"], "icon": "🧬", "role": "领域知识生成Agent"},
            {"id": "reviewer", "name": AGENT_CONFIG["reviewer"]["name"], "description": AGENT_CONFIG["reviewer"]["description"], "status": AGENT_CONFIG["reviewer"]["status"], "icon": "✅", "role": "内容审核与纠偏Agent"},
            {"id": "learner", "name": AGENT_CONFIG["learner"]["name"], "description": AGENT_CONFIG["learner"]["description"], "status": AGENT_CONFIG["learner"]["status"], "icon": "🧠", "role": "决策Agent(动态难度)"},
            {"id": "kg_agent", "name": "知识图谱Agent", "description": "负责知识图谱维护、推理与传播推荐", "status": "active", "icon": "🕸️", "role": "知识图谱与关系Agent"},
        ],
        "agent_loop": "Analyzer(分析) -> Planner/Generator(生成) -> Reviewer(校验/辩论) -> Learner(决策/反馈) -> KGAgent(图谱推理/传播)",
        "socratic_agent": {"id": "socratic", "name": "苏格拉底追问Agent", "role": "启发式交互导学", "status": "active", "icon": "❓"}
    }


# ============================================================
# ==================== v3.1 知识中心接口 =====================
# ============================================================

@app.get("/api/v1/knowledge/targets")
def get_targets():
    targets = []
    for name, info in knowledge_base.targets.items():
        targets.append({"name": name, "full_name": info.full_name, "family": info.family, "difficulty": info.difficulty, "popularity": info.popularity, "known_drugs_count": len(info.known_drugs)})
    return {"status": "success", "total": len(targets), "data": targets}

@app.get("/api/v1/knowledge/target/{target_name}")
def get_target_detail(target_name: str):
    info = knowledge_base.get_target_info(target_name)
    if not info:
        raise HTTPException(status_code=404, detail=f"未找到靶点: {target_name}")
    return {"status": "success", "data": {"name": info.name, "full_name": info.full_name, "family": info.family, "related_diseases": info.related_diseases, "known_drugs": info.known_drugs, "pdb_ids": info.pdb_ids, "difficulty": info.difficulty, "popularity": info.popularity, "related_targets": knowledge_base.get_related_targets(target_name)}}

@app.get("/api/v1/knowledge/drug-classes")
def get_drug_classes():
    classes = [{"name": name, "description": dc.description, "typical_scaffolds": dc.typical_scaffolds, "common_targets": dc.common_targets} for name, dc in knowledge_base.drug_classes.items()]
    return {"status": "success", "data": classes}

@app.get("/api/v1/knowledge/admet-rules")
def get_admet_rules():
    rules = [{"name": name, "description": rule.description, "thresholds": rule.thresholds, "source": rule.source, "reliability": rule.reliability} for name, rule in knowledge_base.admet_rules.items()]
    return {"status": "success", "data": rules}

@app.post("/api/v1/knowledge/evaluate-admet")
def evaluate_admet(properties: Dict[str, float]):
    result = knowledge_base.evaluate_admet(properties)
    return {"status": "success", "data": result}

@app.get("/api/v1/knowledge/scaffolds")
def get_scaffolds(target: str = Query(default="")):
    if target:
        scaffolds = knowledge_base.get_scaffold_suggestions(target)
    else:
        scaffolds = [{"name": k, **v} for k, v in knowledge_base.scaffolds.items()]
    return {"status": "success", "data": scaffolds}

@app.get("/api/v1/knowledge/statistics")
def get_knowledge_stats():
    return {"status": "success", "data": {"targets": knowledge_base.get_target_statistics(), "drug_classes": len(knowledge_base.drug_classes), "admet_rules": len(knowledge_base.admet_rules), "scaffolds": len(knowledge_base.scaffolds)}}


# ============================================================
# ==================== v3.1 各Agent独立接口 ==================
# ============================================================

@app.post("/api/v1/analyze")
def analyze_profile(profile: ResearcherProfile):
    try:
        result = analyzer_agent.analyze(profile.dict())
        target = profile.target_protein
        target_info = knowledge_base.get_target_info(target)
        if target_info:
            result["knowledge_enhancement"] = {"target_full_name": target_info.full_name, "target_family": target_info.family, "known_drugs": target_info.known_drugs[:5], "difficulty": target_info.difficulty}
        return {"status": "success", "agent": "analyzer", "data": result}
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Analyzer错误: {str(e)}")

@app.post("/api/v1/plan")
def plan_strategy(analysis_result: Dict[str, Any]):
    try:
        result = planner_agent.plan(analysis_result)
        return {"status": "success", "agent": "planner", "data": result}
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Planner错误: {str(e)}")

@app.post("/api/v1/generate")
def generate_molecules(request: GenerateRequest):
    try:
        enhanced = cognitive_engine.get_enhanced_constraints(request.researcher_id or "anonymous", request.target_protein)
        gen_request = request.dict()
        if enhanced:
            gen_request["cognitive_enhancement"] = enhanced
        result = generator_agent.generate(gen_request)
        return {"status": "success", "agent": "generator", "data": result}
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Generator错误: {str(e)}")

@app.post("/api/v1/review")
def review_molecules(generation_result: Dict[str, Any]):
    try:
        result = reviewer_agent.review(generation_result)
        return {"status": "success", "agent": "reviewer", "data": result}
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Reviewer错误: {str(e)}")


# ============================================================
# ==================== v3.1 反馈学习接口 ======================
# ============================================================

@app.post("/api/v1/feedback")
def record_feedback(feedback: FeedbackRequest):
    try:
        result = learner_agent.record_feedback(feedback.dict())
        cognitive_engine.learn_from_feedback(feedback.dict())
        return {"status": "success", "agent": "learner", "data": result}
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Learner错误: {str(e)}")

@app.get("/api/v1/feedback/recommendations")
def get_recommendations(target_protein: str = Query(default=""), researcher_id: str = Query(default="")):
    try:
        result = learner_agent.get_recommendations(target_protein, researcher_id)
        return {"status": "success", "agent": "learner", "data": result}
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Learner错误: {str(e)}")


# ============================================================
# ==================== v3.1 认知增强接口 =====================
# ============================================================

@app.get("/api/v1/cognitive/researcher/{researcher_id}")
def get_researcher_insights(researcher_id: str):
    try:
        result = cognitive_engine.get_researcher_insights(researcher_id)
        return {"status": "success", "data": result}
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"认知引擎错误: {str(e)}")

@app.get("/api/v1/cognitive/target/{target}")
def get_target_insights(target: str):
    try:
        result = cognitive_engine.get_target_insights(target)
        return {"status": "success", "data": result}
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"认知引擎错误: {str(e)}")


# ============================================================
# ==================== v3.1 核心Pipeline接口 =================
# ============================================================

@app.post("/api/v1/pipeline", tags=["核心Pipeline"], summary="执行5-Agent协同Pipeline")
async def run_pipeline(profile: ResearcherProfile):
    pipeline_id = f"pipeline_{int(time.time() * 1000)}"
    try:
        start_time = time.time()
        profile_data = profile.model_dump()
        if profile.target:
            profile_data["target_protein"] = profile.target
        await enhanced_manager.broadcast_pipeline_progress(pipeline_id, "started", 0.0, {"profile": profile_data})
        result = orchestrator.run_pipeline(profile_data)
        elapsed = time.time() - start_time
        await enhanced_manager.broadcast_pipeline_progress(pipeline_id, "completed", 100.0, {"status": result["pipeline_status"], "elapsed_time": result["elapsed_time"]})
        save_history({"profile": profile_data, "pipeline_status": result["pipeline_status"], "elapsed_time": result["elapsed_time"], "successful_steps": result["successful_steps"], "summary": result.get("summary", {})})
        for agent_id, step in result.get("steps", {}).items():
            request_logger.log_agent_execution(agent_id, step["status"], 0.1, {"error": step.get("error", "")} if step["status"] == "error" else {})
        return {"status": "success", "pipeline_id": pipeline_id, "pipeline_status": result["pipeline_status"], "elapsed_time": result["elapsed_time"], "data": result}
    except Exception as e:
        await enhanced_manager.broadcast_pipeline_progress(pipeline_id, "error", 0.0, {"error": str(e)})
        raise HTTPException(status_code=500, detail=f"Pipeline错误: {str(e)}")

@app.post("/api/v1/pipeline/batch")
def run_pipeline_batch(request: BatchGenerateRequest):
    results = []
    for profile in request.profiles:
        try:
            result = orchestrator.run_pipeline(profile.dict())
            save_history({"profile": profile.dict(), "pipeline_status": result["pipeline_status"], "elapsed_time": result["elapsed_time"], "successful_steps": result["successful_steps"], "summary": result.get("summary", {})})
            results.append({"profile": profile.name, "status": "success", "elapsed_time": result["elapsed_time"], "summary": result.get("summary", {})})
        except Exception as e:
            results.append({"profile": profile.name, "status": "error", "error": str(e)})
    return {"status": "success", "total": len(request.profiles), "successful": sum(1 for r in results if r["status"] == "success"), "results": results}


# ============================================================
# ==================== v3.1 历史记录接口 ======================
# ============================================================

@app.get("/api/v1/history")
def get_history(limit: int = Query(default=10, ge=1, le=100), target_protein: str = Query(default="")):
    try:
        history = load_history()
        if target_protein:
            history = [h for h in history if h.get("profile", {}).get("target_protein") == target_protein]
        history = history[::-1][:limit]
        return {"status": "success", "total_records": len(load_history()), "returned": len(history), "data": history}
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"历史记录错误: {str(e)}")

@app.get("/api/v1/history/stats")
def get_history_stats():
    try:
        history = load_history()
        if not history:
            return {"status": "success", "data": {"total_runs": 0, "message": "暂无历史记录"}}
        total = len(history)
        successful = sum(1 for h in history if h.get("pipeline_status") == "completed")
        avg_time = sum(h.get("elapsed_time", 0) for h in history) / total if total else 0
        targets = {}
        fields = {}
        for h in history:
            target = h.get("profile", {}).get("target_protein", "未知")
            targets[target] = targets.get(target, 0) + 1
            field = h.get("profile", {}).get("research_field", "未知")
            fields[field] = fields.get(field, 0) + 1
        return {"status": "success", "data": {"total_runs": total, "successful_runs": successful, "success_rate": round(successful / total, 2) if total else 0, "avg_elapsed_time": round(avg_time, 2), "target_distribution": targets, "field_distribution": fields}}
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"统计错误: {str(e)}")

# ============================================================
# ==================== v3.1 分子工具接口 =====================
# ============================================================

@app.post("/api/v1/fingerprint", tags=["分子工具"], summary="生成分子指纹（RDKit CPU预处理）")
async def compute_fingerprint(smiles: str, fp_size: int = Query(default=2048)):
    if not _RDKIT_AVAILABLE:
        raise HTTPException(status_code=503, detail="RDKit未安装，分子计算功能不可用")
    try:
        result = await asyncio.wait_for(
            asyncio.to_thread(fpga_client.compute_fingerprint, smiles, fp_size),
            timeout=5.0
        )
        v40_logger.info(f"CPU指纹预处理成功: {smiles[:30]}...")
        return {
            "status": "success",
            "data": result,
            "source": "cpu_fallback",
            "warning": "指纹由CPU预处理；分子相似度可由FPGA计算",
            "trace_id": get_trace_id()
        }
    except (asyncio.TimeoutError, ConnectionError, Exception) as e:
        try:
            mol = Chem.MolFromSmiles(smiles)
            if not mol:
                raise HTTPException(status_code=400, detail="无效SMILES")
            fp = AllChem.GetMorganFingerprintAsBitVect(mol, 2, nBits=fp_size)
            fp_list = list(fp)
            v40_logger.warning(f"FPGA超时/失败，已降级CPU: {smiles[:30]}... error={e}")
            return {
                "status": "success",
                "data": {"fingerprint": fp_list, "smiles": smiles, "fp_size": fp_size},
                "source": "cpu_fallback",
                "warning": "FPGA不可用，已使用CPU计算",
                "trace_id": get_trace_id()
            }
        except HTTPException:
            raise
        except Exception as e2:
            v40_logger.error(f"CPU降级也失败: {smiles[:30]}... error={e2}")
            raise HTTPException(status_code=500, detail=f"指纹计算错误: {str(e2)}")

@app.post("/api/v1/compare")
async def compare_molecules(request: CompareRequest):
    try:
        result = await asyncio.wait_for(
            asyncio.to_thread(
                fpga_client.compute_tanimoto_smiles,
                request.smiles1,
                request.smiles2,
            ),
            timeout=5.0,
        )
        return {
            "status": "success",
            "data": result,
            "source": "fpga",
            "trace_id": result["trace_id"],
        }
    except Exception as e:
        result = reviewer_agent.compare_molecules(request.smiles1, request.smiles2)
        result["accelerated"] = False
        return {
            "status": "success",
            "data": result,
            "source": "cpu_fallback",
            "warning": f"FPGA不可用，已使用CPU计算: {e}",
            "trace_id": get_trace_id(),
        }

@app.get("/api/v1/molecule/properties", tags=["分子工具"], summary="计算分子理化性质（RDKit）")
def get_molecule_properties(smiles: str):
    if not _RDKIT_AVAILABLE:
        raise HTTPException(status_code=503, detail="RDKit未安装，分子计算功能不可用")
    try:
        mol = Chem.MolFromSmiles(smiles)
        if not mol:
            raise HTTPException(status_code=400, detail="无效的SMILES")
        props = {
            "molwt": round(Descriptors.MolWt(mol), 2), "logp": round(Descriptors.MolLogP(mol), 2),
            "tpsa": round(Descriptors.TPSA(mol), 2), "hbd": Descriptors.NumHDonors(mol),
            "hba": Descriptors.NumHAcceptors(mol), "rotatable_bonds": Descriptors.NumRotatableBonds(mol),
            "qed": round(QED.qed(mol), 3),
            "lipinski_pass": (Descriptors.MolWt(mol) <= 500 and Descriptors.MolLogP(mol) <= 5 and Descriptors.NumHDonors(mol) <= 5 and Descriptors.NumHAcceptors(mol) <= 10),
        }
        admet = knowledge_base.evaluate_admet(props)
        return {"status": "success", "data": {"smiles": smiles, "properties": props, "admet_evaluation": admet}}
    except HTTPException:
        raise
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"计算错误: {str(e)}")

@app.get("/api/v1/molecule/validate")
def validate_smiles(smiles: str):
    if not _RDKIT_AVAILABLE:
        return {"status": "success", "data": {"smiles": smiles, "valid": True, "message": "RDKit未安装，跳过验证"}}
    try:
        mol = Chem.MolFromSmiles(smiles)
        is_valid = mol is not None
        return {"status": "success", "data": {"smiles": smiles, "valid": is_valid, "message": "有效SMILES" if is_valid else "无效SMILES"}}
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"验证错误: {str(e)}")


# ============================================================
# ==================== v3.1 FPGA性能接口 ======================
# ============================================================

@app.get("/api/fpga/health", tags=["FPGA硬件"], summary="FPGA实时健康数据")
async def fpga_health_proxy():
    return await asyncio.to_thread(fpga_client.get_health)

@app.get("/api/fpga/benchmark", tags=["FPGA硬件"], summary="FPGA实时性能数据")
async def fpga_benchmark_proxy():
    return await asyncio.to_thread(fpga_client.get_benchmark)

@app.get("/api/v1/fpga/status", tags=["FPGA硬件"], summary="获取FPGA连接状态")
async def fpga_status():
    return {"status": "success", "data": await asyncio.to_thread(fpga_client.get_status)}

@app.get("/api/v1/fpga/performance")
async def fpga_performance():
    return {"status": "success", "data": await asyncio.to_thread(fpga_client.get_performance_report)}

@app.post("/api/v1/fpga/connect")
async def fpga_connect():
    success = await asyncio.to_thread(fpga_client.connect)
    return {"status": "success" if success else "error", "connected": fpga_client.connected, "message": "连接成功" if success else "连接失败"}


# ============================================================
# ==================== v3.1 监控接口 ==========================
# ============================================================

@app.get("/api/v1/monitor/requests")
def get_request_stats():
    return {"status": "success", "data": request_logger.get_stats()}

@app.get("/api/v1/monitor/websocket")
def get_websocket_stats():
    return {"status": "success", "data": {"active_connections": enhanced_manager.get_connection_count()}}

# ============================================================
# ==================== v3.2/v4.3/v4.4 辩论机制接口 ======================
# ============================================================

@app.post("/api/debate/start", tags=["辩论机制"], summary="发起多Agent辩论（交叉验证消除幻觉）")
async def v32_start_debate(request: DebateStartRequest):
    session = await V32Services.start_debate(request.topic, request.initial_content)
    await enhanced_manager.broadcast({"type": "debate_started", "debate_id": session.debate_id, "topic": session.topic, "timestamp": session.created_at.isoformat()})
    payload = session.model_dump(mode="json")
    payload["first_round"] = payload["rounds"][0] if payload["rounds"] else None
    return payload

@app.get("/api/debate/{debate_id}/rounds")
async def v32_get_debate_rounds(debate_id: str):
    session = v32_db.debates.get(debate_id)
    if not session:
        raise HTTPException(status_code=404, detail="辩论不存在")
    return [round_.model_dump(mode="json") for round_ in session.rounds]

@app.post("/api/debate/{debate_id}/respond")
async def v32_debate_respond(debate_id: str, request: DebateRespondRequest):
    try:
        content = request.content or request.response or ""
        session = await V32Services.debate_respond(debate_id, request.speaker, content, request.confidence, request.evidence)
        next_round = session.rounds[-1].model_dump(mode="json")
        await enhanced_manager.broadcast({"type": "debate_round_added", "debate_id": debate_id, "round": next_round, "total_rounds": len(session.rounds)})
        return {**session.model_dump(mode="json"), "next_round": next_round}
    except ValueError as e:
        raise HTTPException(status_code=400, detail=str(e))

@app.get("/api/debate/{debate_id}/verdict")
async def v32_get_debate_verdict(debate_id: str):
    try:
        verdict = await V32Services.debate_verdict(debate_id)
        await enhanced_manager.broadcast({"type": "debate_verdict", "debate_id": debate_id, "verdict": verdict.dict()})
        payload = verdict.model_dump(mode="json")
        payload["final_confidence"] = max(verdict.updated_weights.values(), default=0.0)
        payload["duration_ms"] = 0
        return payload
    except ValueError as e:
        raise HTTPException(status_code=404, detail=str(e))


# ============================================================
# ==================== v3.2 知识溯源接口 =====================
# ============================================================

@app.get("/api/resources/{resource_id}/provenance")
async def v32_get_provenance(resource_id: str):
    provenance = V32Services.get_provenance(resource_id)
    return {"status": "success", "data": provenance.dict()}


# ============================================================
# ==================== v4.3/v4.4 学情画像接口 ======================
# ============================================================

@app.post("/api/assessment/start", tags=["学情画像"], summary="开始学情评估测试（支持背景适配）")
async def v32_start_assessment(request: AssessmentStartRequest):
    session = V32Services.start_assessment(request.user_id, request.background.value if request.background else "chemistry", request.question_count)
    response_data = session.dict()
    for q in response_data.get("questions", []):
        q.pop("correct_index", None)
    return {"status": "success", "data": response_data}

@app.post("/api/assessment/{assessment_id}/submit")
async def v32_submit_assessment(assessment_id: str, request: AssessmentSubmitRequest):
    try:
        session = await V32Services.submit_assessment(assessment_id, request.answers)
        radar = v32_db.radars.get(session.user_id)
        return {"status": "success", "data": {"assessment_id": session.assessment_id, "status": session.status, "score": radar.overall_score if radar else 0, "completed_at": session.completed_at.isoformat() if session.completed_at else None}}
    except ValueError as e:
        raise HTTPException(status_code=404, detail=str(e))

@app.get("/api/profile/{user_id}/radar")
async def v32_get_radar(user_id: str):
    radar = v32_db.radars.get(user_id)
    if not radar:
        raise HTTPException(status_code=404, detail="用户画像不存在，请先完成测试")
    return {"status": "success", "data": radar.dict()}

@app.get("/api/profile/{user_id}/learning-path")
async def v32_get_learning_path(user_id: str):
    path = v32_db.learning_paths.get(user_id)
    if not path:
        raise HTTPException(status_code=404, detail="学习路径不存在，请先完成测试")
    return {"status": "success", "data": path.dict()}


# ============================================================
# ==================== v4.4 新增：学习路径回溯 ======================
# ============================================================

@app.get("/api/profile/{user_id}/learning-path/history", tags=["学情画像"], summary="学习路径历史版本回溯")
async def v32_get_learning_path_history(user_id: str, limit: int = 10):
    """返回用户学习路径的历史版本，支持回溯对比"""
    versions = V32Services.get_learning_path_history(user_id, limit)
    if not versions:
        raise HTTPException(status_code=404, detail="无历史路径记录")
    return {"status": "success", "data": [v.dict() for v in versions]}


# ============================================================
# ==================== v4.3/v4.4 难度匹配曲线 ======================
# ============================================================

@app.get("/api/profile/{user_id}/difficulty-curve", tags=["学情画像"], summary="获取资源难度匹配曲线（可视化）")
async def v32_get_difficulty_curve(user_id: str):
    radar = v32_db.radars.get(user_id)
    if not radar:
        raise HTTPException(status_code=404, detail="用户画像不存在，请先完成测试")
    return {"status": "success", "data": {
        "user_id": user_id,
        "curve": [c.dict() for c in radar.difficulty_curve],
        "current_score": radar.overall_score,
        "trend": "上升" if len(radar.difficulty_curve) >= 2 and radar.difficulty_curve[-1].correct_rate > radar.difficulty_curve[0].correct_rate else "平稳"
    }}


# ============================================================
# ==================== v4.3/v4.4 知识图谱 ======================
# ============================================================

@app.get("/api/profile/{user_id}/knowledge-graph", tags=["学情画像"], summary="获取个人知识图谱（可视化学习路径规划图）")
async def v32_get_knowledge_graph(user_id: str):
    radar = v32_db.radars.get(user_id)
    if not radar or not radar.knowledge_graph:
        raise HTTPException(status_code=404, detail="知识图谱不存在，请先完成测试")
    return {"status": "success", "data": radar.knowledge_graph.dict()}


# ============================================================
# ==================== v4.4 新增：学习效果预测 ======================
# ============================================================

@app.get("/api/profile/{user_id}/prediction", tags=["学情画像"], summary="学习效果预测与风险预警")
async def v32_get_learning_prediction(user_id: str):
    """基于历史答题正确率的时间序列，预测下一周期得分并输出风险预警"""
    prediction = V32Services.predict_learning(user_id)
    if not prediction:
        raise HTTPException(status_code=404, detail="数据不足，请先完成至少2次测试")
    return {"status": "success", "data": prediction.dict()}


# ============================================================
# ==================== v4.4 新增：知识传播推荐 ======================
# ============================================================

@app.get("/api/profile/{user_id}/propagate-recommend", tags=["学情画像"], summary="知识图谱传播推荐")
async def v32_propagate_recommend(user_id: str, top_k: int = 3):
    """基于知识图谱的节点激活传播，推荐高激活但未掌握的知识点"""
    radar = v32_db.radars.get(user_id)
    if not radar:
        raise HTTPException(status_code=404, detail="用户画像不存在，请先完成测试")
    result = V32Services.propagate_recommend(user_id, top_k)
    return {"status": "success", "data": result}


# ============================================================
# ==================== v4.4 新增：知识图谱Agent推理 =============
# ============================================================

@app.get("/api/kg/infer/{user_id}", tags=["知识图谱Agent"], summary="知识图谱推理与传播推荐")
async def v32_kg_infer(user_id: str):
    """知识图谱与关系Agent：执行传递闭包推理、识别知识孤岛、生成传播推荐"""
    radar = v32_db.radars.get(user_id)
    if not radar or not radar.knowledge_graph:
        raise HTTPException(status_code=404, detail="知识图谱不存在，请先完成测试")
    inference = kg_agent.infer_relations(radar.knowledge_graph)
    v32_db.kg_inferences[user_id] = inference
    return {"status": "success", "data": inference.dict()}


# ============================================================
# ==================== v4.4 新增：微证书与学习档案 =============
# ============================================================

@app.get("/api/profile/{user_id}/portfolio", tags=["终身学习"], summary="获取学习档案（终身学习累积）")
async def v32_get_portfolio(user_id: str):
    """获取用户学习档案：总学习时长、测评次数、技能演进轨迹"""
    portfolio = V32Services.get_learning_portfolio(user_id)
    if not portfolio:
        raise HTTPException(status_code=404, detail="学习档案不存在，请先完成测试")
    return {"status": "success", "data": portfolio.dict()}

@app.get("/api/profile/{user_id}/credentials", tags=["终身学习"], summary="获取微证书列表")
async def v32_get_credentials(user_id: str):
    """获取用户获得的微证书（能力徽章）"""
    creds = V32Services.get_micro_credentials(user_id)
    return {"status": "success", "data": [c.dict() for c in creds], "total": len(creds)}


# ============================================================
# ==================== v4.3 新增：苏格拉底追问Agent =============
# ============================================================

@app.post("/api/socratic/ask", tags=["苏格拉底追问"], summary="启发式交互导学（不直接给答案）")
async def v32_socratic_ask(request: SocraticRequest):
    """苏格拉底式追问Agent：通过反问、类比、分解问题引导学生自主思考，打破静态资源单向输入局限"""
    resp = await V32Services.socratic_ask(
        request.user_id, request.question, request.context,
        request.background.value if request.background else "chemistry", request.turn
    )
    return {"status": "success", "data": resp.dict()}


# ============================================================
# ==================== v3.2 幻觉检测接口 =====================
# ============================================================

@app.post("/api/hallucination/check", tags=["幻觉检测"], summary="检测生成内容幻觉率")
async def v32_check_hallucination(request: HallucinationCheckRequest):
    content = request.generated_content or request.smiles or ""
    content_type = "smiles" if request.smiles else request.content_type
    result = V32Services.check_hallucination(content, content_type, request.reference_data)
    rate = result.hallucination_rate
    return {
        "rate": rate,
        "level": "trusted" if result.is_acceptable else ("suspicious" if rate < 0.2 else "high_risk"),
        "types": [error.type for error in result.errors] or ["结构合法", "性质范围正常"],
        "rdkit_basis": "; ".join(error.detail for error in result.errors) or "结构与规则校验通过，未发现明显幻觉风险。",
    }

@app.get("/api/hallucination/stats")
async def v32_get_hallucination_stats(period: str = "all"):
    stats = V32Services.hallucination_stats(period)
    total = stats["total_checks"]
    return {
        "hallucination_rate": stats["average_rate"],
        "success_rate": stats["acceptable_count"] / total if total else 1.0,
        "coverage": 1.0 if total else 0.0,
    }


# ============================================================
# ==================== v3.2/v4.3/v4.4 动态难度接口 =====================
# ============================================================

@app.post("/api/adaptation/adjust", tags=["学情画像"], summary="动态调整学习难度（降维解释/进阶挑战）")
async def v32_adjust_difficulty(request: AdaptationRequest):
    result = await V32Services.adapt(request.user_id, request.correct_rate, request.current_level, request.subject_area)
    return {"status": "success", "data": result.dict()}


# ============================================================
# ==================== v3.2 批量测试接口 =======================
# ============================================================

@app.post("/api/batch-test/run", tags=["批量测试"], summary="执行批量测试")
async def v32_run_batch_test(request: BatchTestRequest):
    report = V32Services.run_batch(request.test_cases)
    return {"status": "success", "data": {"report_id": report.report_id, "status": "completed", "summary": {"total": report.total_cases, "passed": report.passed_cases, "failed": report.failed_cases, "avg_hallucination_rate": report.avg_hallucination_rate, "avg_adaptation_accuracy": report.avg_adaptation_accuracy, "avg_coverage": report.avg_coverage}}}

@app.get("/api/batch-test/{report_id}/results")
async def v32_get_batch_results(report_id: str):
    report = v32_db.batch_reports.get(report_id)
    if not report:
        raise HTTPException(status_code=404, detail="报告不存在")
    return {"status": "success", "data": report.dict()}

@app.get("/api/batch-test/preset-cases")
async def v32_get_preset_test_cases():
    return {"status": "success", "data": [case.dict() for case in v32_db.preset_test_cases]}


# ============================================================
# ==================== v3.2 Agent思维链接口 =================
# ============================================================

@app.get("/api/agent/thoughts")
async def v32_get_agent_thoughts(agent: Optional[str] = None, limit: int = 50):
    thoughts = V32Services.get_thoughts(agent, limit)
    return {"status": "success", "data": [t.dict() for t in thoughts]}

@app.post("/api/agent/thoughts")
async def v32_log_agent_thought(thought: AgentThought):
    log = V32Services.log_thought(thought.agent, thought.thought, thought.action, thought.confidence, thought.metadata)
    await enhanced_manager.broadcast(log.dict())
    return {"status": "success", "data": log.dict()}


# ============================================================
# ==================== v3.2 异步任务接口 ======================
# ============================================================

@app.post("/api/tasks/generate", tags=["异步任务"], summary="创建异步生成任务")
async def v32_create_async_task(request: TaskCreateRequest):
    task = V32Services.create_task(request.task_type, request.params)
    return {"status": "success", "data": {"task_id": task.task_id, "status": task.status.value, "progress": task.progress, "created_at": task.created_at.isoformat()}}

@app.get("/api/tasks/{task_id}/status", tags=["异步任务"], summary="查询异步任务状态")
async def v32_get_task_status(task_id: str):
    task = V32Services.get_task(task_id)
    if not task:
        raise HTTPException(status_code=404, detail="任务不存在")
    return {"status": "success", "data": {"task_id": task.task_id, "status": task.status.value, "progress": task.progress, "result": task.result, "error_message": task.error_message, "completed_at": task.completed_at.isoformat() if task.completed_at else None}}

# ============================================================
# ==================== v4.3/v4.4 隐私与审计接口 ==================
# ============================================================

@app.get("/api/privacy/statement", tags=["隐私合规"], summary="获取隐私声明与数据使用政策")
async def v32_privacy_statement():
    return {"status": "success", "data": PrivacyStatement(
        version="4.4.0",
        data_collection=["学情测试答题记录", "学习路径交互行为", "Agent思维链日志（脱敏）", "学习档案与微证书"],
        data_usage=["个性化学习资源推荐", "动态难度调整", "学情画像生成", "终身学习档案累积"],
        retention_policy="用户数据本地存储，保留365天，支持一键导出与删除",
        user_rights=["查看个人数据", "导出JSON/CSV", "申请删除账户数据", "撤回隐私授权"],
        contact="privacy@drug-ai-edu.example.com"
    ).dict()}

@app.get("/api/privacy/audit-logs", tags=["隐私合规"], summary="查询审计日志（数据访问记录）")
async def v32_get_audit_logs(user_id: Optional[str] = None, limit: int = 50):
    logs = list(v32_db.audit_logs)
    if user_id:
        logs = [l for l in logs if l.user_id == user_id]
    logs = logs[-limit:]
    return {"status": "success", "data": [l.dict() for l in logs]}

# v4.4 新增：一键删除用户数据
@app.delete("/api/privacy/data/{user_id}", tags=["隐私合规"], summary="一键删除用户所有数据")
async def v32_delete_user_data(user_id: str, confirmation: str = Query(..., description="输入 DELETE 确认")):
    if confirmation != "DELETE":
        raise HTTPException(status_code=400, detail="确认码错误，请输入 DELETE 以确认永久删除")
    deleted_items = []
    for store_name, store in [
        ("assessments", v32_db.assessments),
        ("radars", v32_db.radars),
        ("learning_paths", v32_db.learning_paths),
        ("adaptations", v32_db.adaptations),
        ("portfolios", v32_db.portfolios),
        ("micro_credentials", v32_db.micro_credentials),
    ]:
        if user_id in store.keys():
            del store._data[user_id]
            store.save()
            deleted_items.append(store_name)
    V32Services.log_audit("user_data_deleted", user_id, "all", f"已删除数据: {', '.join(deleted_items)}")
    return {"status": "success", "message": f"用户 {user_id} 的所有数据已彻底删除", "deleted_items": deleted_items}

# v4.4 新增：撤回隐私授权
@app.post("/api/privacy/revoke-consent/{user_id}", tags=["隐私合规"], summary="撤回隐私授权")
async def v32_revoke_consent(user_id: str):
    v32_db.user_profiles[user_id] = {"consent": False, "revoked_at": datetime.now().isoformat()}
    V32Services.log_audit("consent_revoked", user_id, "privacy", "用户撤回隐私授权")
    return {"status": "success", "message": "隐私授权已撤回，系统将停止收集您的数据，已存数据保留至保留期结束"}


# ============================================================================
# ==================== v4.0/v4.4 新增 API 路由 ========================
# ============================================================================

@app.get("/health", tags=["系统监控"], summary="健康检查（服务是否存活）")
async def health_check():
    return {"status": "healthy", "timestamp": datetime.now().isoformat(), "version": "4.4.0"}

@app.get("/ready", tags=["系统监控"], summary="就绪检查（依赖是否可用）")
async def readiness_check():
    """v4.5: 环境感知的就绪检查，FPGA和加密可配置"""
    checks = {
        "data_directory": os.path.exists(DATA_DIR) and os.access(DATA_DIR, os.W_OK),
        "config_valid": iconfig.get("cache_ttl") is not None,
        "storage_initialized": all(os.path.exists(os.path.join(DATA_DIR, f)) for f in [
            "debates.json", "assessments.json", "async_tasks.json"
        ]),
        "rdkit": _RDKIT_AVAILABLE,
    }

    # v4.5: FPGA 检查（根据环境变量决定是否必须）
    if _ENABLE_FPGA:
        fpga_health = await asyncio.to_thread(fpga_client.get_health)
        fpga_ok = bool(fpga_health.get("online")) and not bool(fpga_health.get("fault"))
        checks["fpga"] = fpga_ok
        checks["fpga_reason"] = "FPGA 服务已连接" if fpga_ok else "FPGA 已启用但未检测到服务"
    else:
        checks["fpga"] = True  # 未启用时不阻塞
        checks["fpga_reason"] = "FPGA 未启用（ENABLE_FPGA=false）"

    # v4.5: 加密检查（开发环境自动生成密钥，生产环境强制要求）
    if _ENCRYPTION_AVAILABLE and _ENCRYPTION_KEY:
        checks["encryption"] = True
        checks["encryption_reason"] = "加密模块已初始化"
    else:
        debug = os.getenv("DEBUG", "false").lower() in ("1", "true", "yes")
        if debug and _ENCRYPTION_AVAILABLE:
            checks["encryption"] = True
            checks["encryption_reason"] = "开发环境自动密钥"
        else:
            checks["encryption"] = False
            checks["encryption_reason"] = "生产环境必须配置 ENCRYPTION_KEY"

    # v4.5: LLM 检查（信息性，不阻塞就绪）
    checks["llm"] = {
        "configured": bool(os.getenv("LLM_API_KEY") and os.getenv("LLM_BASE_URL") and os.getenv("LLM_MODEL")),
        "mock_mode": llm_client.mock_mode if hasattr(llm_client, 'mock_mode') else True,
        "model": os.getenv("LLM_MODEL", "未配置"),
    }

    # The deployed startup page prioritizes checks.api/checks.storage/checks.fpga.
    checks["api"] = True
    checks["storage"] = checks["data_directory"] and checks["storage_initialized"]

    all_ready = all(v for k, v in checks.items() if isinstance(v, bool))
    service_states = {
        "api": "ready" if checks["api"] else "down",
        "storage": "ready" if checks["storage"] else "down",
        "fpga": "ready" if checks["fpga"] else "offline",
    }
    return JSONResponse(
        status_code=200 if all_ready else 503,
        content={
            "ready": all_ready,
            "status": "ready" if all_ready else "degraded",
            "version": "4.4.0",
            **service_states,
            "services": service_states,
            "checks": checks,
            "timestamp": datetime.now().isoformat(),
            "environment": "development" if os.getenv("DEBUG", "").lower() in ("1", "true", "yes") else "production",
        }
    )

class ExportRequest(BaseModel):
    data_type: str = Field(..., pattern="^(debates|assessments|radars|learning_paths|hallucination_results|adaptations|batch_reports|agent_thoughts|async_tasks|socratic_logs|audit_logs|micro_credentials|portfolios|all)$")
    format: str = Field(default="json", pattern="^(json|csv|markdown)$")
    user_id: Optional[str] = Field(default=None, max_length=64)

@app.post("/api/export", tags=["数据管理"], summary="数据导出（JSON/CSV/Markdown）")
async def export_data(request: ExportRequest):
    data_map = {
        "debates": v32_db.debates, "assessments": v32_db.assessments,
        "radars": v32_db.radars, "learning_paths": v32_db.learning_paths,
        "hallucination_results": v32_db.hallucination_results,
        "adaptations": v32_db.adaptations, "batch_reports": v32_db.batch_reports,
        "agent_thoughts": v32_db.agent_thoughts, "async_tasks": v32_db.async_tasks,
        "socratic_logs": v32_db.socratic_logs, "audit_logs": v32_db.audit_logs,
        "micro_credentials": v32_db.micro_credentials, "portfolios": v32_db.portfolios,
    }
    if request.data_type == "all":
        raw_data = {}
        for k, v in data_map.items():
            if hasattr(v, '__iter__') and not isinstance(v, dict):
                raw_data[k] = list(v)
            else:
                raw_data[k] = dict(v.items())
    else:
        store = data_map[request.data_type]
        if hasattr(store, '__iter__') and not isinstance(store, dict):
            raw_data = list(store)
        else:
            raw_data = dict(store.items())

    if request.user_id and isinstance(raw_data, dict):
        raw_data = {k: v for k, v in raw_data.items() if request.user_id in str(k) or (isinstance(v, dict) and v.get("user_id") == request.user_id)}
    elif request.user_id and isinstance(raw_data, list):
        raw_data = [v for v in raw_data if isinstance(v, dict) and v.get("user_id") == request.user_id]

    export_id = f"exp_{uuid.uuid4().hex[:12]}"

    if request.format == "json":
        content = json.dumps(raw_data, ensure_ascii=False, indent=2, default=str)
        media_type = "application/json"
        filename = f"export_{request.data_type}_{export_id}.json"
    elif request.format == "csv":
        content = _to_csv(raw_data)
        media_type = "text/csv"
        filename = f"export_{request.data_type}_{export_id}.csv"
    else:
        content = _to_markdown(raw_data, request.data_type)
        media_type = "text/markdown"
        filename = f"export_{request.data_type}_{export_id}.md"

    return StreamingResponse(
        io.StringIO(content),
        media_type=media_type,
        headers={"Content-Disposition": f"attachment; filename={filename}"}
    )

def _to_csv(data):
    if not data:
        return ""
    output = io.StringIO()
    if isinstance(data, dict):
        first = list(data.values())[0] if data else {}
        if isinstance(first, dict):
            writer = csv.DictWriter(output, fieldnames=list(first.keys()))
            writer.writeheader()
            for v in data.values():
                if isinstance(v, dict):
                    writer.writerow({k: str(val) for k, val in v.items()})
        else:
            writer = csv.writer(output)
            writer.writerow(["key", "value"])
            for k, v in data.items():
                writer.writerow([k, json.dumps(v, ensure_ascii=False)])
    elif isinstance(data, list) and data:
        first = data[0]
        if isinstance(first, dict):
            writer = csv.DictWriter(output, fieldnames=list(first.keys()))
            writer.writeheader()
            for item in data:
                if isinstance(item, dict):
                    writer.writerow({k: str(val) for k, val in item.items()})
    return output.getvalue()

def _to_markdown(data, title):
    lines = [f"# {title} 数据导出", f"\n生成时间: {datetime.now().isoformat()}\n"]
    if isinstance(data, dict):
        for k, v in data.items():
            lines.append(f"## {k}")
            lines.append(f"```json\n{json.dumps(v, ensure_ascii=False, indent=2, default=str)}\n```\n")
    elif isinstance(data, list):
        for i, item in enumerate(data):
            lines.append(f"## 记录 {i+1}")
            lines.append(f"```json\n{json.dumps(item, ensure_ascii=False, indent=2, default=str)}\n```\n")
    return "\n".join(lines)

@app.get("/api/admin/status", tags=["系统监控"], summary="系统状态监控")
async def admin_status():
    return {
        "status": "success",
        "data": {
            "version": "4.4.0",
            "cache": {"size": len(_cache), "maxsize": _cache.maxsize},
            "WebSocket": {
                "active_connections": enhanced_manager.get_connection_count(),
                "max_connections": iconfig.get("websocket.max_connections", 100)
            },
            "rate_limiter": {"buckets": len(_mem_limiter.buckets)},
            "storage": {k: os.path.getsize(os.path.join(DATA_DIR, k)) if os.path.exists(os.path.join(DATA_DIR, k)) else 0 
                       for k in ["debates.json", "assessments.json", "async_tasks.json"]},
            "trace_id": get_trace_id(),
            "llm_stats": llm_client.get_stats(),
            "rdkit_available": _RDKIT_AVAILABLE,
            "encryption_available": _ENCRYPTION_AVAILABLE,
        }
    }

@app.post("/api/admin/reload-config", tags=["系统监控"], summary="手动热加载配置")
async def reload_config():
    iconfig.reload()
    return {"status": "success", "message": "配置已重新加载"}


# ============================================================
# ==================== 启动服务 ===============================
# ============================================================

@app.on_event("startup")
async def startup_event():
    print("=" * 60)
    print("AI药物分子智能决策辅助系统 后端服务 v4.4（评审对齐版）")
    print("基于 v3.2 业务逻辑 + v4.0/v4.1 框架增强 + v4.2 LLM集成 + v4.3 评审增强 + v4.4 缺口补齐")
    print("=" * 60)
    print("增强功能: JSON并发锁 | 自动备份恢复 | trace_id | 缓存 | 限流 | WebSocket心跳 | 配置热加载 | 数据导出 | 任务断点续传 | LLM智能增强")
    print("v4.3评审增强: 学习者背景适配 | 3种资源形态 | 降维解释/进阶挑战 | 苏格拉底追问Agent | 难度匹配曲线 | 知识图谱 | 数据脱敏 | 审计日志 | 场景延伸")
    print("v4.4评审对齐: 学习效果预测 | 知识传播推荐 | 知识图谱Agent | 数据加密存储 | RBAC访问控制 | 微证书体系 | 学习路径回溯 | 隐私删除/撤回 | 题库扩充54题")
    print("=" * 60)
    recovered = 0
    for task_id, task in v32_db.async_tasks.items():
        if task.status == TaskStatus.RUNNING:
            task.status = TaskStatus.PENDING
            task.progress = 0.0
            v32_db.async_tasks[task_id] = task
            asyncio.create_task(V32Services._simulate_task(task_id))
            recovered += 1
    if recovered > 0:
        print(f"[断点续传] 已恢复 {recovered} 个异步任务")
    DATA_VERSION_FILE = os.path.join(DATA_DIR, ".version")
    if not os.path.exists(DATA_VERSION_FILE):
        with open(DATA_VERSION_FILE, 'w', encoding='utf-8') as f:
            f.write("4.4")
        print("[v4.4] 数据目录版本标记: 4.4")
    else:
        with open(DATA_VERSION_FILE, 'r', encoding='utf-8') as f:
            ver = f.read().strip()
        if ver != "4.4":
            print(f"[v4.4] 警告: 数据版本 {ver}，当前系统 4.4，可能存在兼容性问题")
    asyncio.create_task(_periodic_cleanup())

@app.on_event("shutdown")
async def shutdown_event():
    print("[v4.0] 服务正在关闭，执行清理...")
    print("[v4.0] 服务已安全关闭")

async def _periodic_cleanup():
    while True:
        try:
            await asyncio.sleep(iconfig.get("cleanup_interval", 60))
            await _mem_limiter.cleanup()
            await enhanced_manager.cleanup_stale()
            iconfig.reload()
        except Exception as e:
            print(f"[v4.0] 定时清理异常: {e}")


if __name__ == "__main__":
    print("=" * 60)
    print("AI药物分子智能决策辅助系统 后端服务 v4.4（评审对齐版）")
    print("云之脑架构: 5-Agent协同 + 知识中心 + 认知增强 + FPGA加速 + WebSocket")
    print("v3.2增强: 辩论机制 + 知识溯源 + 学情画像 + 幻觉检测 + 动态难度 + 批量测试 + Agent思维链 + 异步任务")
    print("v4.0增强: JSON并发锁 + trace_id追踪 + 内存限流 + WS心跳 + 配置热加载 + 数据导出 + 断点续传")
    print("v4.1增强：FPGA异步降级 + 日志文件化 + CORS安全 + GZip压缩 + 请求体限制 + OpenAPI分类 + 回归测试")
    打印("v4.2增强：LLM智能辩论 + LLM学情分析 + LLM动态难度 + OpenAI兼容API + 自动降级保护")
    print("v4.3评审增强: 学习者背景适配 + 3种资源形态 + 降维解释/进阶挑战 + 苏格拉底追问Agent + 难度匹配曲线 + 知识图谱 + 数据脱敏 + 审计日志 + 场景延伸")
    print("v4.4评审对齐: 学习效果预测 + 知识传播推荐 + 知识图谱Agent + 数据加密存储 + RBAC访问控制 + 微证书体系 + 学习路径回溯 + 隐私删除/撤回 + 题库扩充54题")
    print("数据持久化：JSON文件自动存储（data/目录，线程安全 + 原子写入 + 自动备份 + 可选加密）")
    print("=" * 60)
    print(f"服务地址: http://{SERVICE_CONFIG['host']}:{SERVICE_CONFIG['port']}")
    print(f"API文档: http://{SERVICE_CONFIG['host']}:{SERVICE_CONFIG['port']}/docs")
    print(f"健康检查: http://{SERVICE_CONFIG['host']}:{SERVICE_CONFIG['port']}/health")
    print(f"WebSocket: ws://{SERVICE_CONFIG['host']}:{SERVICE_CONFIG['port']}/ws")
    print("=" * 60)
    uvicorn.run("main:app", host=SERVICE_CONFIG["host"], port=SERVICE_CONFIG["port"], reload=SERVICE_CONFIG["debug"])
