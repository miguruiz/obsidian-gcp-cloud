#!/usr/bin/env python3
"""Obsidian Scheduled Prompt Runner.

Reads schedules.yaml from the vault, fires LLM prompt jobs on cron schedules,
and writes results back into the vault as markdown. Hot-reloads config every 30s.
"""

import logging
import os
import time
from datetime import datetime

import frontmatter
import yaml
from croniter import croniter

VAULT_BASE = os.environ.get("VAULT_BASE", "/opt/obsidian-vault")
SCHEDULE_FILE = os.path.join(VAULT_BASE, "00-Inbox/_other/schedules.yaml")
LOG_FILE = os.path.join(VAULT_BASE, "00-Inbox/_other/schedules-log.md")
LOG_DIR = os.path.dirname(LOG_FILE)
CHECK_INTERVAL = 30

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(message)s",
    datefmt="%Y-%m-%d %H:%M:%S",
)
logger = logging.getLogger(__name__)


def load_schedule():
    try:
        with open(SCHEDULE_FILE) as f:
            data = yaml.safe_load(f)
        jobs = (data or {}).get("jobs", [])
        return [j for j in jobs if j.get("enabled", True)]
    except FileNotFoundError:
        logger.debug("Schedule file not found: %s", SCHEDULE_FILE)
        return []
    except Exception as e:
        logger.warning("Failed to load schedule: %s", e)
        return []


def jobs_due(jobs, since, now):
    due = []
    for job in jobs:
        try:
            cron = croniter(job["schedule"], since)
            next_fire = cron.get_next(datetime)
            if since < next_fire <= now:
                due.append(job)
        except Exception as e:
            logger.warning("Invalid schedule for job %s: %s", job.get("id"), e)
    return due


def call_llm(prompt_text, model="claude-sonnet-4-6", temperature=0.7):
    """Placeholder LLM call — replace with real Anthropic API call."""
    logger.info(
        "  [LLM] model=%s temperature=%s prompt_len=%d", model, temperature, len(prompt_text)
    )
    return f"[placeholder response — {datetime.now().isoformat()}]"


def execute_prompt(prompt_path):
    """Load a prompt file, call LLM, write output. Returns (success, status_msg)."""
    full_path = prompt_path if os.path.isabs(prompt_path) else os.path.join(VAULT_BASE, prompt_path)

    try:
        post = frontmatter.load(full_path)
    except FileNotFoundError:
        return False, "file not found"
    except Exception as e:
        return False, str(e)

    output_cfg = post.get("output", {})
    output_path = output_cfg.get("path", "") if isinstance(output_cfg, dict) else ""
    mode = post.get("mode", "append")
    model = post.get("model", "claude-sonnet-4-6")
    temperature = post.get("temperature", 0.7)

    if not output_path:
        logger.warning("  No output.path in frontmatter: %s", prompt_path)
        return False, "no output.path"

    result = call_llm(post.content, model=model, temperature=temperature)

    out_full = output_path if os.path.isabs(output_path) else os.path.join(VAULT_BASE, output_path)
    out_dir = os.path.dirname(out_full)
    if out_dir:
        os.makedirs(out_dir, exist_ok=True)

    if mode == "append":
        separator = f"---\n*{datetime.now().strftime('%Y-%m-%d %H:%M')}*\n\n"
        with open(out_full, "a") as f:
            f.write(separator + result + "\n")
    else:
        with open(out_full, "w") as f:
            f.write(result + "\n")

    return True, "ok"


def execute_job(job):
    """Run all prompts in a job sequentially. Returns list of (prompt_path, success, msg)."""
    results = []
    for prompt_path in job.get("prompts", []):
        logger.info("  Running prompt: %s", prompt_path)
        success, msg = execute_prompt(prompt_path)
        results.append((prompt_path, success, msg))
        if success:
            logger.info("  ✓ %s", prompt_path)
        else:
            logger.warning("  ✗ %s (%s)", prompt_path, msg)
    return results


def write_log(job_id, results, run_time):
    """Append a markdown block to LOG_FILE."""
    os.makedirs(LOG_DIR, exist_ok=True)
    all_ok = all(s for _, s, _ in results)
    status = "✓" if all_ok else "✗"
    timestamp = run_time.strftime("%Y-%m-%d %H:%M")
    lines = [f"## {timestamp} — {job_id} {status}"]
    for prompt_path, success, msg in results:
        mark = "✓" if success else f"✗ ({msg})"
        lines.append(f"- `{prompt_path}` {mark}")
    lines.append("")
    block = "\n".join(lines) + "\n"
    try:
        with open(LOG_FILE, "a") as f:
            f.write(block)
    except Exception as e:
        logger.warning("Failed to write log: %s", e)


def main():
    logger.info("Obsidian Runner starting. VAULT_BASE=%s", VAULT_BASE)
    logger.info("Schedule file: %s", SCHEDULE_FILE)
    last_check = datetime.now()

    while True:
        time.sleep(CHECK_INTERVAL)
        now = datetime.now()
        jobs = load_schedule()
        due = jobs_due(jobs, last_check, now)
        for job in due:
            job_id = job.get("id", "unknown")
            logger.info("Running job: %s", job_id)
            results = execute_job(job)
            write_log(job_id, results, now)
        last_check = now


if __name__ == "__main__":
    main()
