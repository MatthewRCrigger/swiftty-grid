"""Universal Link files from real generators, with private packaging commands."""

import copy
import itertools
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
TARGETS = ["MobileClient", "MacClient", "CatalystClient", "VisionClient"]
ENTITLEMENT = "com.apple.developer.associated-domains"
TEAM = "TEAMID1234"
BUNDLES = ["dev.swiftty.fixture.mobile", "dev.swiftty.fixture.mac"]
BONJOUR = "_swiftty._tcp"
MULTICAST = "com.apple.developer.networking.multicast"
TOOL = '''#!/PYTHON
import json, os, sys
from pathlib import Path
name = Path(sys.argv[0]).name
with open(os.environ['LINK_FIXTURE_CALLS'], 'a') as stream:
    stream.write(json.dumps([name, sys.argv[1:]]) + '\\n')
if name == 'swift' and '--show-bin-path' in sys.argv:
    print(os.environ['LINK_FIXTURE_PRODUCTS'])
'''


@unittest.skipUnless(sys.platform == "darwin" and shutil.which("plutil"), "macOS plist tools")
class LinkConfigurationTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory(prefix="swiftty-link-config-")
        self.addCleanup(directory.cleanup)
        self.root = Path(directory.name)
        self.environment = dict(os.environ)
        for key in ["SWIFTTY_LINK_DOMAINS", "SWIFTTY_LINK_MODE",
                    "SWIFTTY_PROVISIONING_PROFILE", "NOTARY_PROFILE"]:
            self.environment.pop(key, None)

    def run_script(self, name, *arguments, **environment):
        return subprocess.run(
            ["/bin/sh", str(ROOT / "Scripts" / name), *map(str, arguments)],
            cwd=self.root, env={**self.environment, **environment},
            capture_output=True, text=True, timeout=10,
        )

    def assert_success(self, result):
        self.assertEqual(result.returncode, 0, result.stderr)

    def read_plist(self, path):
        with path.open("rb") as stream:
            return plistlib.load(stream)

    def test_configuration_preserves_literal_developer_suffix_despite_matching_filenames(self):
        for suffix in ["X", "Y", '"']:
            (self.root / f"applinks:links.example.com{suffix}mode=developer").touch()
        for mode in ["", "developer"]:
            with self.subTest(mode=mode):
                output = self.root / ("generated " + (mode or "normal"))
                result = self.run_script(
                    "configure-links.sh", output,
                    SWIFTTY_LINK_DOMAINS="Links.Example.COM, other.example.com\nlinks.example.com",
                    SWIFTTY_LINK_MODE=mode,
                )
                self.assert_success(result)
                domains = ["links.example.com", "other.example.com"]
                info = self.read_plist(output / "AttentionLinks.plist")
                base_info = self.read_plist(ROOT / "Apps/Config/AttentionLinks.plist")
                self.assertEqual(info, {**base_info, "SwifttyAssociatedDomains": domains})
                suffix = "?mode=developer" if mode else ""
                for target in TARGETS:
                    base = ROOT / f"Apps/{target}/{target}.entitlements"
                    expected = self.read_plist(base) if base.exists() else {}
                    expected[ENTITLEMENT] = [f"applinks:{domain}{suffix}" for domain in domains]
                    self.assertEqual(self.read_plist(output / f"{target}.entitlements"), expected)

    def test_empty_domains_and_invalid_settings_do_not_add_entitlements(self):
        output = self.root / "generated"
        result = self.run_script("configure-links.sh", output)
        self.assert_success(result)
        self.assertEqual(self.read_plist(output / "AttentionLinks.plist")["SwifttyAssociatedDomains"], [])
        for target in TARGETS:
            base = ROOT / f"Apps/{target}/{target}.entitlements"
            self.assertEqual(self.read_plist(output / f"{target}.entitlements"),
                             self.read_plist(base) if base.exists() else {})
        for setting in [{"SWIFTTY_LINK_DOMAINS": "invalid_domain.example"},
                        {"SWIFTTY_LINK_DOMAINS": "links.example.com", "SWIFTTY_LINK_MODE": "invalid"}]:
            with self.subTest(setting=setting):
                rejected = self.root / "rejected"
                result = self.run_script("configure-links.sh", rejected, **setting)
                self.assertEqual(result.returncode, 64, result.stderr)
                self.assertFalse(rejected.exists())

    def test_generated_client_plist_carries_the_bonjour_declaration(self):
        output = self.root / "generated"
        self.assert_success(self.run_script("configure-links.sh", output))
        base = self.read_plist(ROOT / "Apps/Config/AttentionLinks.plist")
        info = self.read_plist(output / "AttentionLinks.plist")
        self.assertEqual(base["NSBonjourServices"], [BONJOUR])
        self.assertEqual(info["NSBonjourServices"], [BONJOUR])
        self.assertEqual(info["CFBundleURLTypes"], base["CFBundleURLTypes"])
        for target in TARGETS:
            self.assertNotIn(MULTICAST, self.read_plist(output / f"{target}.entitlements"))

    def test_project_declares_camera_only_for_the_scanning_client(self):
        project = (ROOT / "Apps/project.yml").read_text()
        blocks = {}
        current = None
        for line in project.splitlines():
            if line.startswith("  ") and not line.startswith("   ") and line.rstrip().endswith(":"):
                current = line.strip()[:-1]
                blocks[current] = []
            elif current is not None:
                blocks[current].append(line)
        camera = [name for name, lines in blocks.items()
                  if any("NSCameraUsageDescription" in line for line in lines)]
        self.assertEqual(camera, ["MobileClient"])
        watch = "\n".join(blocks["WatchCompanion"])
        for key in ["NSCameraUsageDescription", "NSLocalNetworkUsageDescription",
                    "AttentionLinks.plist", "RoamingApp", "HostConnection"]:
            self.assertNotIn(key, watch)
        self.assertIn("Find and connect to your Mac", project)
        self.assertNotIn(MULTICAST, project)
        for entitlements in (ROOT / "Apps").glob("*/*.entitlements"):
            self.assertNotIn(MULTICAST, entitlements.read_text())

    def test_native_package_preserves_literal_domains_without_real_build_or_signing(self):
        tools = self.root / "bin"
        tools.mkdir()
        products = self.root / "products"
        products.mkdir()
        for name in ["swiftty", "swiftmux-agent", "swmux-launcher", "swmux"]:
            (products / name).write_text("owned fixture executable\n")
        resources = products / "swiftty_SwifttyCore.bundle"
        resources.mkdir()
        (resources / "fixture").write_text("owned resource\n")
        for name in ["swift", "codesign"]:
            executable = tools / name
            executable.write_text(TOOL.replace("/PYTHON", sys.executable))
            executable.chmod(0o700)
        (self.root / "applinks:links.example.comXmode=developer").touch()
        (self.root / "applinks:links.example.comYmode=developer").touch()
        # The script copies the app icon from the repository-relative
        # Resources directory of its working directory.
        (self.root / "Resources").symlink_to(ROOT / "Resources")
        for mode in ["", "developer"]:
            with self.subTest(mode=mode):
                output = self.root / ("package " + (mode or "normal"))
                calls = self.root / f"calls-{mode or 'normal'}.jsonl"
                result = self.run_script(
                    "package-swiftmux.sh", "-", output,
                    PATH=str(tools) + os.pathsep + self.environment["PATH"],
                    LINK_FIXTURE_PRODUCTS=str(products), LINK_FIXTURE_CALLS=str(calls),
                    SWIFTTY_LINK_DOMAINS="Links.Example.COM,other.example.com",
                    SWIFTTY_LINK_MODE=mode,
                )
                self.assert_success(result)
                suffix = "?mode=developer" if mode else ""
                expected = [f"applinks:{domain}{suffix}" for domain in
                            ["links.example.com", "other.example.com"]]
                self.assertEqual(self.read_plist(output / "Swiftty.entitlements"), {ENTITLEMENT: expected})
                app = output / "Swiftty.app"
                info = self.read_plist(app / "Contents/Info.plist")
                self.assertEqual(info["SwifttyAssociatedDomains"],
                                 ["links.example.com", "other.example.com"])
                # Foreground discovery (spec.connection-setup.md D5): a
                # real array, a purpose string, and no multicast entitlement.
                self.assertEqual(info["NSBonjourServices"], [BONJOUR])
                self.assertTrue(info["NSLocalNetworkUsageDescription"].strip())
                self.assertEqual(info["CFBundleURLTypes"][0]["CFBundleURLSchemes"], ["swiftty"])
                self.assertNotIn(MULTICAST, self.read_plist(output / "Swiftty.entitlements"))
                commands = [json.loads(line) for line in calls.read_text().splitlines()]
                self.assertEqual(sum(name == "swift" for name, _ in commands), 2)
                self.assertEqual(sum(name == "codesign" for name, _ in commands), 5)
                self.assertTrue(any(name == "codesign" and "--entitlements" in args and
                                    str(output / "Swiftty.entitlements") in args
                                    for name, args in commands))

    def association_document(self):
        result = self.run_script("make-aasa.sh", TEAM, *BUNDLES)
        self.assert_success(result)
        return json.loads(result.stdout)

    def check_document(self, document, *arguments):
        file = self.root / "apple-app-site-association"
        file.write_text(json.dumps(document))
        return self.run_script("make-aasa.sh", "--check", file, *arguments)

    def test_generated_association_and_each_exclusion_order_pass_with_exact_app_ids(self):
        document = self.association_document()
        entry = document["applinks"]["details"][0]
        self.assertEqual(entry["appIDs"], [f"{TEAM}.{bundle}" for bundle in BUNDLES])
        rules = copy.deepcopy(entry["components"])
        for exclusions in itertools.permutations(rules[:3]):
            with self.subTest(exclusions=exclusions):
                entry["components"] = [*exclusions, rules[3]]
                self.assert_success(self.check_document(document, TEAM, *reversed(BUNDLES)))

    def test_association_rejects_exclusions_shadowed_by_the_inclusion(self):
        document = self.association_document()
        entry = document["applinks"]["details"][0]
        rules = copy.deepcopy(entry["components"])
        for position in range(3):
            with self.subTest(position=position):
                entry["components"] = [*rules[:position], rules[3], *rules[position:3]]
                result = self.check_document(document)
                self.assertNotEqual(result.returncode, 0, result.stderr)
                self.assertIn("before", result.stderr)

    def test_association_rejects_mutated_matching_rules_and_wrong_ids(self):
        original = self.association_document()
        mutations = [
            (0, "exclude", False), (1, "?", "only-this-query"),
            (2, "#", "only-this-fragment"), (3, "?", "query-required"),
            (3, "/", "/a/*"), (0, "exclude", "true"),
        ]
        for index, key, value in mutations:
            with self.subTest(index=index, key=key, value=value):
                document = copy.deepcopy(original)
                document["applinks"]["details"][0]["components"][index][key] = value
                result = self.check_document(document)
                self.assertNotEqual(result.returncode, 0, result.stderr)
                self.assertNotIn("Traceback", result.stderr)
        result = self.check_document(original, TEAM, "dev.swiftty.other")
        self.assertNotEqual(result.returncode, 0, result.stderr)

    def test_additional_exclusions_comments_and_explicit_false_inclusion_remain_supported(self):
        document = self.association_document()
        rules = document["applinks"]["details"][0]["components"]
        rules.insert(0, {"/": "/a/reserved", "exclude": True,
                         "comment": "an additional site policy"})
        rules.insert(1, {"/": "/a/*", "?": {"blocked": "?*"}, "exclude": True})
        rules[-1]["exclude"] = False
        document["applinks"]["apps"] = []
        self.assert_success(self.check_document(document))

    def test_malformed_structures_and_matching_overrides_report_validation_errors(self):
        original = self.association_document()
        documents = [[], {"applinks": []}, {"applinks": {"details": []}}]
        for key, value in [("appIDs", "TEAMID1234.dev.swiftty.fixture"),
                           ("appIDs", [123]), ("appIDs", ["bad.dev.fixture"]),
                           ("components", [None]), ("components", [[]]),
                           ("defaults", {"caseSensitive": False})]:
            document = copy.deepcopy(original)
            document["applinks"]["details"][0][key] = value
            documents.append(document)
        for key, value in [("exclude", 1), ("/", ["/a/*/*"]),
                           ("?", {"query": []}), ("comment", []),
                           ("caseSensitive", False)]:
            document = copy.deepcopy(original)
            document["applinks"]["details"][0]["components"][0][key] = value
            documents.append(document)
        for document in documents:
            with self.subTest(document=document):
                result = self.check_document(document)
                self.assertNotEqual(result.returncode, 0, result.stderr)
                self.assertNotIn("Traceback", result.stderr)

    def test_output_file_generation_and_invalid_identifiers(self):
        output = self.root / "association with spaces"
        result = self.run_script("make-aasa.sh", "-o", output, TEAM, *BUNDLES)
        self.assert_success(result)
        document = json.loads(output.read_text())
        self.assert_success(self.check_document(document, TEAM, *BUNDLES))
        before = output.read_bytes()
        for arguments in [["TEAMID12345", *BUNDLES], [TEAM, "invalid..bundle"],
                          [TEAM, "invalid/bundle"], [TEAM, 'quoted".bundle']]:
            with self.subTest(arguments=arguments):
                result = self.run_script("make-aasa.sh", "-o", output, *arguments)
                self.assertEqual(result.returncode, 64, result.stderr)
                self.assertEqual(output.read_bytes(), before)


if __name__ == "__main__":
    unittest.main()
