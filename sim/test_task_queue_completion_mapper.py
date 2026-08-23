"""Guard the fixed-depth scoreboard's constant-time completion lookup."""

from pathlib import Path
import unittest


RTL = Path(__file__).resolve().parents[1] / "rtl" / "dma_task_queue.v"


class CompletionMapperStructureTest(unittest.TestCase):
    def test_six_bit_sequence_uses_a_live_slot_map_not_a_linear_cam(self):
        source = RTL.read_text(encoding="utf-8")
        self.assertIn("reg [4:0] sequence_slot [0:63];", source)
        self.assertIn("reg sequence_live [0:63];", source)
        self.assertIn("sequence_slot[done_sequence_safe]", source)
        self.assertIn("sequence_live[done_sequence_safe]", source)
        self.assertNotIn("done_entry_match_bits", source)


if __name__ == "__main__":
    unittest.main()
