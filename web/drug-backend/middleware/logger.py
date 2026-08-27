"""
请求日志中间件
功能：记录所有请求和Agent执行日志
对应云之脑架构：韧性保障系统 - 监控与日志
"""
import time
import json
import logging
from typing import Dict, Any
from datetime import datetime
from fastapi import Request

# 配置日志
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s',
    handlers=[
        logging.FileHandler('requests.log', encoding='utf-8'),
        logging.StreamHandler()
    ]
)
req_logger = logging.getLogger('requests')
agent_logger = logging.getLogger('agents')

class RequestLogger:
    """请求日志记录器"""

    def __init__(self):
        self.stats = {
            "total_requests": 0,
            "total_errors": 0,
            "avg_response_time": 0,
            "endpoint_stats": {},
        }

    def log_request(self, request: Request, response_status: int, duration: float):
        """记录请求日志"""
        self.stats["total_requests"] += 1

        endpoint = request.url.path
        if endpoint not in self.stats["endpoint_stats"]:
            self.stats["endpoint_stats"][endpoint] = {
                "count": 0,
                "errors": 0,
                "avg_time": 0,
            }

        ep_stat = self.stats["endpoint_stats"][endpoint]
        ep_stat["count"] += 1
        if response_status >= 400:
            ep_stat["errors"] += 1
            self.stats["total_errors"] += 1

        # 更新平均响应时间
        ep_stat["avg_time"] = (ep_stat["avg_time"] * (ep_stat["count"] - 1) + duration) / ep_stat["count"]

        log_data = {
            "timestamp": datetime.now().isoformat(),
            "method": request.method,
            "path": endpoint,
            "client_ip": request.client.host if request.client else "unknown",
            "status_code": response_status,
            "duration_ms": round(duration * 1000, 2),
            "user_agent": request.headers.get("user-agent", ""),
        }

        if response_status >= 400:
            req_logger.warning(f"请求异常: {json.dumps(log_data, ensure_ascii=False)}")
        else:
            req_logger.info(f"请求记录: {json.dumps(log_data, ensure_ascii=False)}")

    def log_agent_execution(self, agent_name: str, status: str, duration: float, details: Dict = None):
        """记录Agent执行日志"""
        log_data = {
            "timestamp": datetime.now().isoformat(),
            "agent": agent_name,
            "status": status,
            "duration_ms": round(duration * 1000, 2),
            "details": details or {},
        }
        agent_logger.info(f"Agent执行: {json.dumps(log_data, ensure_ascii=False)}")

    def get_stats(self) -> Dict[str, Any]:
        """获取统计信息"""
        total = self.stats["total_requests"]
        return {
            "total_requests": total,
            "total_errors": self.stats["total_errors"],
            "error_rate": round(self.stats["total_errors"] / total, 4) if total else 0,
            "endpoint_stats": self.stats["endpoint_stats"],
        }

# 单例实例
request_logger = RequestLogger()

async def logging_middleware(request: Request, call_next):
    """日志中间件"""
    start_time = time.time()

    response = await call_next(request)

    duration = time.time() - start_time
    request_logger.log_request(request, response.status_code, duration)

    return response
