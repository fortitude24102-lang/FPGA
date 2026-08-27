import json
import os
import tempfile
import unittest
from unittest.mock import patch

from main import SafeJSONStorage


class StorageCloudFileFallbackTest(unittest.TestCase):
    def test_writes_directly_when_windows_refuses_atomic_replace(self):
        with tempfile.TemporaryDirectory() as directory:
            path = os.path.join(directory, "state.json")
            storage = SafeJSONStorage(path, {})

            with patch("main.os.replace", side_effect=PermissionError("cloud file")):
                storage.write({"saved": True})

            with open(path, encoding="utf-8") as handle:
                self.assertEqual(json.load(handle), {"saved": True})


if __name__ == "__main__":
    unittest.main()
