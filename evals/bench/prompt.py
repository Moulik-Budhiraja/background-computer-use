"""The prompt both agents get: eval rules + BCU's own agent instructions + the task."""
import re
import subprocess
from functools import lru_cache
from pathlib import Path

from .common import BCU

SKILL = Path(__file__).resolve().parents[2] / "skills/background-computer-use/SKILL.md"

PREAMBLE = """You are completing a computer-use task on this Mac (user "ralph"). Your only way to act is the Background Computer Use \
tools (the `bcu` MCP server). Its instructions and skill are included below; follow them.

Rules for this run:
- You run unattended. Nobody will answer questions or approve anything mid-task. The user has already approved every step this task \
names, so don't stop to ask; finish the task.
- Touch only the files, pages and apps the task names. Don't change other documents, settings or accounts. Don't send, post or \
submit anything on real websites. Local test pages on localhost are fine to submit.
- When you're done, release every window you opened.
- If the task asks a question, end your final message with one line: `ANSWER: <answer>`.
- If the task can't be done (the file, setting, field or feature doesn't exist, or the request is impossible), don't improvise \
a substitute. End your final message with one line: `INFEASIBLE: <short reason>`.
"""


@lru_cache()
def server_instructions():
    out = subprocess.run([BCU, "docs"], capture_output=True, text=True, timeout=30).stdout
    m = re.search(r"## Server instructions.*?```\n(.*?)```", out, re.S)
    return m.group(1).strip() if m else ""


@lru_cache()
def skill_text():
    s = SKILL.read_text()
    return re.sub(r"^---\n.*?\n---\n", "", s, flags=re.S).strip()


def build(task_text: str) -> str:
    return (PREAMBLE
            + "\n<bcu_server_instructions>\n" + server_instructions() + "\n</bcu_server_instructions>\n"
            + "\n<bcu_skill>\n" + skill_text() + "\n</bcu_skill>\n"
            + "\n<task>\n" + task_text.strip() + "\n</task>\n")
