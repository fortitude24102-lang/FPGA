import unittest

from main import RBACMiddleware


class FPGARBACContractTest(unittest.TestCase):
    def test_read_only_fpga_status_routes_are_public(self):
        for path in (
            "/api/fpga/health",
            "/api/fpga/benchmark",
            "/api/v1/fpga/status",
            "/api/v1/fpga/performance",
        ):
            with self.subTest(path=path):
                self.assertTrue(RBACMiddleware.check_permission(path, "student"))


if __name__ == "__main__":
    unittest.main()
