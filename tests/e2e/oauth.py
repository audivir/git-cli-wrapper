# /// script
# requires-python = ">=3.11"
# dependencies = ["playwright"]
# ///
"""End-to-end test of the OAuth login of gt through the wrapper, against a real Gitea.

Needs a Gitea with the user below, and the real gt in PATH. Run through tests/e2e/run.sh, which
starts Gitea in Docker, or point GITEA_URL at an existing one. The browser is Playwright's
Chromium (uv run --with playwright playwright install chromium).

gt opens the authorize URL with the program in BROWSER. A script there records the URL, and
Playwright signs in and approves the app there, so the login finishes without a human.
"""

# ruff: noqa: S603, S607, S105  # the harness runs known tools with a test-only password
from __future__ import annotations

import os
import platform
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path

from playwright.sync_api import sync_playwright

ROOT = Path(__file__).resolve().parents[2]
GITEA_URL = os.environ.get("GITEA_URL", "http://localhost:3000")
USER = os.environ.get("GITEA_USER", "tester")
PASSWORD = os.environ.get("GITEA_PASSWORD", "Test-pass-123")
BACKEND = os.environ.get("GIT_CLI_WRAPPER_BACKEND") or (
    "keychain" if platform.system() == "Darwin" else "gopass"
)
URL_TIMEOUT = 30
LOGIN_TIMEOUT = 60


def check(condition: bool, message: str) -> None:
    print(("ok   " if condition else "FAIL ") + message)
    if not condition:
        sys.exit(1)


def make_browser(workdir: Path) -> tuple[Path, Path]:
    """Return the recording BROWSER script and the dir with the wrapper linked as gt."""
    browser = workdir / "browser"
    browser.write_text(f'#!/bin/sh\necho "$1" >> "{workdir / "opened"}"\n')
    browser.chmod(0o755)
    wrapper_bin = workdir / "wrapper-bin"
    wrapper_bin.mkdir()
    (wrapper_bin / "gt").symlink_to(ROOT / "git-cli-wrapper")
    return browser, wrapper_bin


def backend_env(workdir: Path) -> dict[str, str]:
    """Environment of the chosen backend, isolated in the workdir."""
    env = {
        "HOME": str(workdir / "home"),
        "XDG_STATE_HOME": str(workdir / "state"),
        "GIT_CLI_WRAPPER_BACKEND": BACKEND,
    }
    (workdir / "home").mkdir()
    if BACKEND == "keychain":
        keychain = workdir / "test.keychain-db"
        subprocess.run(["security", "create-keychain", "-p", "pw", str(keychain)], check=True)
        subprocess.run(["security", "unlock-keychain", "-p", "pw", str(keychain)], check=True)
        env["GIT_CLI_WRAPPER_KEYCHAIN"] = str(keychain)
    elif BACKEND == "gopass":
        env["GOPASS_AGE_PASSWORD"] = "pw"
        env["GOPASS_CONFIG"] = str(workdir / "home" / "gopass-config")
        env["XDG_DATA_HOME"] = str(workdir / "data")
        subprocess.run(
            ["gopass", "setup", "--crypto", "age", "--storage", "fs"],
            check=True,
            env={**os.environ, **env},
            stdin=subprocess.DEVNULL,
            capture_output=True,
        )
    return env


def approve(page_url: str) -> None:
    with sync_playwright() as playwright:
        browser = playwright.chromium.launch()
        page = browser.new_page()
        page.goto(page_url)
        # Gitea sends a signed-out visitor to its login page first.
        if "/user/login" in page.url:
            page.fill("#user_name", USER)
            page.fill("#password", PASSWORD)
            page.get_by_role("button", name="Sign In").click()
        page.get_by_role("button", name="Authorize Application").click()
        page.wait_for_load_state("networkidle")
        browser.close()


def wait_for_url(opened: Path) -> str:
    deadline = time.monotonic() + URL_TIMEOUT
    while time.monotonic() < deadline:
        if opened.exists() and opened.read_text().strip():
            return opened.read_text().splitlines()[0]
        time.sleep(0.2)
    check(False, "gt asked for a browser")
    raise AssertionError


def main() -> None:
    workdir = Path(tempfile.mkdtemp(prefix="gcw-e2e."))
    try:
        browser, wrapper_bin = make_browser(workdir)
        env = {
            **os.environ,
            **backend_env(workdir),
            "BROWSER": str(browser),
            "PATH": f"{wrapper_bin}:{os.environ['PATH']}",
        }
        env.pop("GITEA_TOKEN", None)

        login = subprocess.Popen(
            ["gt", "auth", "login", "--host", GITEA_URL],
            env=env,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
        )
        authorize_url = wait_for_url(workdir / "opened")
        check(authorize_url.startswith(f"{GITEA_URL}/login/oauth/authorize"), "authorize URL")
        approve(authorize_url)
        output, _ = login.communicate(timeout=LOGIN_TIMEOUT)
        check(login.returncode == 0, "login finished")
        check("stored with the" in output, "wrapper stored the login")

        gt_config = Path(env["HOME"]) / ".config" / "gitea-cli"
        check(not gt_config.exists(), "gt left no config with credentials behind")

        api = subprocess.run(
            ["gt", "api", "/user"], env=env, capture_output=True, text=True, check=False
        )
        check(api.returncode == 0 and f'"login":"{USER}"' in api.stdout, "call with stored login")

        logout = subprocess.run(
            ["gt", "auth", "logout", "--host", GITEA_URL],
            env=env,
            capture_output=True,
            text=True,
            check=False,
        )
        check(logout.returncode == 0, "logout")
        api = subprocess.run(
            ["gt", "api", "/user"], env=env, capture_output=True, text=True, check=False
        )
        check(api.returncode != 0, "no login after logout")
    finally:
        shutil.rmtree(workdir, ignore_errors=True)


if __name__ == "__main__":
    main()
