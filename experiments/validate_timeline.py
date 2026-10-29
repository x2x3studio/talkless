"""Validate a probe JSONL without interpreting source text as instructions."""
import argparse
import json
from pathlib import Path

parser = argparse.ArgumentParser()
parser.add_argument("timeline", type=Path)
args = parser.parse_args()
rows = [json.loads(line) for line in args.timeline.read_text().splitlines() if line.strip()]
sessions = sorted({r.get("sessionIndex", 0) for r in rows if r.get("event") == "audio_start"})
if not sessions:
    raise SystemExit("FAIL: no audio_start event")
for index in sessions:
    events = [r for r in rows if r.get("sessionIndex") == index]
    summaries = [r for r in events if r.get("event") == "summary"]
    if len(summaries) != 1:
        raise SystemExit(f"FAIL: session {index}: expected one summary, found {len(summaries)}")
    summary = summaries[0]
    frames = [r for r in events if r.get("event") == "audio_frame"]
    fed = [r for r in events if r.get("event") == "audio_fed"]
    stops = [r for r in events if r.get("event") == "input_stopped"]
    if len(stops) != 1 or not frames:
        raise SystemExit(f"FAIL: session {index}: incomplete capture")
    if [r["index"] for r in frames] != list(range(len(frames))):
        raise SystemExit(f"FAIL: session {index}: capture indices are not contiguous")
    if [r["index"] for r in fed] != list(range(len(frames))):
        raise SystemExit(f"FAIL: session {index}: not all frames fed in order")
    media_seconds = sum(r["samples"] for r in frames) / 16000
    wall_seconds = (stops[0]["elapsedMs"] - frames[0]["elapsedMs"]) / 1000
    if wall_seconds < media_seconds - 0.1:
        raise SystemExit(f"FAIL: session {index}: audio was not fed at real-time pace")
    if wall_seconds > media_seconds + max(0.1, media_seconds * 0.02):
        raise SystemExit(f"FAIL: session {index}: capture slowed down by more than 2 percent")
    partials = [r for r in events if r.get("event") == "displayUpdate" and r.get("fullText", "").strip()]
    before_stop = [r for r in partials if r["elapsedMs"] < stops[0]["elapsedMs"]]
    unique = []
    for row in partials:
        if not unique or row["fullText"] != unique[-1]["fullText"]:
            unique.append(row)
    print(json.dumps({
        "sessionIndex": index,
        "frameCount": len(frames),
        "mediaSeconds": media_seconds,
        "captureWallSeconds": wall_seconds,
        "capturePacingRatio": wall_seconds / media_seconds,
        "nonemptyUpdatesBeforeStop": len(before_stop),
        "distinctConsecutiveUpdates": len(unique),
        "firstPartial": unique[0] if unique else None,
        "stopToFinalMs": summary.get("stopToFinalMs"),
        "fullText": summary.get("fullText"),
        "peakRSSBytes": summary.get("peakRSSBytes"),
    }, ensure_ascii=False))
