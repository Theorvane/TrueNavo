import copy
import importlib.util
import json
from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("repository_triage", ROOT / ".github/scripts/triage.py")
triage = importlib.util.module_from_spec(spec)
spec.loader.exec_module(triage)
CONFIG = json.loads((ROOT / ".github/triage-labels.json").read_text())


def pull():
    return {"number": 1, "title": "feat: dashboard", "body": "", "state": "open",
            "draft": False, "labels": [], "user": {"login": "sjungwon03"},
            "base": {"ref": "dev", "repo": {"full_name": "Theorvane/TrueNavo"}},
            "head": {"ref": "feature", "repo": {"full_name": "Theorvane/TrueNavo"}}}


class FakeAPI:
    def __init__(self, item, files=None, requested=None, reviews=None):
        self.item = item
        self.files = files or []
        self.requested = requested or []
        self.reviews = reviews or []
        self.calls = []

    def __call__(self, method, path, payload=None):
        self.calls.append((method, path, payload))
        if method == "GET" and path.endswith("requested_reviewers"):
            return {"users": self.requested}
        if method == "GET":
            return copy.deepcopy(self.item)
        return {}

    def pages(self, path):
        self.calls.append(("GET", path, None))
        if path == "/labels":
            return CONFIG["labels"]
        return self.files if path.endswith("files") else self.reviews

    def writes(self):
        return [call for call in self.calls if call[0] != "GET"]


class RepositoryTriageTest(unittest.TestCase):
    def run_pr(self, api, action="opened"):
        triage.run({"pull_request": {"number": 1}, "action": action}, api, CONFIG)

    def test_policy_labels_and_codeowner_are_consistent(self):
        names = [label["name"] for label in CONFIG["labels"]]
        self.assertEqual(len(names), len(set(names)))
        for label in CONFIG["labels"]:
            self.assertRegex(label["color"], r"^[0-9a-f]{6}$")
        self.assertTrue(set(CONFIG["path_rules"]) <= set(names))
        self.assertIn("* @" + CONFIG["reviewer"], (ROOT / ".github/CODEOWNERS").read_text())

    def test_missing_labels_are_created_without_overwriting_existing_labels(self):
        class MissingLabels(FakeAPI):
            def pages(self, path):
                return [{"name": "BUG", "color": "abcdef", "description": "Manual description"}]

        api = MissingLabels({})
        config = {"labels": [CONFIG["labels"][0], CONFIG["labels"][1]]}
        triage.ensure_labels(api, config)
        self.assertEqual(api.writes(), [("POST", "/labels", CONFIG["labels"][1])])

    def test_label_creation_race_is_ignored_only_when_the_label_exists(self):
        class Racing(FakeAPI):
            def __init__(self, present):
                super().__init__({})
                self.reads = 0
                self.present = present

            def pages(self, path):
                self.reads += 1
                return [{"name": "bug"}] if self.reads > 1 and self.present else []

            def __call__(self, method, path, payload=None):
                raise triage.MetadataError(422)

        config = {"labels": [CONFIG["labels"][0]]}
        triage.ensure_labels(Racing(True), config)
        with self.assertRaises(triage.MetadataError):
            triage.ensure_labels(Racing(False), config)

    def test_titles_are_classified_as_data_not_commands(self):
        item = pull()
        item["title"] = "fix(android)!: $(touch /tmp/untrusted) ${{ secrets.VALUE }}"
        self.assertEqual(triage.classify(item, [], CONFIG, True, "edited"), ["bug"])
        item["title"] = "please do not fix this"
        self.assertEqual(triage.classify(item, [], CONFIG, True, "edited"), [])

    def test_issue_form_and_korean_prefix(self):
        item = {"title": "[버그] reconnect", "body": "### Change type\r\n\r\nBug report\r\n\r\n### Affected area\r\n\r\nSecurity / credentials\r\n"}
        self.assertEqual(triage.classify(item, [], CONFIG, False, "opened"),
                         ["area:security", "bug", "needs:triage"])
        self.assertNotIn("needs:triage", triage.classify(item, [], CONFIG, False, "edited"))

    def test_unknown_issue_text_gets_no_inferred_type_or_area(self):
        item = {"title": "unknown", "body": "### Change type\n\n${{ secrets.VALUE }}\n### Affected area\n\n../../../release"}
        self.assertEqual(triage.classify(item, [], CONFIG, False, "opened"), ["needs:triage"])

    def test_multiple_paths_and_rename_source_are_classified(self):
        item = pull()
        files = [{"filename": "docs/moved.md", "previous_filename": "apps/truenavo/android/app/a.kt"},
                 {"filename": "packages/truenas_api/test/a_test.dart"},
                 {"filename": "apps/truenavo/ios/Runner/a.swift"}]
        labels = set(triage.classify(item, files, CONFIG, True, "synchronize"))
        self.assertTrue({"area:android", "area:ios", "area:api", "tests", "documentation", "enhancement"} <= labels)

    def test_release_promotion_requires_the_same_repository(self):
        item = pull()
        item["base"]["ref"], item["head"]["ref"] = "main", "dev"
        self.assertIn("release:promotion", triage.classify(item, [], CONFIG, True, "opened"))
        item["head"]["repo"]["full_name"] = "attacker/TrueNavo"
        self.assertNotIn("release:promotion", triage.classify(item, [], CONFIG, True, "opened"))
        item["head"]["repo"] = None
        self.assertNotIn("release:promotion", triage.classify(item, [], CONFIG, True, "opened"))

    def test_labels_are_added_without_removing_manual_labels(self):
        item = pull()
        item["labels"] = [{"name": "help wanted"}, {"name": "enhancement"}]
        api = FakeAPI(item, files=[{"filename": "apps/truenavo/android/app/a.kt"}])
        self.run_pr(api)
        self.assertEqual(api.writes(), [
            ("POST", "/issues/1/labels", {"labels": ["area:android"]}),
            ("POST", "/pulls/1/requested_reviewers", {"reviewers": ["sjungwon03-ai"]}),
        ])

    def test_draft_and_self_review_requests_are_skipped(self):
        for draft, author in ((True, "sjungwon03"), (False, "sjungwon03-ai"), (False, "SJUNGWON03-AI")):
            item = pull()
            item["draft"], item["user"]["login"] = draft, author
            api = FakeAPI(item)
            self.run_pr(api)
            self.assertEqual([call[1] for call in api.writes()], ["/issues/1/labels"])

    def test_existing_review_request_is_not_duplicated(self):
        api = FakeAPI(pull(), requested=[{"login": "sjungwon03-ai"}])
        self.run_pr(api)
        self.assertEqual([call[1] for call in api.writes()], ["/issues/1/labels"])

    def test_active_review_is_not_spammed_but_dismissed_review_can_be_requested(self):
        for state, count in (("APPROVED", 0), ("CHANGES_REQUESTED", 0), ("COMMENTED", 0), ("DISMISSED", 1)):
            api = FakeAPI(pull(), reviews=[{"user": {"login": "sjungwon03-ai"}, "state": state}])
            self.run_pr(api, "synchronize")
            self.assertEqual(len([call for call in api.writes() if call[1].endswith("requested_reviewers")]), count)

    def test_closed_pr_does_not_mutate_metadata(self):
        item = pull()
        item["state"] = "closed"
        api = FakeAPI(item)
        self.run_pr(api)
        self.assertEqual(api.writes(), [])

    def test_issue_never_requests_reviews(self):
        item = {"number": 5, "title": "question: usage", "body": "", "labels": [], "state": "open"}
        api = FakeAPI(item)
        triage.run({"issue": {"number": 5}, "action": "opened"}, api, CONFIG)
        self.assertEqual(api.writes(), [("POST", "/issues/5/labels", {"labels": ["needs:triage"]})])

    def test_api_adapter_cannot_approve_merge_delete_or_use_external_urls(self):
        api = triage.GitHub("Theorvane/TrueNavo", "synthetic-token")
        for method, path in (("POST", "/pulls/1/reviews"), ("PUT", "/pulls/1/merge"),
                             ("DELETE", "/issues/1/labels/bug"), ("GET", "https://attacker.invalid/"),
                             ("GET", "/actions/secrets"), ("GET", "/pulls/0")):
            with self.subTest(method=method, path=path), self.assertRaises(ValueError):
                api(method, path)

    def test_api_adapter_rejects_invalid_repository(self):
        with self.assertRaises(ValueError):
            triage.GitHub("../outside", "synthetic-token")

    def test_pagination_does_not_drop_file_101(self):
        class Paginated(triage.GitHub):
            def __init__(self):
                self.seen = []

            def __call__(self, method, path, payload=None):
                self.seen.append(path)
                return [{}] * 100 if path.endswith("page=1") else [{"filename": "file101"}]

        api = Paginated()
        values = api.pages("/pulls/1/files")
        self.assertEqual(len(values), 101)
        self.assertEqual(len(api.seen), 2)


if __name__ == "__main__":
    unittest.main()
