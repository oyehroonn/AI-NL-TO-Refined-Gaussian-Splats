"""
Layer 7 — Groq API Client.

Uses only stdlib (urllib) — zero new dependencies.
Talks to the Groq OpenAI-compatible endpoint.
"""
from __future__ import annotations

import json
import time
import urllib.error
import urllib.request

_GROQ_URL = "https://api.groq.com/openai/v1/chat/completions"
_TIMEOUT   = 120   # seconds
_MAX_RETRY = 2


class GroqError(RuntimeError):
    """Raised when the Groq API returns a non-200 response after all retries."""


def call_groq(
    api_key:    str,
    messages:   list[dict],
    *,
    model:      str  = "llama-3.3-70b-versatile",
    max_tokens: int  = 2048,
    temperature: float = 0.3,
) -> tuple[str, dict]:
    """
    POST to the Groq chat-completions endpoint.

    Returns
    -------
    (response_text, usage_dict)
        response_text : the AI's reply as a plain string
        usage_dict    : {"prompt_tokens": int, "completion_tokens": int, "total_tokens": int}
    """
    payload = json.dumps({
        "model":       model,
        "messages":    messages,
        "max_tokens":  max_tokens,
        "temperature": temperature,
    }).encode("utf-8")

    headers = {
        "Authorization": f"Bearer {api_key}",
        "Content-Type":  "application/json",
    }

    last_err: Exception | None = None
    for attempt in range(_MAX_RETRY + 1):
        if attempt > 0:
            time.sleep(2 ** attempt)   # exponential back-off: 2s, 4s
        req = urllib.request.Request(
            _GROQ_URL,
            data=payload,
            headers=headers,
            method="POST",
        )
        try:
            with urllib.request.urlopen(req, timeout=_TIMEOUT) as resp:
                body = json.loads(resp.read().decode("utf-8"))
                text  = body["choices"][0]["message"]["content"]
                usage = body.get("usage", {})
                return text, {
                    "prompt_tokens":     usage.get("prompt_tokens", 0),
                    "completion_tokens": usage.get("completion_tokens", 0),
                    "total_tokens":      usage.get("total_tokens", 0),
                }
        except urllib.error.HTTPError as exc:
            err_body = ""
            try:
                err_body = exc.read().decode("utf-8")
            except Exception:
                pass
            last_err = GroqError(
                f"Groq API HTTP {exc.code}: {exc.reason}. Body: {err_body[:300]}"
            )
            if exc.code in (400, 401, 403):
                break   # don't retry auth/bad-request errors
        except urllib.error.URLError as exc:
            last_err = GroqError(f"Groq API network error: {exc.reason}")
        except (KeyError, json.JSONDecodeError) as exc:
            last_err = GroqError(f"Groq API unexpected response format: {exc}")
            break

    raise last_err or GroqError("Groq API call failed for unknown reason.")
