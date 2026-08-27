"""
全局异常处理中间件
功能：统一错误响应格式，记录错误日志
对应云之脑架构：韧性保障系统
"""
from fastapi import Request
from fastapi.responses import JSONResponse
from fastapi.exceptions import RequestValidationError
import traceback
import logging
import time
from typing import Dict, Any

# 配置日志
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s',
    handlers=[
        logging.FileHandler('app.log', encoding='utf-8'),
        logging.StreamHandler()
    ]
)
logger = logging.getLogger(__name__)

class ErrorResponse:
    """统一错误响应格式"""

    @staticmethod
    def create(
        status_code: int,
        error_type: str,
        message: str,
        details: Dict[str, Any] = None
    ) -> Dict[str, Any]:
        return {
            "status": "error",
            "error": {
                "type": error_type,
                "code": status_code,
                "message": message,
                "details": details or {},
                "timestamp": time.strftime("%Y-%m-%d %H:%M:%S"),
            }
        }

async def global_exception_handler(request: Request, exc: Exception):
    """全局异常处理器"""
    error_msg = str(exc)
    stack_trace = traceback.format_exc()

    logger.error(f"未捕获异常: {error_msg}\n{stack_trace}")

    return JSONResponse(
        status_code=500,
        content=ErrorResponse.create(
            status_code=500,
            error_type="internal_error",
            message="服务器内部错误",
            details={
                "path": str(request.url.path),
                "method": request.method,
                "error": error_msg,
            }
        )
    )

async def validation_exception_handler(request: Request, exc: RequestValidationError):
    """请求参数验证错误处理器"""
    errors = []
    for error in exc.errors():
        errors.append({
            "field": " -> ".join(str(x) for x in error["loc"]),
            "message": error["msg"],
            "type": error["type"],
        })

    logger.warning(f"参数验证错误: {errors}")

    return JSONResponse(
        status_code=422,
        content=ErrorResponse.create(
            status_code=422,
            error_type="validation_error",
            message="请求参数验证失败",
            details={"errors": errors}
        )
    )

async def http_exception_handler(request: Request, exc):
    """HTTP异常处理器"""
    from fastapi import HTTPException
    if isinstance(exc, HTTPException):
        logger.warning(f"HTTP异常 {exc.status_code}: {exc.detail}")
        return JSONResponse(
            status_code=exc.status_code,
            content=ErrorResponse.create(
                status_code=exc.status_code,
                error_type="http_error",
                message=exc.detail,
            )
        )
    raise exc
