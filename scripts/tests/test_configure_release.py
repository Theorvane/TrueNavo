import importlib.util
from pathlib import Path
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("configure_release", Path(__file__).resolve().parents[1] / "configure_release.py")
configure = importlib.util.module_from_spec(spec)
spec.loader.exec_module(configure)


class ConfigureReleaseTest(unittest.TestCase):
    def test_secret_goes_to_stdin_not_arguments_or_console(self):
        synthetic = b"synthetic-test-value-not-a-credential"
        with patch.object(configure.subprocess, "run") as run, patch("builtins.print") as output:
            configure.secret("play-store", "TEST", synthetic)
        self.assertEqual(run.call_args.kwargs["input"], synthetic)
        self.assertNotIn(synthetic.decode(), " ".join(run.call_args.args[0]))
        self.assertNotIn(synthetic.decode(), str(output.call_args_list))
        self.assertIn("Theorvane/TrueNavo", run.call_args.args[0])

    def test_empty_secret_is_rejected_before_any_upload(self):
        with patch.object(configure.subprocess, "run") as run, self.assertRaises(ValueError):
            configure.secret("play-store", "TEST", b"")
        run.assert_not_called()
