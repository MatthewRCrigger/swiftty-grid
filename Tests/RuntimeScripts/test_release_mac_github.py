"""Exercise notarization and release publication with private tool fixtures."""

import json
import os
from pathlib import Path
import plistlib
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import unittest
from urllib.parse import parse_qs, urlparse


ROOT = Path(__file__).resolve().parents[2]
# dash, unlike bash, skips EXIT traps when a signal ends the shell.
SHELLS = [shell for shell in ["/bin/sh", "/bin/dash"] if Path(shell).exists()]
NOTES = ("Developer ID-signed, notarized macOS build of Fixture 1.2 (3) from fixture-commit."
         "\n\nUnzip and move the app to /Applications.")
TOOL = r'''#!/PYTHON
import json, os, sys, time
from pathlib import Path
from urllib.parse import parse_qs, urlparse
name = Path(sys.argv[0]).name
args = sys.argv[1:]
environment = os.environ
with open(environment["RELEASE_FIXTURE_TOOLS"], "a") as stream:
    stream.write(json.dumps([name] + args) + "\n")
if name == "codesign":
    if "-dv" in args: print("Authority=Developer ID Application: Fixture", file=sys.stderr)
elif name == "curl":
    method = args[args.index("--request") + 1]
    url = urlparse(args[-1])
    assert url.hostname in ["api.github.com", "uploads.github.com"], url
    with open(environment["RELEASE_FIXTURE_CALLS"], "a") as stream:
        stream.write(json.dumps([method, args[-1]]) + "\n")
    data = json.loads(args[args.index("--data") + 1]) if "--data" in args else None
    if method == "GET" and url.path.endswith("/releases"):
        page = int(parse_qs(url.query)["page"][0])
        pages = json.loads(environment["RELEASE_FIXTURE_PAGES"])
        assert page <= len(pages), "pagination did not stop at the empty page"
        body = pages[page - 1]
        if body == "HTTP_ERROR": sys.exit(22)
        if body == "HANG": time.sleep(30)
        sys.stdout.write(body)
    elif method == "POST" and url.path.endswith("/releases"):
        assert data["tag_name"] == "mac-v1.2-3", data
        assert data["draft"] is True, data
        print(json.dumps({"id": 42, "html_url": "https://github.com/fixture/repo/releases/42"}))
    elif method == "PATCH" and url.path.endswith("/releases/42"):
        assert data == {"draft": False}, data
        print(json.dumps({"id": 42, "html_url": "https://github.com/fixture/repo/releases/tag/mac-v1.2-3"}))
    elif method == "GET" and url.path.endswith("/assets"):
        print(environment.get("RELEASE_FIXTURE_ASSETS", "[]"))
    elif method == "POST" and url.hostname == "uploads.github.com":
        if environment.get("RELEASE_FIXTURE_UPLOAD") == "fail": sys.exit(22)
        assert Path(args[args.index("--data-binary") + 1][1:]).is_file()
        asset = parse_qs(url.query)["name"][0]
        assert asset.endswith(".partial"), asset
        print(json.dumps({"id": 101 if asset.endswith(".sha256.partial") else 100}))
    elif method == "PATCH" and "/releases/assets/" in url.path:
        assert not data["name"].endswith(".partial"), data
        print("{}")
    elif method == "DELETE" and "/releases/assets/" in url.path:
        pass
    else:
        raise AssertionError((method, url))
elif name == "xcrun":
    if args[:2] == ["stapler", "validate"]:
        sys.exit(0 if environment.get("RELEASE_FIXTURE_STAPLED", "yes") == "yes" else 1)
    if args[:2] == ["notarytool", "submit"]:
        key = Path(args[args.index("--key") + 1])
        assert key.read_text() == environment["NOTARY_KEY"] + "\n"
        assert key.stat().st_mode & 0o077 == 0
        if environment["RELEASE_FIXTURE_STATUS"] == "HANG": time.sleep(30)
        print(json.dumps({"id": "fixture", "status": environment["RELEASE_FIXTURE_STATUS"]}))
elif name != "spctl":
    raise AssertionError(name)
'''


class Fixture(unittest.TestCase):
    bundle_name = "Fixture"

    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="swiftty-release-test-")
        self.addCleanup(temporary.cleanup)
        self.directory = Path(temporary.name)
        scripts = self.directory / "Scripts"
        scripts.mkdir()
        for name in ["release-mac-github.sh", "notarize.sh"]:
            shutil.copy2(ROOT / "Scripts" / name, scripts / name)
        self.app = self.directory / "Fixture.app"
        (self.app / "Contents").mkdir(parents=True)
        (self.app / "Contents/Info.plist").write_bytes(plistlib.dumps({
            "CFBundleName": self.bundle_name, "CFBundleShortVersionString": "1.2",
            "CFBundleVersion": "3",
        }))
        binary = self.directory / "bin"
        binary.mkdir()
        for name in ["codesign", "xcrun", "spctl", "curl"]:
            tool = binary / name
            tool.write_text(TOOL.replace("#!/PYTHON", "#!" + sys.executable))
            tool.chmod(0o755)
        self.calls = self.directory / "calls.jsonl"
        self.tools = self.directory / "tools.jsonl"
        self.scratch = self.directory / "tmp"
        self.scratch.mkdir()
        self.environment = {
            **os.environ, "PATH": str(binary) + os.pathsep + os.environ["PATH"],
            "TMPDIR": str(self.scratch),
            "GITHUB_TOKEN": "fixture-token", "GITHUB_REPOSITORY": "fixture/repo",
            "RELEASE_COMMIT": "fixture-commit", "RELEASE_TAG": "",
            "RELEASE_FIXTURE_CALLS": str(self.calls),
            "RELEASE_FIXTURE_TOOLS": str(self.tools),
        }

    def run_script(self, script, environment):
        self.calls.write_text("")
        self.tools.write_text("")
        result = subprocess.run(
            ["/bin/sh", str(self.directory / "Scripts" / script), str(self.app)],
            env={**self.environment, **environment},
            capture_output=True, text=True, timeout=15,
        )
        calls = [json.loads(line) for line in self.calls.read_text().splitlines()]
        tools = [json.loads(line) for line in self.tools.read_text().splitlines()]
        return result, calls, tools

    def interrupt(self, shell, script, environment, started):
        """Sends SIGTERM to the script's process group, as a cancelled CI job
        does, once `started(tools)` holds; returns the exit status."""
        self.tools.write_text("")
        process = subprocess.Popen(
            [shell, str(self.directory / "Scripts" / script), str(self.app)],
            env={**self.environment, **environment}, start_new_session=True,
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        )
        try:
            deadline = time.monotonic() + 10
            while not started([json.loads(line) for line in self.tools.read_text().splitlines()]):
                self.assertIsNone(process.poll(), "the script ended before the interruption")
                self.assertLess(time.monotonic(), deadline)
                time.sleep(0.05)
            os.killpg(process.pid, signal.SIGTERM)
            return process.wait(timeout=10)
        finally:
            if process.poll() is None:
                os.killpg(process.pid, signal.SIGKILL)
                process.wait()


@unittest.skipUnless(sys.platform == "darwin", "macOS packaging tools")
class ReleasePublicationTests(Fixture):
    def invoke(self, pages, **environment):
        result, calls, _ = self.run_script(
            "release-mac-github.sh", {"RELEASE_FIXTURE_PAGES": json.dumps(pages), **environment})
        return result, calls

    def test_empty_array_formats_reach_release_creation(self):
        for page in ["[]", "[\n\n]", " \n [ \n ] \n"]:
            with self.subTest(page=page):
                result, calls = self.invoke([page])
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(len(calls), 8)
                self.assertEqual(calls[1], ["POST", "https://api.github.com/repos/fixture/repo/releases"])
                self.assertIn("created draft release mac-v1.2-3", result.stdout)
                self.assertTrue(result.stdout.endswith("/releases/tag/mac-v1.2-3\n"))

    def test_a_created_release_is_published_only_after_its_assets(self):
        result, calls = self.invoke(["[]"])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual([call[0] for call in calls],
                         ["GET", "POST", "GET", "POST", "POST", "PATCH", "PATCH", "PATCH"])
        self.assertEqual(calls[-1], ["PATCH", "https://api.github.com/repos/fixture/repo/releases/42"])
        self.assertIn("published release mac-v1.2-3", result.stdout)

    def test_a_failed_upload_leaves_a_created_release_unpublished(self):
        result, calls = self.invoke(["[]"], RELEASE_FIXTURE_UPLOAD="fail")
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn(["PATCH", "https://api.github.com/repos/fixture/repo/releases/42"], calls)

    def test_unrelated_pages_end_at_decoded_empty_array(self):
        result, calls = self.invoke([json.dumps([{"tag_name": "other"}]), "[\n]"])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual([call[0] for call in calls],
                         ["GET", "GET", "POST", "GET", "POST", "POST", "PATCH", "PATCH", "PATCH"])

    def test_existing_draft_on_later_page_is_updated_and_stays_a_draft(self):
        release = {"id": 42, "html_url": "https://github.com/fixture/repo/releases/42",
                   "tag_name": "mac-v1.2-3", "draft": True, "body": "Written by hand."}
        result, calls = self.invoke([json.dumps([{"tag_name": "other"}]), json.dumps([release])])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual([call[0] for call in calls], ["GET", "GET", "GET", "POST", "POST", "PATCH", "PATCH"])
        self.assertIn("updating release mac-v1.2-3", result.stdout)
        self.assertNotIn("published", result.stdout)

    def test_a_draft_left_by_a_failed_run_is_published(self):
        release = {"id": 42, "html_url": "https://github.com/fixture/repo/releases/42",
                   "tag_name": "mac-v1.2-3", "draft": True, "body": NOTES}
        result, calls = self.invoke([json.dumps([release])])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(calls[-1], ["PATCH", "https://api.github.com/repos/fixture/repo/releases/42"])

    def test_existing_assets_are_replaced_only_after_both_uploads(self):
        release = {"id": 42, "html_url": "https://github.com/fixture/repo/releases/42",
                   "tag_name": "mac-v1.2-3", "draft": False}
        assets = [{"id": 7, "name": "Fixture-1.2-3-macOS.zip"},
                  {"id": 8, "name": "Fixture-1.2-3-macOS.zip.sha256"},
                  {"id": 9, "name": "Fixture-1.2-3-macOS.zip.partial"}]
        result, calls = self.invoke([json.dumps([release])], RELEASE_FIXTURE_ASSETS=json.dumps(assets))
        self.assertEqual(result.returncode, 0, result.stderr)
        steps = [(method, urlparse(url).path.rsplit("/", 1)[-1]) for method, url in calls]
        self.assertEqual(steps, [
            ("GET", "releases"), ("GET", "assets"),
            ("DELETE", "9"), ("POST", "assets"), ("POST", "assets"),
            ("DELETE", "7"), ("PATCH", "100"), ("DELETE", "8"), ("PATCH", "101"),
        ])

    def test_a_failed_upload_keeps_existing_assets(self):
        release = {"id": 42, "html_url": "https://github.com/fixture/repo/releases/42",
                   "tag_name": "mac-v1.2-3", "draft": False}
        assets = [{"id": 7, "name": "Fixture-1.2-3-macOS.zip"}]
        result, calls = self.invoke([json.dumps([release])], RELEASE_FIXTURE_ASSETS=json.dumps(assets),
                                    RELEASE_FIXTURE_UPLOAD="fail")
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("DELETE", [call[0] for call in calls])

    def test_api_errors_and_malformed_json_do_not_create_releases(self):
        for page in ["HTTP_ERROR", "not json"]:
            with self.subTest(page=page):
                result, calls = self.invoke([page])
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(len(calls), 1)

    def test_an_interrupted_run_removes_the_token_header(self):
        for shell in SHELLS:
            with self.subTest(shell=shell):
                status = self.interrupt(
                    shell, "release-mac-github.sh", {"RELEASE_FIXTURE_PAGES": json.dumps(["HANG"])},
                    lambda tools: any(tool[0] == "curl" for tool in tools))
                self.assertNotEqual(status, 0)
                self.assertEqual(list(self.scratch.iterdir()), [])


@unittest.skipUnless(sys.platform == "darwin", "macOS packaging tools")
class UnusualBundleNameTests(Fixture):
    bundle_name = "Roaming SSH&#"

    def test_asset_names_are_url_safe(self):
        result, calls, _ = self.run_script(
            "release-mac-github.sh", {"RELEASE_FIXTURE_PAGES": json.dumps(["[]"])})
        self.assertEqual(result.returncode, 0, result.stderr)
        uploads = [parse_qs(urlparse(url).query)["name"][0] for method, url in calls
                   if urlparse(url).hostname == "uploads.github.com"]
        self.assertEqual(uploads, ["Roaming-SSH---1.2-3-macOS.zip.partial",
                                   "Roaming-SSH---1.2-3-macOS.zip.sha256.partial"])


@unittest.skipUnless(sys.platform == "darwin", "macOS packaging tools")
class NotarizationTests(Fixture):
    def notarize(self, status):
        return self.run_script("notarize.sh", {
            "RELEASE_FIXTURE_STAPLED": "no", "RELEASE_FIXTURE_STATUS": status,
            "NOTARY_KEY_ID": "FIXTURE", "NOTARY_ISSUER_ID": "issuer", "NOTARY_KEY": "fixture-key",
        })

    def test_an_accepted_submission_is_stapled_and_assessed(self):
        result, _, tools = self.notarize("Accepted")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(["xcrun", "stapler", "staple", str(self.app)], tools)
        self.assertEqual(tools[-1][0], "spctl")
        self.assertEqual(list(self.scratch.iterdir()), [])

    def test_a_rejected_submission_fails_without_stapling(self):
        for status in ["Invalid", "Rejected", ""]:
            with self.subTest(status=status):
                result, _, tools = self.notarize(status)
                self.assertEqual(result.returncode, 65)
                self.assertNotIn(["xcrun", "stapler", "staple", str(self.app)], tools)
                self.assertEqual(list(self.scratch.iterdir()), [])

    def test_an_interrupted_submission_removes_the_key(self):
        for shell in SHELLS:
            with self.subTest(shell=shell):
                status = self.interrupt(shell, "notarize.sh", {
                    "RELEASE_FIXTURE_STAPLED": "no", "RELEASE_FIXTURE_STATUS": "HANG",
                    "NOTARY_KEY_ID": "FIXTURE", "NOTARY_ISSUER_ID": "issuer",
                    "NOTARY_KEY": "fixture-key",
                }, lambda tools: any(tool[:2] == ["xcrun", "notarytool"] for tool in tools))
                self.assertNotEqual(status, 0)
                self.assertEqual(list(self.scratch.iterdir()), [])

    def test_an_already_stapled_app_is_still_assessed(self):
        result, _, tools = self.run_script("notarize.sh", {})
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual([tool[0] for tool in tools], ["xcrun", "spctl"])


if __name__ == "__main__":
    unittest.main()
