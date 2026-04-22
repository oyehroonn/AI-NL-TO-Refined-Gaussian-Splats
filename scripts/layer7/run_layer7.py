#!/usr/bin/env python3
"""
Layer 7 — AI Splat Analysis.

CLI entry point and pipeline-callable function.

Usage (standalone):
  python -m layer7.run_layer7 --run-dir runs/20260422T143200Z_kitchen
  python -m layer7.run_layer7 --run-dir runs/... --api-key sk-...

Pipeline call:
  from layer7.run_layer7 import run_layer7
  summary = run_layer7(run_dir, api_key="sk-...", model="llama-3.3-70b-versatile")
"""
from __future__ import annotations

import argparse
import os
import sys
import time
from pathlib import Path


# ── .env loader (no new dependencies) ────────────────────────────────────────

def _load_dotenv(repo_root: Path) -> None:
    """
    Parse .env from repo_root and populate os.environ for missing keys.
    Simple KEY=VALUE parser — supports quoted values and inline # comments.
    """
    env_path = repo_root / ".env"
    if not env_path.is_file():
        return
    for raw_line in env_path.read_text(encoding="utf-8").splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        # Strip inline comments after the value
        key_raw, _, rest = line.partition("=")
        key = key_raw.strip()
        # Remove inline comment
        value = rest.split("#")[0].strip()
        # Strip surrounding quotes
        if (value.startswith('"') and value.endswith('"')) or \
           (value.startswith("'") and value.endswith("'")):
            value = value[1:-1]
        if key and key not in os.environ:
            os.environ[key] = value


# ── Pipeline-callable entry ───────────────────────────────────────────────────

def run_layer7(
    run_dir:    Path,
    *,
    api_key:    str | None = None,
    model:      str        = "llama-3.3-70b-versatile",
    max_tokens: int        = 2048,
    verbose:    bool       = True,
) -> dict:
    """
    Run the Layer 7 AI analysis on a completed pipeline run.

    Parameters
    ----------
    run_dir    : pipeline run root (must contain metadata/ with layer3 and/or layer6 JSON)
    api_key    : Groq API key (overrides GROQ_API_KEY env var and .env file)
    model      : Groq model name (default: llama-3.3-70b-versatile)
    max_tokens : maximum tokens for the AI response (default: 2048)
    verbose    : print progress messages

    Returns
    -------
    dict — pipeline metadata summary
    """
    # Ensure scripts/ and scripts/layer7/ are on sys.path
    this_dir = Path(__file__).resolve().parent      # scripts/layer7/
    scripts  = this_dir.parent                      # scripts/
    repo_root = scripts.parent                      # repo root
    for p in (str(scripts), str(this_dir)):
        if p not in sys.path:
            sys.path.insert(0, p)

    from .context_builder   import build_context
    from .prompt_builder    import build_messages
    from .groq_client       import call_groq, GroqError
    from .report_formatter  import print_report, save_report

    # Load .env so GROQ_API_KEY is available
    _load_dotenv(repo_root)

    # Resolve API key: argument > env var
    resolved_key = api_key or os.environ.get("GROQ_API_KEY", "")
    if not resolved_key or resolved_key == "your-groq-api-key-here":
        raise ValueError(
            "Groq API key not set. Provide --api-key, set GROQ_API_KEY env var, "
            "or fill in the .env file at the repo root."
        )

    # Resolve model: argument > env var
    resolved_model = model
    if resolved_model == "llama-3.3-70b-versatile":
        resolved_model = os.environ.get("GROQ_MODEL", model)

    run_dir = run_dir.resolve()

    if verbose:
        print(f"\n[Layer 7] Building analysis context for {run_dir.name} …")

    ctx      = build_context(run_dir)
    messages = build_messages(ctx)

    prompt_chars = sum(len(m["content"]) for m in messages)
    if verbose:
        l3_ready = ctx["layer3"].get("readiness", "n/a") if ctx["layer3"].get("available") else "not available"
        l6_grade = ctx["layer6"].get("quality_grade", "n/a") if ctx["layer6"].get("available") else "not available"
        print(f"[Layer 7]   Layer 3 readiness : {l3_ready}")
        print(f"[Layer 7]   Layer 6 grade     : {l6_grade}")
        print(f"[Layer 7]   Prompt size       : {prompt_chars:,} chars")
        print(f"[Layer 7] Calling Groq API (model: {resolved_model}) …")

    t0 = time.perf_counter()
    try:
        ai_text, usage = call_groq(
            resolved_key,
            messages,
            model=resolved_model,
            max_tokens=max_tokens,
            temperature=0.3,
        )
    except GroqError as exc:
        print(f"\n[Layer 7] ERROR: {exc}", file=sys.stderr)
        return {"error": str(exc), "status": "failed"}

    elapsed = time.perf_counter() - t0

    if verbose:
        print(
            f"[Layer 7] Response received in {elapsed:.1f}s  |  "
            f"tokens: {usage.get('prompt_tokens',0)} prompt + "
            f"{usage.get('completion_tokens',0)} completion"
        )

    # Print to console
    print_report(ai_text, ctx)

    # Save files
    summary = save_report(
        run_dir,
        ai_text,
        ctx,
        messages,
        model=resolved_model,
        usage=usage,
        elapsed=elapsed,
    )

    if verbose:
        print(f"[Layer 7] JSON report  → {summary['layer7_json']}")
        print(f"[Layer 7] Markdown     → {summary['layer7_report_md']}")

    return summary


# ── CLI ───────────────────────────────────────────────────────────────────────

def main() -> None:
    parser = argparse.ArgumentParser(
        description="Layer 7: AI splat analysis using Groq LLM.",
        formatter_class=argparse.ArgumentDefaultsHelpFormatter,
    )
    parser.add_argument(
        "--run-dir",
        type=Path,
        required=True,
        help="Pipeline run root directory (e.g. runs/20260422T143200Z_kitchen).",
    )
    parser.add_argument(
        "--api-key",
        type=str,
        default=None,
        dest="api_key",
        help="Groq API key (overrides GROQ_API_KEY env var and .env file).",
    )
    parser.add_argument(
        "--model",
        type=str,
        default="llama-3.3-70b-versatile",
        help="Groq model to use.",
    )
    parser.add_argument(
        "--max-tokens",
        type=int,
        default=2048,
        help="Maximum tokens for AI response.",
    )
    parser.add_argument(
        "--quiet",
        action="store_true",
        help="Suppress progress output.",
    )
    args = parser.parse_args()

    try:
        summary = run_layer7(
            args.run_dir,
            api_key    = args.api_key,
            model      = args.model,
            max_tokens = args.max_tokens,
            verbose    = not args.quiet,
        )
    except ValueError as exc:
        print(f"Error: {exc}", file=sys.stderr)
        sys.exit(1)

    if summary.get("status") == "failed":
        sys.exit(1)

    print(f"\nDone.  Report saved to {summary.get('layer7_report_md', '?')}")


if __name__ == "__main__":
    _scripts = Path(__file__).resolve().parent.parent
    if str(_scripts) not in sys.path:
        sys.path.insert(0, str(_scripts))
    main()
