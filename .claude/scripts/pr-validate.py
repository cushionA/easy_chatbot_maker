#!/usr/bin/env python3
"""
pr-validate.py
Scans PR body, commit messages, and changed files for prompt injection patterns.
Usage: python3 pr-validate.py [--pr-body <file>] [--diff <file>]
"""
import sys, re, argparse, subprocess
from pathlib import Path

try:
    sys.stdout.reconfigure(encoding="utf-8")
    sys.stderr.reconfigure(encoding="utf-8")
except Exception:
    pass

# Known injection patterns
INJECTION_PATTERNS = [
    # Classic overrides (EN)
    r"ignore\s+(all\s+)?(previous|prior|above)\s+instructions?",
    r"disregard\s+(all\s+)?previous",
    r"forget\s+(all\s+)?previous\s+instructions?",
    r"new\s+instructions?:",
    r"system\s+prompt",
    r"<\s*system\s*>",
    # Classic overrides (JA)
    r"これまでの指示(は|を)(無視|忘れ)",
    r"以前の指示(は|を)(無視|忘れ)",
    r"上記の指示(は|を)(無視|忘れ)",
    r"システムプロンプト",
    r"新しい指示[:：]",
    # Role hijacking (EN)
    r"you\s+are\s+now\s+(?!a\s+(developer|engineer|reviewer))",
    r"act\s+as\s+(?!a\s+(developer|reviewer|engineer))",
    r"pretend\s+(you\s+are|to\s+be)",
    # Role hijacking (JA)
    r"あなたは(もう|今から|これから).{0,10}(ではなく|から)",
    r"のふりをして",
    r"の役を演じて",
    # Data exfiltration
    r"send\s+(this|the\s+above|all)\s+to\s+http",
    r"curl\s+.*\|\s*bash",
    r"wget\s+.*\|\s*sh",
    r"!\[[^\]]*\]\(https?://[^)]*\?[^)]*=",
    # Credential fishing
    r"(api[_\s]?key|secret|password|token)\s*[:=]\s*['\"]?\$\{",
    r"echo\s+\$?(AWS|OPENAI|ANTHROPIC|GEMINI|GITHUB)[_A-Z]*",
    r"AIzaSy[A-Za-z0-9_\-]{33}",
    r"sk-[A-Za-z0-9]{32,}",
    r"ghp_[A-Za-z0-9]{36}",
    # Zero-width / Unicode tag stego
    r"[​-‏‪-‮⁠-⁯]",
    r"[\U000E0000-\U000E007F]",
]

COMPILED = [re.compile(p, re.IGNORECASE | re.MULTILINE) for p in INJECTION_PATTERNS]

# False positive exclusion list (add patterns to security-exclude.txt to suppress)
EXCLUDE_FILE = Path(__file__).parent / "security-exclude.txt"

def load_exclusions():
    if EXCLUDE_FILE.exists():
        return [re.compile(line.strip(), re.IGNORECASE)
                for line in EXCLUDE_FILE.read_text(encoding="utf-8").splitlines()
                if line.strip() and not line.startswith("#")]
    return []

def scan(text: str, source: str, exclusions: list, added_only: bool = False) -> list[dict]:
    findings = []
    # In a unified diff only newly-added lines can introduce content; removed (`-`) and
    # context lines cannot, so scanning them yields false positives (e.g. deleting a config
    # line that held `password: ${VAR}`). In diff mode, scan only `+` lines (not the `+++`
    # file header).
    if added_only:
        for idx, raw in enumerate(text.split("\n")):
            if not raw.startswith("+") or raw.startswith("+++"):
                continue
            content = raw[1:]
            for pattern in COMPILED:
                for match in pattern.finditer(content):
                    snippet = match.group(0)[:80]
                    if any(ex.search(snippet) for ex in exclusions):
                        continue
                    findings.append({
                        "source": source,
                        "line": idx + 1,
                        "pattern": pattern.pattern[:60],
                        "snippet": snippet,
                    })
        return findings
    for pattern in COMPILED:
        for match in pattern.finditer(text):
            line_no = text[:match.start()].count("\n") + 1
            snippet = match.group(0)[:80]
            # check exclusions
            if any(ex.search(snippet) for ex in exclusions):
                continue
            findings.append({
                "source": source,
                "line": line_no,
                "pattern": pattern.pattern[:60],
                "snippet": snippet,
            })
    return findings

def get_pr_body_from_gh() -> str:
    try:
        result = subprocess.run(
            ["gh", "pr", "view", "--json", "body", "-q", ".body"],
            capture_output=True, text=True, encoding="utf-8", errors="replace", timeout=10
        )
        return result.stdout.strip()
    except Exception:
        return ""

def get_staged_diff() -> str:
    try:
        result = subprocess.run(
            ["git", "diff", "--staged"],
            capture_output=True, text=True, encoding="utf-8", errors="replace"
        )
        return result.stdout
    except Exception:
        return ""

def main():
    parser = argparse.ArgumentParser(description="Scan for prompt injection in PRs")
    parser.add_argument("--pr-body", help="File containing PR body text")
    parser.add_argument("--diff", help="File containing diff to scan")
    parser.add_argument("--staged", action="store_true", help="Scan staged diff")
    args = parser.parse_args()

    exclusions = load_exclusions()
    all_findings = []

    if args.pr_body:
        body = Path(args.pr_body).read_text(encoding="utf-8")
        all_findings += scan(body, "PR body", exclusions)
    else:
        body = get_pr_body_from_gh()
        if body:
            all_findings += scan(body, "PR body (gh)", exclusions)

    if args.diff:
        diff = Path(args.diff).read_text(encoding="utf-8")
        all_findings += scan(diff, "diff file", exclusions, added_only=True)
    elif args.staged:
        diff = get_staged_diff()
        if diff:
            all_findings += scan(diff, "staged diff", exclusions, added_only=True)

    if not all_findings:
        print("[pr-validate] PASS: No injection patterns detected.")
        sys.exit(0)
    else:
        print(f"[pr-validate] WARN: {len(all_findings)} suspicious pattern(s) found:\n")
        for f in all_findings:
            print(f"  [{f['source']}] line {f['line']}: {f['snippet']!r}")
            print(f"    pattern: {f['pattern']}")
        print("\nIf these are false positives, add exclusion patterns to security-exclude.txt")
        sys.exit(1)

if __name__ == "__main__":
    main()
