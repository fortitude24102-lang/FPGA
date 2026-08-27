import asyncio
import unittest

import httpx

from main import app


class CorsPreflightTest(unittest.TestCase):
    def test_pages_frontend_can_preflight_backend_routes(self):
        async def request():
            transport = httpx.ASGITransport(app=app)
            async with httpx.AsyncClient(transport=transport, base_url="http://testserver") as client:
                return await client.options(
                    "/api/v1/pipeline",
                    headers={
                        "Origin": "https://molrecommender.pages.dev",
                        "Access-Control-Request-Method": "POST",
                        "Access-Control-Request-Headers": "content-type,x-trace-id,x-user-role",
                    },
                )

        response = asyncio.run(request())

        self.assertEqual(response.status_code, 200)
        self.assertEqual(
            response.headers.get("access-control-allow-origin"),
            "https://molrecommender.pages.dev",
        )


if __name__ == "__main__":
    unittest.main()
