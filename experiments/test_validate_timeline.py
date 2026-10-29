import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

VALIDATOR = Path(__file__).with_name("validate_timeline.py")


class TimelineValidationTests(unittest.TestCase):
    def rows(self):
        return [
            {"event": "audio_start", "sessionIndex": 1, "elapsedMs": 0},
            {"event": "audio_frame", "sessionIndex": 1, "elapsedMs": 0, "index": 0, "samples": 8000},
            {"event": "audio_fed", "sessionIndex": 1, "elapsedMs": 1, "index": 0},
            {"event": "displayUpdate", "sessionIndex": 1, "elapsedMs": 400, "fullText": "test"},
            {"event": "audio_frame", "sessionIndex": 1, "elapsedMs": 500, "index": 1, "samples": 8000},
            {"event": "audio_fed", "sessionIndex": 1, "elapsedMs": 501, "index": 1},
            {"event": "input_stopped", "sessionIndex": 1, "elapsedMs": 1000},
            {"event": "summary", "sessionIndex": 1, "elapsedMs": 1100, "fullText": "test", "stopToFinalMs": 100},
        ]

    def run_validator(self, rows):
        with tempfile.TemporaryDirectory(prefix="talkless-timeline-test-") as directory:
            path = Path(directory) / "timeline.jsonl"
            path.write_text("\n".join(json.dumps(row) for row in rows))
            return subprocess.run([sys.executable, "-I", str(VALIDATOR), str(path)], text=True, capture_output=True)

    def test_realtime_with_partial(self):
        result = self.run_validator(self.rows())
        self.assertEqual(result.returncode, 0, result.stderr)
        output = json.loads(result.stdout)
        self.assertEqual(output["nonemptyUpdatesBeforeStop"], 1)
        self.assertEqual(output["capturePacingRatio"], 1)

    def test_rejects_instant_whole_file(self):
        rows = self.rows()
        rows[-2]["elapsedMs"] = 20
        result = self.run_validator(rows)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("not fed at real-time pace", result.stderr)

    def test_rejects_slow_capture(self):
        rows = self.rows()
        rows[-2]["elapsedMs"] = 1300
        result = self.run_validator(rows)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("capture slowed down", result.stderr)

    def test_rejects_dropped_frame(self):
        rows = [r for r in self.rows() if not (r["event"] == "audio_fed" and r["index"] == 1)]
        result = self.run_validator(rows)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("not all frames fed", result.stderr)

    def test_final_only_not_counted_as_live(self):
        rows = self.rows()
        rows[3]["elapsedMs"] = 1050
        result = self.run_validator(rows)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout)["nonemptyUpdatesBeforeStop"], 0)

    def test_silence_has_no_first_partial(self):
        rows = [r for r in self.rows() if r["event"] != "displayUpdate"]
        rows[-1]["fullText"] = ""
        result = self.run_validator(rows)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIsNone(json.loads(result.stdout)["firstPartial"])


if __name__ == "__main__":
    unittest.main()
