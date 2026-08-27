"""
配置文件 v3 - 药物分子设计平台后端配置
"""

# 服务配置
SERVICE_CONFIG = {
    "host": "0.0.0.0",
    "port": 8000,
    "debug": True,
}

# CORS配置
CORS_CONFIG = {
    "allow_origins": ["*"],
    "allow_credentials": True,
    "allow_methods": ["*"],
    "allow_headers": ["*"],
}

# Agent配置
AGENT_CONFIG = {
    "analyzer": {
        "name": "需求分析Agent",
        "description": "解析研究员画像，提取药物设计需求",
        "status": "active"
    },
    "planner": {
        "name": "策略规划Agent", 
        "description": "根据需求生成药物设计策略和步骤",
        "status": "active"
    },
    "generator": {
        "name": "分子生成Agent",
        "description": "基于RDKit生成候选药物分子",
        "status": "active"
    },
    "reviewer": {
        "name": "审核裁判Agent",
        "description": "对生成分子进行多维度打分和过滤",
        "status": "active"
    },
    "learner": {
        "name": "反馈学习Agent",
        "description": "记录反馈，优化后续推荐策略",
        "status": "active"
    }
}

# FPGA配置
FPGA_CONFIG = {
    "host": "localhost",
    "port": 5001,
    "enabled": False,  # 暂时未启用，等FPGA同学对接后改为True
}

# 分子生成配置
MOLECULE_CONFIG = {
    "max_generate_count": 10,
    "default_generate_count": 5,
    "min_molwt": 200,
    "max_molwt": 600,
    "min_logp": -2,
    "max_logp": 5,
}

# 评分权重
SCORING_WEIGHTS = {
    "lipinski": 0.25,
    "qed": 0.25,
    "sa_score": 0.20,
    "mw": 0.10,
    "logp": 0.10,
    "tpsa": 0.10,
}

# 认知引擎配置
COGNITIVE_CONFIG = {
    "learning_rate": 0.1,
    "memory_size": 100,
    "feedback_threshold": 5,  # 最少反馈数才开始学习
}

# 限流配置
RATE_LIMIT_CONFIG = {
    "default": {"requests": 100, "window": 60},
    "pipeline": {"requests": 20, "window": 60},
    "generate": {"requests": 30, "window": 60},
    "feedback": {"requests": 50, "window": 60},
}
