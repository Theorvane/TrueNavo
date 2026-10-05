import copy
import datetime
import importlib.util
from pathlib import Path
import plistlib
import tempfile
import unittest
import zipfile

spec = importlib.util.spec_from_file_location("apple_signing", Path(__file__).resolve().parents[1] / "apple_signing.py")
apple = importlib.util.module_from_spec(spec)
spec.loader.exec_module(apple)


class AppleSigningTest(unittest.TestCase):
    team = "TESTTEAM01"
    bundle = "com.sloki9637.truenavo"
    now = datetime.datetime(2026, 1, 1)

    def profile(self):
        return {"Name": "TrueNavo App Store", "UUID": "12345678-1234-1234-1234-123456789ABC",
                "TeamIdentifier": [self.team], "ExpirationDate": self.now + datetime.timedelta(days=1),
                "Entitlements": {"application-identifier": f"{self.team}.{self.bundle}",
                                 "com.apple.developer.team-identifier": self.team,
                                 "get-task-allow": False}}

    def test_accepts_matching_app_store_profile(self):
        self.assertEqual(apple.validate_profile(self.profile(), self.team, self.bundle, self.now),
                         ("TrueNavo App Store", "12345678-1234-1234-1234-123456789ABC"))

    def test_rejects_wrong_identity_expired_and_other_profile_types(self):
        changes = [{"TeamIdentifier": ["OTHERTEAM"]}, {"ExpirationDate": self.now},
                   {"ProvisionedDevices": []}, {"ProvisionsAllDevices": True},
                   {"Name": "Injected\nPROFILE_UUID=other"}, {"UUID": "../../other"},
                   {"Entitlements": {"application-identifier": f"{self.team}.*"}}]
        for change in changes:
            profile = copy.deepcopy(self.profile())
            profile.update(change)
            with self.subTest(change=change), self.assertRaises(ValueError):
                apple.validate_profile(profile, self.team, self.bundle, self.now)

    def test_export_does_not_renumber_store_build(self):
        self.assertFalse(apple.export_options(self.team, self.bundle, "Profile")["manageAppVersionAndBuildNumber"])

    def test_ipa_identity_and_version_are_checked(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "sample.ipa"
            info = {"CFBundleIdentifier": self.bundle, "CFBundleShortVersionString": "0.1.0",
                    "CFBundleVersion": "1", "CFBundleSupportedPlatforms": ["iPhoneOS"]}
            with zipfile.ZipFile(path, "w") as archive:
                archive.writestr("Payload/Runner.app/Info.plist", plistlib.dumps(info))
            apple.validate_ipa(path, self.bundle, "0.1.0", "1")
            with self.assertRaises(ValueError):
                apple.validate_ipa(path, self.bundle, "0.1.0", "2")
