"""
Layer 7 — Report Formatter.

Takes the raw AI text response and:
  1. Prints it to the console with ANSI colour for section headers.
  2. Saves metadata/layer7_ai_analysis.json (full structured output).
  3. Saves layer7_report.md (clean markdown, no ANSI).
"""
from __future__ import annotations

import json
import sys
import time
from datetime import datetime, timezone
from pathlib import Path


# ── ANSI helpers ──────────────────────────────────────────────────────────────

def _c(text: str, code: str) -> str:
    if not sys.stdout.isatty():
        return text
    return f"\033[{code}m{text}\033[0m"

_BOLD  = "1"
_CYAN  = "36"
_GREEN = "32"
_DIM   = "2"
_YELLOW = "33"


# ── Section-header detector ───────────────────────────────────────────────────

_SECTION_PREFIXES = (
    "### 1.",
    "### 2.",
    "### 3.",
    "### 4.",
    "### 5.",
    "### 6.",
    "### 7.",
)


def _is_section_header(line: str) -> bool:
    stripped = line.strip()
    return any(stripped.startswith(p) for p in _SECTION_PREFIXES)


def _priority_colour(line: str) -> str:
    low = line.lower()
    if "[high]" in low:
        return "31"    # red
    if "[medium]" in low:
        return _YELLOW
    if "[low]" in low:
        return "32"    # green
    return ""


# ── Console printer ───────────────────────────────────────────────────────────

def print_report(ai_text: str, ctx: dict) -> None:
    """Print the AI report to stdout with ANSI formatting."""
    run   = ctx["run"]
    l3    = ctx.get("layer3", {})
    l6    = ctx.get("layer6", {})
    grade = l6.get("quality_grade", "?") if l6.get("available") else "?"

    print()
    print(_c("━" * 72, _BOLD))
    print(_c("  Layer 7 — AI Splat Analysis Report", _BOLD))
    print(_c(f"  Run: {run['run_id']}", _DIM))
    print(_c("━" * 72, _BOLD))

    readiness_str = ""
    if l3.get("available"):
        readiness_str = f"  Pre-capture readiness : {l3['readiness']}\n"
    grade_col = {"EXCELLENT": "32", "GOOD": "32", "FAIR": _YELLOW,
                 "POOR": "31", "FAILED": "31"}.get(grade, _DIM)
    print(f"\n  Splat quality grade   : {_c(grade, grade_col + ';' + _BOLD)}")
    if readiness_str:
        print(readiness_str, end="")

    print()

    for line in ai_text.splitlines():
        if _is_section_header(line):
            print()
            print(_c(line.strip(), _CYAN + ";" + _BOLD))
        elif line.strip().startswith("[HIGH]") or line.strip().startswith("[MEDIUM]") or \
             line.strip().startswith("[LOW]"):
            col = _priority_colour(line)
            if col:
                print(_c(line, col))
            else:
                print(line)
        else:
            print(line)

    print()
    print(_c("━" * 72, _BOLD))
    print()


# ── File savers ───────────────────────────────────────────────────────────────

def save_report(
    run_dir:  Path,
    ai_text:  str,
    ctx:      dict,
    messages: list[dict],
    model:    str,
    usage:    dict,
    elapsed:  float,
) -> dict:
    """
    Save layer7_ai_analysis.json and layer7_report.md.
    Returns the summary dict for pipeline metadata.
    """
    run_dir  = run_dir.resolve()
    meta_dir = run_dir / "metadata"
    meta_dir.mkdir(parents=True, exist_ok=True)

    run   = ctx["run"]
    l3    = ctx.get("layer3", {})
    l6    = ctx.get("layer6", {})

    # ── JSON ──────────────────────────────────────────────────────────────────
    output = {
        "schema_version":    1,
        "run_id":            run["run_id"],
        "video_name":        run["video_name"],
        "generated_at":      datetime.now(timezone.utc).isoformat(),
        "model":             model,
        "usage":             usage,
        "elapsed_seconds":   round(elapsed, 2),
        "layer3_readiness":  l3.get("readiness") if l3.get("available") else None,
        "layer6_grade":      l6.get("quality_grade") if l6.get("available") else None,
        "n_l3_issues":       l3.get("n_critical", 0) + l3.get("n_warnings", 0)
                             if l3.get("available") else None,
        "n_l6_issues":       l6.get("n_issues") if l6.get("available") else None,
        "prompt_system_chars": len(messages[0]["content"]) if messages else 0,
        "prompt_user_chars":   len(messages[1]["content"]) if len(messages) > 1 else 0,
        "analysis":          ai_text,
    }

    json_path = meta_dir / "layer7_ai_analysis.json"
    tmp = json_path.with_suffix(".json.tmp")
    tmp.write_text(json.dumps(output, indent=2) + "\n", encoding="utf-8")
    tmp.replace(json_path)

    # ── Markdown ──────────────────────────────────────────────────────────────
    md_path = run_dir / "layer7_report.md"
    md_lines = [
        f"# Layer 7 — AI Splat Analysis Report",
        f"",
        f"**Run:** `{run['run_id']}`  |  **Video:** `{run['video_name']}`",
        f"**Model:** `{model}`  |  "
        f"**Generated:** {output['generated_at'][:19].replace('T', ' ')} UTC",
        f"",
    ]
    if l3.get("available"):
        md_lines.append(
            f"**Pre-capture readiness:** {l3['readiness']}  |  "
            f"**Splat grade:** {l6.get('quality_grade','?') if l6.get('available') else '?'}"
        )
        md_lines.append("")

    md_lines.append("---")
    md_lines.append("")
    md_lines.append(ai_text)
    md_lines.append("")
    md_lines.append("---")
    md_lines.append(
        f"*Generated by Layer 7 AI Analysis using {model}. "
        f"Tokens: {usage.get('total_tokens', '?')} total.*"
    )

    md_path.write_text("\n".join(md_lines), encoding="utf-8")

    return {
        "model":              model,
        "usage":              usage,
        "elapsed_seconds":    round(elapsed, 2),
        "layer7_json":        str(json_path),
        "layer7_report_md":   str(md_path),
        "layer3_readiness":   output["layer3_readiness"],
        "layer6_grade":       output["layer6_grade"],
    }
