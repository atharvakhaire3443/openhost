"""Resume evaluator using the PyPI-ready openhost SDK (no Swift dependency).

Uses your existing local MLX model via register_local_model. Swap to
`openhost.pull("qwen3.6-35b-mlx-turbo")` + auto-start if you don't have it
pre-downloaded.
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

import openhost

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
    return re.sub(r"<think>.*?</think>\s*", "", text, flags=re.DOTALL).strip()


def critique_prompt(resume: str, target_role: str) -> str:
    return f"""You are a senior technical recruiter with 15 years of experience. Critique the resume below for a {target_role} role.

Produce exactly these three sections and nothing else:

1. **Top 5 weaknesses** — concrete. Cite the exact phrases that are weak.
2. **Missing elements** — what a strong resume for this role would include.
3. **ATS / formatting risks** — parsing, structure, keyword issues.

Be direct and blunt. No softening.

RESUME:
---
{resume}
---
"""


def rewrite_prompt(resume: str, target_role: str, critique: str) -> str:
    return f"""You are an executive resume writer. Rewrite the resume below to be submission-ready for a {target_role} role, addressing every issue raised in the critique.

Rules:
- Strong action verbs, quantified impact (revenue, latency, team size, users, %).
- Where the original lacks a metric, INVENT a plausible one and prefix it with ~ so the candidate knows to verify.
- Clean Markdown. ## for section headings. Bullets only for bullet-appropriate content.
- ~600 words max.
- No summary/objective section unless the role demands it.
- No emojis.

Return ONLY the rewritten resume in Markdown. No preamble.

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

    # Register the user's already-downloaded MLX model so we don't re-download.
    openhost.register_local_model(
        id="qwen3.6-local",
        backend="mlx-lm",
        path="~/models/qwen3.6-35b-mlx",
        display_name="Qwen3.6 35B (local MLX)",
    )

    print("[info] starting model (port auto-selected)…")
    runner = openhost.run("qwen3.6-local")
    info = runner.info()
    print(f"[info] running on {info.base_url}  (upstream id: {info.upstream_model_id})\n")

    llm = openhost.make_chat(
        "qwen3.6-local",
        max_tokens=4096,
        temperature=0.3,
        timeout=600,
    )

    try:
        print("━" * 70)
        print("STEP 1 — CRITIQUE")
        print("━" * 70)
        critique = strip_think(llm.invoke(critique_prompt(resume, target_role)).content)
        print(critique)
        print()

        print("━" * 70)
        print("STEP 2 — REWRITE")
        print("━" * 70)
        improved = strip_think(llm.invoke(rewrite_prompt(resume, target_role, critique)).content)
        print(improved)
        print()

        print("━" * 70)
        print("DONE")
        print("━" * 70)
    finally:
        openhost.stop_all()

    return 0


if __name__ == "__main__":
    sys.exit(main())
