#!/usr/bin/env python3
import os
import plistlib
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


class BuildReleaseTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="uwvpn-release-")
        self.root = Path(self.temp.name)
        self.repo = self.root / "repo"
        shutil.copytree(ROOT, self.repo, ignore=shutil.ignore_patterns(".git", "build", "dist"))
        subprocess.run(["git", "init", "-q"], cwd=self.repo, check=True)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.log = self.root / "commands.log"
        self.make_doubles()
        (self.repo / "tests" / "packaged-tunnel.py").write_text('''#!/usr/bin/env python3
import os, sys
with open(os.environ["TOOL_LOG"], "a") as log: log.write("packaged-tunnel " + sys.argv[1] + "\\n")
''')
        (self.repo / "src" / "UWVPN" / "BuildFixture.swift").write_text('let buildFixture = true\n')
        self.commit("fixture")
        self.revision = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=self.repo, text=True).strip()

    def tearDown(self):
        self.temp.cleanup()

    def commit(self, message):
        subprocess.run(["git", "add", "."], cwd=self.repo, check=True)
        subprocess.run([
            "git", "-c", "user.name=Build Test", "-c", "user.email=build@example.invalid",
            "commit", "-qm", message,
        ], cwd=self.repo, check=True)

    def tool(self, name, body):
        path = self.bin / name
        path.write_text("#!/usr/bin/python3\n" + body)
        path.chmod(0o755)

    def make_doubles(self):
        self.tool("go", '''
import os, pathlib, sys
with open(os.environ["TOOL_LOG"], "a") as log: log.write("go " + " ".join(sys.argv[1:]) + "\\n")
if sys.argv[1] == "env":
    root = pathlib.Path(os.environ["TEST_TEMP"]) / "goroot"
    root.mkdir(exist_ok=True)
    (root / "LICENSE").write_text("Go license")
    print(root)
elif sys.argv[1] == "build":
    output = pathlib.Path(sys.argv[sys.argv.index("-o") + 1])
    output.write_bytes(os.environ["GOARCH"].encode())
    output.chmod(0o755)
''')
        self.tool("xcrun", '''
import os, pathlib, sys
with open(os.environ["TOOL_LOG"], "a") as log: log.write("xcrun " + " ".join(sys.argv[1:]) + "\\n")
args = sys.argv[1:]
if args[0] == "swiftc" and "--version" in args: print("Swift 6")
elif args[0] == "swiftc":
    sources = [pathlib.Path(a).name for a in args if a.endswith(".swift")]
    output = pathlib.Path(args[args.index("-o") + 1])
    output.write_text("\\n".join(sources))
    output.chmod(0o755)
elif args[:2] == ["vtool", "-show-build"]:
    print("Load command 9\\n      cmd LC_VERSION_MIN_MACOSX\\n  minos 26.0\\n      sdk 26.0")
elif args[0] == "--show-sdk-version": print("26.0")
elif args[0] == "--show-sdk-path": print("/SDK")
elif args[0] == "notarytool":
    if os.environ.get("FAIL_NOTARY") == "1": sys.exit(7)
elif args[0] == "stapler":
    pathlib.Path(args[-1], "Contents", "Resources", "stapled").write_text("ticket")
''')
        self.tool("codesign", '''
import os, sys
args = sys.argv[1:]
with open(os.environ["TOOL_LOG"], "a") as log: log.write("codesign " + " ".join(args) + "\\n")
if os.environ.get("UWVPN_BUILD_MODE") == "release" and "--sign" in args and "-" in args:
    raise AssertionError("release fell back to ad-hoc signing")
if args[0] == "-dvv":
    print("Authority=" + os.environ["UWVPN_SIGN_IDENTITY"])
    print("flags=0x10000(runtime)")
    print("flags=0x10000(runtime)")
''')
        self.tool("otool", "print('/usr/lib/libSystem.B.dylib')")
        self.tool("spctl", '''
import os, sys
with open(os.environ["TOOL_LOG"], "a") as log: log.write("spctl " + " ".join(sys.argv[1:]) + "\\n")
if os.environ.get("FAIL_GATEKEEPER") == "1": sys.exit(8)
''')
        self.tool("lipo", '''
import pathlib, sys
args = sys.argv[1:]
if args[0] == "-archs": print("arm64 x86_64")
else:
    pathlib.Path(args[args.index("-output") + 1]).write_bytes(b"arm64 x86_64")
''')

    def run_script(self, script, *args, env=None, expect=0):
        environment = os.environ.copy()
        environment.update({
            "PATH": str(self.bin) + ":/usr/bin:/bin:/usr/sbin:/sbin",
            "TOOL_LOG": str(self.log),
            "TEST_TEMP": str(self.root),
            "UWVPN_COMMIT": self.revision,
        })
        environment.update(env or {})
        result = subprocess.run([str(self.repo / "scripts" / script), *map(str, args)],
                                cwd=self.repo, env=environment, text=True, capture_output=True)
        if expect is not None:
            self.assertEqual(expect, result.returncode, result.stdout + result.stderr)
        return result

    def fingerprint(self, arch):
        return subprocess.check_output(
            [str(self.repo / "scripts" / "build-helpers.sh"), "--fingerprint", arch],
            env={"PATH": str(self.bin) + ":/usr/bin:/bin", "TOOL_LOG": str(self.log),
                 "TEST_TEMP": str(self.root)}, text=True).strip()

    def build_arch(self, arch, env=None):
        helpers = self.root / "helpers" / arch
        (helpers / "bin").mkdir(parents=True)
        (helpers / "licenses").mkdir()
        for name in ["openconnect", "tun-socks"]:
            (helpers / "bin" / name).write_text(arch)
            (helpers / "bin" / name).chmod(0o755)
        for name in ["OpenConnect.txt", "OpenSSL.txt"]:
            (helpers / "licenses" / name).write_text(name)
        (helpers / "fingerprint").write_text(self.fingerprint(arch))
        output = self.root / arch
        self.run_script("build-app.sh", arch, helpers, output / "UWVPN.app", env=env)
        return output

    def package(self, path, arch):
        archive = path / f"UWVPN-macOS-{arch}.zip"
        subprocess.run(["ditto", "-c", "-k", "--keepParent", str(path / "UWVPN.app"), str(archive)], check=True)

    def release_env(self, identity="Developer ID Application: Example (TEAMID)"):
        return {
            "UWVPN_BUILD_MODE": "release", "UWVPN_RELEASE_TAG": "v1.2.3",
            "UWVPN_BUILD_NUMBER": "42", "UWVPN_SIGN_IDENTITY": identity,
            "UWVPN_NOTARY_PROFILE": "test-profile",
        }

    def test_personal_build_is_traceable_and_compiles_every_swift_file(self):
        output = self.build_arch("arm64")
        info = plistlib.loads((output / "UWVPN.app" / "Contents" / "Info.plist").read_bytes())
        self.assertEqual(info["UWVPNSourceRevision"], self.revision)
        self.assertEqual(info["UWVPDistribution"], "adhoc")
        self.assertIn("-adhoc+", info["CFBundleShortVersionString"])
        self.assertIn("BuildFixture.swift", (output / "UWVPN.app" / "Contents" / "MacOS" / "UWVPN").read_text())
        commands = self.log.read_text()
        self.assertIn("codesign --force --deep --sign - --timestamp=none", commands)
        self.assertNotIn("notarytool", commands)

    def test_public_build_requires_developer_id_and_matching_tag(self):
        env = self.release_env()
        self.run_script("build-app.sh", "arm64", self.root / "unused", self.root / "bad.app", env=env, expect=1)
        subprocess.run(["git", "tag", "v1.2.3"], cwd=self.repo, check=True)
        env["UWVPN_SIGN_IDENTITY"] = "-"
        result = self.run_script("build-app.sh", "arm64", self.root / "unused", self.root / "bad.app", env=env, expect=1)
        self.assertIn("Developer ID", result.stderr)
        self.assertFalse((self.root / "bad.app").exists())

    def test_public_archives_keep_identity_and_pass_release_gates(self):
        subprocess.run(["git", "tag", "v1.2.3"], cwd=self.repo, check=True)
        env = self.release_env()
        for arch in ["arm64", "x86_64"]:
            self.package(self.build_arch(arch, env), arch)
        self.run_script("build-universal.sh", self.root / "arm64", env=env, expect=1)
        for arch in ["arm64", "x86_64"]:
            shutil.copy(self.root / arch / f"UWVPN-macOS-{arch}.zip", self.root)
        self.run_script("build-universal.sh", self.root, env=env)
        self.run_script("notarize-app.sh", self.root, env=env)
        self.run_script("notarize-app.sh", self.root, env={"UWVPN_BUILD_MODE": "adhoc"}, expect=1)
        for arch in ["arm64", "x86_64", "universal"]:
            destination = self.root / "check" / arch
            subprocess.run(["ditto", "-x", "-k", str(self.root / f"UWVPN-macOS-{arch}.zip"), str(destination)], check=True)
            app = destination / "UWVPN.app"
            self.assertTrue((app / "Contents" / "Resources" / "stapled").exists())
            info = plistlib.loads((app / "Contents" / "Info.plist").read_bytes())
            self.assertEqual(info["CFBundleShortVersionString"], "1.2.3")
            self.assertEqual(info["CFBundleVersion"], "42")
            self.assertEqual(info["UWVPNSourceRevision"], self.revision)
            self.assertEqual(info["UWVPDistribution"], "release")
        commands = self.log.read_text()
        self.assertEqual(commands.count("notarytool submit"), 3)
        self.assertEqual(commands.count("spctl --assess"), 6)
        self.assertNotIn("--sign -", commands)
        self.assertIn("--options runtime", commands)
        self.assertGreaterEqual(commands.count("packaged-tunnel"), 3)

    def test_universal_rejects_mixed_build_identities(self):
        subprocess.run(["git", "tag", "v1.2.3"], cwd=self.repo, check=True)
        env = self.release_env()
        self.package(self.build_arch("arm64", env), "arm64")
        self.package(self.build_arch("x86_64"), "x86_64")
        for arch in ["arm64", "x86_64"]:
            shutil.copy(self.root / arch / f"UWVPN-macOS-{arch}.zip", self.root)
        result = self.run_script("build-universal.sh", self.root, env=env, expect=1)
        self.assertIn("disagree", result.stderr)

    def test_gatekeeper_failure_blocks_notarization(self):
        subprocess.run(["git", "tag", "v1.2.3"], cwd=self.repo, check=True)
        env = self.release_env()
        env["FAIL_GATEKEEPER"] = "1"
        for arch in ["arm64", "x86_64"]:
            self.package(self.build_arch(arch, env), arch)
            shutil.copy(self.root / arch / f"UWVPN-macOS-{arch}.zip", self.root)
        self.run_script("build-universal.sh", self.root, env=env)
        self.run_script("notarize-app.sh", self.root, env=env, expect=8)
        self.assertNotIn("packaged-tunnel", self.log.read_text())

    def test_toolchain_fingerprint_tracks_pkgconf_version(self):
        self.tool("pkgconf", "print('1.0.0')")
        environment = os.environ.copy()
        environment.update({"PATH": str(self.bin) + ":/usr/bin:/bin", "TOOL_LOG": str(self.log)})
        first = subprocess.check_output([str(self.repo / "scripts" / "build-helpers.sh"), "--fingerprint", "arm64"], env=environment, text=True).strip()
        self.tool("pkgconf", "print('2.0.0')")
        second = subprocess.check_output([str(self.repo / "scripts" / "build-helpers.sh"), "--fingerprint", "arm64"], env=environment, text=True).strip()
        self.assertNotEqual(first, second)


if __name__ == "__main__":
    unittest.main(verbosity=2)
