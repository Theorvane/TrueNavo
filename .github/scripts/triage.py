"""Add deterministic labels and request review; never execute PR content."""

import fnmatch
import json
import os
from pathlib import Path
import re
import urllib.error
import urllib.request


TITLE_TYPES = {
    "fix": "bug", "feat": "enhancement", "docs": "documentation",
    "chore": "maintenance", "refactor": "maintenance", "perf": "enhancement",
    "style": "maintenance", "build": "maintenance", "test": "tests",
    "ci": "area:ci",
}
FORM_TYPES = {
    "Bug report": "bug", "Feature request": "enhancement",
    "Question": "question", "Maintenance": "maintenance",
}
FORM_AREAS = {
    "Android": "area:android", "iOS": "area:ios", "Desktop": "area:desktop",
    "Web": "area:web", "TrueNAS API": "area:api", "UI / design": "area:ui",
    "Security / credentials": "area:security", "CI / release": "area:release",
    "Documentation": "documentation",
}


def selection(body, heading):
    normalized = (body or "").replace("\r\n", "\n")
    match = re.search(r"^### " + re.escape(heading) + r"\n+([^\n]+)", normalized, re.MULTILINE)
    return match.group(1).strip() if match else None


def classify(item, files, config, is_pr, action):
    labels = set()
    title = item.get("title") or ""
    conventional = re.match(r"^\s*([a-z]+)(?:\([^\r\n)]*\))?!?:", title, re.IGNORECASE)
    if conventional and conventional.group(1).lower() in TITLE_TYPES:
        labels.add(TITLE_TYPES[conventional.group(1).lower()])
    for prefix, label in (("[bug]", "bug"), ("[버그]", "bug"),
                          ("[feature]", "enhancement"), ("[기능]", "enhancement"),
                          ("[question]", "question"), ("[질문]", "question")):
        if title.strip().lower().startswith(prefix):
            labels.add(label)
    if not is_pr:
        kind = FORM_TYPES.get(selection(item.get("body"), "Change type"))
        area = FORM_AREAS.get(selection(item.get("body"), "Affected area"))
        labels.update(label for label in (kind, area) if label)
        if action in ("opened", "reopened"):
            labels.add("needs:triage")
    paths = [file[key] for file in files for key in ("filename", "previous_filename") if file.get(key)]
    for label, patterns in config["path_rules"].items():
        if any(fnmatch.fnmatchcase(path, pattern) for path in paths for pattern in patterns):
            labels.add(label)
    if is_pr and (item.get("base", {}).get("ref") == "main"
                  and item.get("head", {}).get("ref") == "dev"
                  and (item.get("head", {}).get("repo") or {}).get("full_name")
                  == (item.get("base", {}).get("repo") or {}).get("full_name")):
        labels.update(("release:promotion", "area:release"))
    known = {label["name"] for label in config["labels"]}
    if not labels <= known:
        raise ValueError("Classification uses a label not in the trusted policy")
    return sorted(labels)


class MetadataError(RuntimeError):
    def __init__(self, status):
        self.status = status
        super().__init__(f"GitHub metadata request failed (HTTP {status}); response suppressed")


def ensure_labels(api, config):
    existing = {label["name"].lower() for label in api.pages("/labels")}
    for label in config["labels"]:
        if label["name"].lower() not in existing:
            try:
                api("POST", "/labels", label)
            except MetadataError as error:
                # Two different issues can be triaged at once after policy adds
                # a label. Only ignore a creation conflict if that label exists.
                if error.status != 422 or label["name"].lower() not in {
                    entry["name"].lower() for entry in api.pages("/labels")
                }:
                    raise
    # Existing colors/descriptions are intentionally not overwritten.


def run(event, api, config):
    is_pr = "pull_request" in event
    number = int((event.get("pull_request") or event["issue"])["number"])
    if number <= 0:
        raise ValueError("Invalid issue number")
    # Read the current state, not an old event snapshot from a queued run.
    item = api("GET", f"/pulls/{number}" if is_pr else f"/issues/{number}")
    if item.get("state") != "open":
        return
    ensure_labels(api, config)
    files = []
    if is_pr:
        files = api.pages(f"/pulls/{number}/files")
        if item.get("changed_files", 0) > 3000:
            print("GitHub exposes at most 3,000 changed files; path labels may be incomplete")
    labels = classify(item, files, config, is_pr, event.get("action"))
    existing = {label["name"] for label in item.get("labels", [])}
    additions = sorted(set(labels) - existing)
    if additions:
        api("POST", f"/issues/{number}/labels", {"labels": additions})
        print(f"Added {len(additions)} policy labels to #{number}")
    # Additive labeling intentionally keeps manual/existing labels, including
    # labels from an earlier classification. Maintainers resolve stale labels.
    reviewer = config["reviewer"]
    if not is_pr or item.get("draft") or item["user"]["login"].lower() == reviewer.lower():
        return
    requested = api("GET", f"/pulls/{number}/requested_reviewers")
    if any(user["login"].lower() == reviewer.lower() for user in requested.get("users", [])):
        return
    reviews = api.pages(f"/pulls/{number}/reviews")
    if any((review.get("user") or {}).get("login", "").lower() == reviewer.lower()
           and review.get("state") != "DISMISSED" for review in reviews):
        return  # Do not spam a reviewer who has already reviewed this PR.
    api("POST", f"/pulls/{number}/requested_reviewers", {"reviewers": [reviewer]})
    print(f"Requested review for #{number} (no approval or merge performed)")


class GitHub:
    def __init__(self, repository, token):
        if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9-]*/(?!\.{1,2}$)[A-Za-z0-9_.-]+", repository):
            raise ValueError("Invalid repository")
        self.base = "https://api.github.com/repos/" + repository
        self.token = token

    def __call__(self, method, path, payload=None):
        # Only scoped metadata operations. No approvals, merges, workflow runs,
        # branch writes, environment secrets, or untrusted URLs are supported.
        allowed = (method == "GET" and re.fullmatch(r"/(?:pulls|issues)/[1-9][0-9]*(?:/(?:files|requested_reviewers|reviews))?(?:\?per_page=100&page=[1-9][0-9]*)?", path))
        allowed = allowed or (method == "GET" and re.fullmatch(r"/labels(?:\?per_page=100&page=[1-9][0-9]*)?", path))
        allowed = allowed or (method == "POST" and re.fullmatch(r"/(?:issues/[1-9][0-9]*/labels|pulls/[1-9][0-9]*/requested_reviewers)", path))
        allowed = allowed or (method == "POST" and path == "/labels")
        if not allowed:
            raise ValueError("Unapproved metadata operation")
        headers = {"Authorization": "Bearer " + self.token,
                   "Accept": "application/vnd.github+json", "X-GitHub-Api-Version": "2022-11-28"}
        if payload is not None:
            headers["Content-Type"] = "application/json"
        request = urllib.request.Request(self.base + path, headers=headers, method=method,
            data=json.dumps(payload).encode() if payload is not None else None)
        try:
            with urllib.request.urlopen(request, timeout=30) as response:
                return json.load(response)
        except urllib.error.HTTPError as error:
            raise MetadataError(error.code) from None

    def pages(self, path):
        values = []
        page = 1
        while True:
            batch = self("GET", f"{path}?per_page=100&page={page}")
            values.extend(batch)
            if len(batch) < 100:
                return values
            page += 1


if __name__ == "__main__":
    policy_path = Path(__file__).resolve().parents[1] / "triage-labels.json"
    config = json.loads(policy_path.read_text())
    event = json.loads(Path(os.environ["GITHUB_EVENT_PATH"]).read_text())
    run(event, GitHub(os.environ["GITHUB_REPOSITORY"], os.environ["GH_TOKEN"]), config)
