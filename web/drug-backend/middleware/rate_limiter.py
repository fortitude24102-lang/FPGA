"""
请求限流中间件
功能：防止接口被刷，保护后端服务
对应云之脑架构：韧性保障系统
"""
import time
from typing import Dict, List, Optional
from fastapi import Request, HTTPException
from collections import defaultdict

class RateLimiter:
    """限流器 - 基于滑动窗口"""

    def __init__(self):
        # IP -> 请求记录 [(timestamp, count), ...]
        self.requests: Dict[str, List[float]] = defaultdict(list)

        # 限流配置
        self.limits = {
            "default": {"requests": 100, "window": 60},  # 默认: 60秒100次
            "pipeline": {"requests": 20, "window": 60},  # Pipeline: 60秒20次
            "generate": {"requests": 30, "window": 60},  # 生成: 60秒30次
            "feedback": {"requests": 50, "window": 60}, # 反馈: 60秒50次
        }

        # IP白名单
        self.whitelist = {"127.0.0.1", "localhost"}

    def is_allowed(self, client_ip: str, endpoint: str = "default") -> tuple[bool, dict]:
        """
        检查请求是否允许

        Returns:
            (是否允许, 限流信息)
        """
        # 白名单直接通过
        if client_ip in self.whitelist:
            return True, {"limit": "unlimited", "remaining": -1}

        # 获取限流配置
        limit_config = self.limits.get(endpoint, self.limits["default"])
        max_requests = limit_config["requests"]
        window = limit_config["window"]

        now = time.time()

        # 清理过期记录
        self.requests[client_ip] = [
            t for t in self.requests[client_ip]
            if now - t < window
        ]

        # 检查是否超过限制
        current_count = len(self.requests[client_ip])

        if current_count >= max_requests:
            # 计算重置时间
            oldest = min(self.requests[client_ip]) if self.requests[client_ip] else now
            reset_time = oldest + window

            return False, {
                "limit": max_requests,
                "remaining": 0,
                "reset_at": reset_time,
                "retry_after": int(reset_time - now),
            }

        # 记录本次请求
        self.requests[client_ip].append(now)

        return True, {
            "limit": max_requests,
            "remaining": max_requests - current_count - 1,
            "reset_at": now + window,
        }

    def get_endpoint_type(self, path: str) -> str:
        """根据路径判断端点类型"""
        if "/pipeline" in path:
            return "pipeline"
        elif "/generate" in path:
            return "generate"
        elif "/feedback" in path:
            return "feedback"
        return "default"

# 单例实例
rate_limiter = RateLimiter()

async def rate_limit_middleware(request: Request, call_next):
    """限流中间件"""
    # 获取客户端IP
    client_ip = request.headers.get("X-Forwarded-For", request.client.host)

    # 判断端点类型
    endpoint = rate_limiter.get_endpoint_type(request.url.path)

    # 检查限流
    allowed, info = rate_limiter.is_allowed(client_ip, endpoint)

    if not allowed:
        raise HTTPException(
            status_code=429,
            detail={
                "error": "请求过于频繁",
                "retry_after": info["retry_after"],
                "limit": info["limit"],
            }
        )

    # 添加限流信息到响应头
    response = await call_next(request)
    response.headers["X-RateLimit-Limit"] = str(info["limit"])
    response.headers["X-RateLimit-Remaining"] = str(info["remaining"])

    return response
