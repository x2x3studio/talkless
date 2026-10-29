#!/usr/bin/env python3
"""Summarize measurement JSONL (not assistant session transcripts)."""
import json
from pathlib import Path
import sys

for argument in sys.argv[1:]:
    path = Path(argument)
    all_rows = [json.loads(line) for line in path.read_text().splitlines() if line.strip()]
    for session in sorted(set(r.get("sessionIndex", 1) for r in all_rows) - {0}):
        rows = [r for r in all_rows if r.get("sessionIndex", 1) == session]
        frames = [r for r in rows if r["event"] == "audio_frame"]
        partials = [r for r in rows if r["event"] == "displayUpdate"]
        summaries = [r for r in rows if r["event"] == "summary"]
        intervals = [b["sinceFirstFrameMs"] - a["sinceFirstFrameMs"] for a, b in zip(frames, frames[1:])]
        snapshots = []
        previous_second = -1
        for row in partials:
            second = int(row["sinceFirstFrameMs"] / 1000)
            if second != previous_second:
                snapshots.append({k: row[k] for k in ("sinceFirstFrameMs", "confirmedText", "provisionalText", "fullText")})
                previous_second = second
        first_nonempty = next((r for r in partials if r["fullText"].strip()), None)
        report = {"file": str(path.resolve()), "sessionIndex": session, "events": len(rows), "frames": len(frames), "samples": sum(r["samples"] for r in frames), "displayUpdateCount": len(partials), "firstNonemptyPartial": first_nonempty, "captureIntervalMsMin": min(intervals) if intervals else None, "captureIntervalMsMax": max(intervals) if intervals else None, "captureIntervalMsMean": sum(intervals)/len(intervals) if intervals else None, "partialTimelineOnePerSecond": snapshots, "summary": summaries[-1] if summaries else None, "errors": [r for r in rows if r["event"] == "error"]}
        stop = next((r for r in rows if r["event"] == "input_stopped"), None)
        start = next((r for r in rows if r["event"] == "audio_start"), None)
        if stop and start:
            report["captureWallSeconds"] = (stop["elapsedMs"] - start["elapsedMs"]) / 1000
            report["partialsBeforeStop"] = sum(r["elapsedMs"] < stop["elapsedMs"] and bool(r["fullText"].strip()) for r in partials)
        # One JSON object per line even for repeated sessions.
        print(json.dumps(report, ensure_ascii=False))
