#!/usr/bin/env python3
"""Verify release tag/version, exact commit, and GitHub commit identity."""
from __future__ import annotations
import argparse, json, re, sys, urllib.error, urllib.request
from pathlib import Path
from typing import Any
TAG = re.compile(r"^daeroh-v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$")
VERSION_LINE = re.compile(r"^version:\s*((?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*))\+((?:0|[1-9][0-9]*))\s*(?:#.*)?$")
GIT_ID = re.compile(r"^[0-9a-f]{40}(?:[0-9a-f]{24})?$")
LOGIN = re.compile(r"^[A-Za-z0-9](?:[A-Za-z0-9-]{0,37}[A-Za-z0-9])?$")
MAX_FILE_BYTES = 1024 * 1024
class IdentityError(ValueError): pass
def strict_string(value: Any) -> str:
    if not isinstance(value, str) or not value or value.strip() != value: raise IdentityError
    return value
def load_json(path: Path) -> Any:
    if not path.is_file() or path.is_symlink() or path.stat().st_size > MAX_FILE_BYTES: raise IdentityError
    try: return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as error: raise IdentityError from error
def pubspec_version(path: Path) -> tuple[str, int]:
    if not path.is_file() or path.is_symlink() or path.stat().st_size > MAX_FILE_BYTES: raise IdentityError
    try: matches = [VERSION_LINE.fullmatch(x) for x in path.read_text(encoding="utf-8").splitlines()]
    except (OSError, UnicodeError) as error: raise IdentityError from error
    matches = [x for x in matches if x]
    if len(matches) != 1: raise IdentityError
    return matches[0].group(1), int(matches[0].group(2))
def source_policy(path: Path) -> tuple[set[str], set[str], str]:
    value = load_json(path); source = value.get("sourceAuthorization") if isinstance(value, dict) else None
    required = {"forge", "repository", "authorizedActors", "authorizedCommitters", "requireAuthorAndCommitter"}
    if value.get("schema") != 1 or not isinstance(source, dict) or set(source) != required or source["forge"] != "github.com" or source["requireAuthorAndCommitter"] is not True or not isinstance(source["repository"], str) or not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", source["repository"]): raise IdentityError
    def actors(items: Any) -> set[str]:
        if not isinstance(items, list) or not items or any(not isinstance(x, str) or LOGIN.fullmatch(x) is None for x in items): raise IdentityError
        result = {x.casefold() for x in items}
        if len(result) != len(items): raise IdentityError
        return result
    return actors(source["authorizedActors"]), actors(source["authorizedCommitters"]), source["repository"]
def check_identity(author: str, committer: str, verification: Any, policy: Path) -> None:
    authors, committers, _ = source_policy(policy)
    if author.casefold() not in authors: raise IdentityError("GitHub commit author is not authorized")
    if committer.casefold() not in committers: raise IdentityError("GitHub commit committer is not authorized")
    if not isinstance(verification, dict) or verification.get("verified") is not True or verification.get("reason") != "valid": raise IdentityError("GitHub commit signature is not verified")
def github_identity(commit: str, policy: Path) -> None:
    _, _, repository = source_policy(policy)
    if GIT_ID.fullmatch(commit) is None: raise IdentityError
    request = urllib.request.Request(f"https://api.github.com/repos/{repository}/commits/{commit}", headers={"Accept":"application/vnd.github+json", "User-Agent":"daeroh-release-verifier"})
    try:
        with urllib.request.urlopen(request, timeout=20) as response:
            if response.status != 200: raise IdentityError
            value = json.loads(response.read().decode("utf-8"))
        check_identity(strict_string(value["author"]["login"]), strict_string(value["committer"]["login"]), value["commit"]["verification"], policy)
    except (OSError, UnicodeError, KeyError, TypeError, json.JSONDecodeError, urllib.error.HTTPError) as error: raise IdentityError("GitHub commit identity could not be verified") from error
def validate(tag: str, pubspec: Path, build_number: str, expected_commit: str, checkout_commit: str, tag_commit: str, policy: Path, verification_json: Path | None) -> None:
    if TAG.fullmatch(tag) is None or not build_number.isdecimal() or (len(build_number)>1 and build_number.startswith("0")): raise IdentityError
    version, build = pubspec_version(pubspec)
    if version != tag.removeprefix("daeroh-v") or build != int(build_number) or any(GIT_ID.fullmatch(x) is None for x in (expected_commit, checkout_commit, tag_commit)) or len({expected_commit,checkout_commit,tag_commit}) != 1: raise IdentityError
    if verification_json is None: github_identity(expected_commit, policy); return
    value = load_json(verification_json)
    if not isinstance(value, dict) or set(value) != {"authorLogin","committerLogin","verification"}: raise IdentityError
    check_identity(strict_string(value["authorLogin"]), strict_string(value["committerLogin"]), value["verification"], policy)
def main() -> int:
    p=argparse.ArgumentParser(description=__doc__)
    for name in ("tag","build-number","expected-commit","checkout-commit","tag-commit"): p.add_argument(f"--{name}",required=True)
    p.add_argument("--pubspec",type=Path,required=True); p.add_argument("--policy",type=Path,required=True); p.add_argument("--verification-json",type=Path)
    a=p.parse_args()
    try: validate(a.tag,a.pubspec,a.build_number,a.expected_commit,a.checkout_commit,a.tag_commit,a.policy,a.verification_json)
    except IdentityError as error: print(f"ERROR: release source identity validation failed: {error or 'invalid identity'}.",file=sys.stderr); return 1
    print("Release source identity validation passed."); return 0
if __name__ == "__main__": raise SystemExit(main())
