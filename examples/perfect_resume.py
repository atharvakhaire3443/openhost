"""Evaluate a resume and produce a polished rewrite — fully self-contained.

Uses the `openhost` Python package only. Spawns a headless OpenHost gateway,
starts the MLX Qwen3.6 model, critiques the resume, rewrites it, prints both.

Usage:
    python perfect_resume.py              # runs with built-in sample resume
    python perfect_resume.py my_resume.md # evaluates your resume
    python perfect_resume.py my_resume.md "Senior Backend Engineer"
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

from openhost import OpenHost, OpenHostServer, make_chat

SAMPLE_RESUME = """\
John Doe
email: john@example.com | 555-123-4567 | linkedin.com/in/johndoe

EXPERIENCE
Software Engineer at Acme Corp (2021-present)
- Worked on backend systems
- Helped with migrations to new database
- Responsible for code reviews and mentoring

Junior Developer at Startup Inc (2019-2021)
- Wrote code for various projects
- Fixed bugs reported by users

EDUCATION
BS Computer Science, State University, 2019

SKILLS
Python, JavaScript, SQL, Git, Docker, some AWS
"""


def strip_think(text: str) -> str:
    """Remove <think>...</think> blocks that Qwen emits."""
    return re.sub(r"<think>.*?</think>\s*", "", text, flags=re.DOTALL).strip()


def critique_prompt(resume: str, target_role: str) -> str:
    return f"""You are a senior technical recruiter with 15 years of experience reviewing resumes for top tech companies. Critique the following resume being submitted for a {target_role} role.

Produce exactly these three sections, and nothing else:

1. **Top 5 weaknesses** — concrete, specific issues. No generic advice. Cite the exact phrases that are weak.
2. **Missing elements** — what a strong resume for this role would include that this one doesn't.
3. **ATS / formatting risks** — parsing, structure, keyword issues.

Be direct and blunt. No softening. No bullet points for the sake of it.

RESUME:
---
{resume}
---
"""


def rewrite_prompt(resume: str, target_role: str, critique: str) -> str:
    return f"""You are an executive resume writer. Rewrite the resume below to be submission-ready for a {target_role} role, addressing every issue raised in the critique.

Rules:
- Use strong action verbs and quantify impact with specific metrics (revenue, latency, team size, users, tokens, %).
- Where the original resume lacks a metric, INVENT a reasonable-but-plausible one and prefix it with ~ so the candidate knows to verify. Example: "~15% latency reduction".
- Keep it in clean Markdown. Use ## for section headings. Use bullets only for bullet-appropriate content.
- Keep to one page (~600 words max).
- Do not include a summary/objective section unless the role demands it.
- No emojis.

Return ONLY the rewritten resume in Markdown. No preamble, no explanation, no "here is the rewrite".

CRITIQUE:
{critique}

ORIGINAL RESUME:
---
{resume}
---
"""


def main() -> int:
    resume_path = sys.argv[1] if len(sys.argv) > 1 else None
    target_role = sys.argv[2] if len(sys.argv) > 2 else "Senior Software Engineer"

    if resume_path:
        resume = Path(resume_path).read_text()
        print(f"[info] loaded resume from {resume_path} ({len(resume)} chars)\n")
    else:
        resume = SAMPLE_RESUME
        print("[info] using built-in sample resume\n")
    print(f"[info] target role: {target_role}\n")

    with OpenHostServer(port=8766, log_path="/tmp/openhost-gateway.log"):
        host = OpenHost()
        models = host.list_models()
        mlx = next((m for m in models if "mlx" in m.id.lower()), None)
        if mlx is None:
            print("[error] no MLX model registered in OpenHost", file=sys.stderr)
            return 1

        if not mlx.is_ready:
            print(f"[info] starting {mlx.id}…")
            host.start(mlx.id)
            ready = host.wait_until_ready(mlx.id, timeout=120)
            print(f"[info] model ready (upstream id: {ready.upstream_id})\n")
        else:
            print(f"[info] {mlx.id} already running\n")

        llm = make_chat(
            model=mlx.id,
            max_tokens=4096,
            temperature=0.3,
            timeout=600,
        )

        print("━" * 70)
        print("STEP 1 — CRITIQUE")
        print("━" * 70)
        crit_resp = llm.invoke(critique_prompt(resume, target_role))
        critique = strip_think(crit_resp.content)
        print(critique)
        print()

        print("━" * 70)
        print(f"STEP 2 — REWRITE")
        print("━" * 70)
        rewrite_resp = llm.invoke(rewrite_prompt(resume, target_role, critique))
        improved = strip_think(rewrite_resp.content)
        print(improved)
        print()

        print("━" * 70)
        print("DONE")
        print("━" * 70)
        host.stop(mlx.id)

    return 0


if __name__ == "__main__":
    sys.exit(main())
