import os
import pathlib
import plistlib
import shutil
import subprocess
import sys
import tempfile
import unittest

SCRIPT = pathlib.Path(__file__).resolve().parents[1] / "verify-dmg.sh"


def tool(name):
    return shutil.which(name) is not None


@unittest.skipUnless(sys.platform == "darwin" and tool("hdiutil") and tool("codesign") and tool("cc"),
                     "needs macOS developer tools")
class VerifyDmgTests(unittest.TestCase):
    """Builds tiny throwaway apps and DMGs and runs scripts/verify-dmg.sh on them."""

    def setUp(self):
        self.tmp = pathlib.Path(tempfile.mkdtemp(prefix="verify-dmg-test."))
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)

    def make_app(self, root, name="macsh-lite", seal=False):
        app = root / f"{name}.app"
        (app / "Contents/MacOS").mkdir(parents=True)
        (app / "Contents/Resources").mkdir()
        src = self.tmp / "main.c"
        src.write_text("int main(void){return 0;}\n")
        subprocess.run(["cc", "-arch", "arm64", "-o", str(app / "Contents/MacOS" / name), str(src)], check=True)
        with open(app / "Contents/Info.plist", "wb") as f:
            plistlib.dump({"CFBundleIdentifier": f"test.{name}", "CFBundleExecutable": name,
                           "CFBundleShortVersionString": "9.9.9", "CFBundleName": name,
                           "CFBundlePackageType": "APPL", "LSMinimumSystemVersion": "14.0"}, f)
        (app / "Contents/Resources/hello.txt").write_text("resource the signature must seal\n")
        if seal:
            subprocess.run(["codesign", "--force", "--deep", "--sign", "-", str(app)], check=True, capture_output=True)
        return app

    def make_dmg(self, name="macsh-lite", seal=False, applications_link=True):
        stage = self.tmp / f"stage-{name}-{seal}-{applications_link}"
        stage.mkdir()
        self.make_app(stage, name, seal)
        if applications_link:
            os.symlink("/Applications", stage / "Applications")
        dmg = self.tmp / f"{name}-9.9.9.dmg"
        subprocess.run(["hdiutil", "create", "-volname", name, "-srcfolder", str(stage), "-ov",
                        "-fs", "HFS+", "-format", "UDZO", str(dmg)], check=True, capture_output=True)
        return dmg

    def verify(self, dmg):
        r = subprocess.run([str(SCRIPT), str(dmg)], capture_output=True, text=True)
        return r.returncode, r.stdout + r.stderr

    def test_unsealed_app_is_reported_as_the_damaged_case(self):
        # Same shape as the real bug: a linker-signed executable inside a bundle with resources.
        code, out = self.verify(self.make_dmg(seal=False))
        self.assertNotEqual(code, 0, out)
        self.assertIn("invalid code signature", out)
        self.assertIn("Gatekeeper cannot assess", out)

    def test_sealed_app_passes(self):
        code, out = self.verify(self.make_dmg(seal=True))
        self.assertEqual(code, 0, out)
        self.assertIn("code signature is valid for the whole bundle", out)
        self.assertIn("All checks passed", out)

    def test_missing_applications_shortcut_fails(self):
        code, out = self.verify(self.make_dmg(seal=True, applications_link=False))
        self.assertNotEqual(code, 0, out)
        self.assertIn("no Applications -> /Applications symlink", out)

    def test_missing_file_fails(self):
        code, out = self.verify(self.tmp / "nope.dmg")
        self.assertNotEqual(code, 0)
        self.assertIn("file not found", out)

    def test_no_arguments_prints_usage(self):
        r = subprocess.run([str(SCRIPT)], capture_output=True, text=True)
        self.assertEqual(r.returncode, 2)
        self.assertIn("usage", r.stderr)

    def test_leaves_no_mounts_behind(self):
        before = subprocess.run(["mount"], capture_output=True, text=True).stdout.count("verify-dmg")
        self.verify(self.make_dmg(seal=True))
        after = subprocess.run(["mount"], capture_output=True, text=True).stdout.count("verify-dmg")
        self.assertEqual(before, after)


if __name__ == "__main__":
    unittest.main()
