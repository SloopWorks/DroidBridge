#!/usr/bin/env python3
import importlib.util
from pathlib import Path
import json
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("downloads", Path(__file__).with_name("telemetry-downloads.py"))
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


def inventory(assets, complete=True):
    return {"inventory_complete": complete, "releases": [{"id": 1, "draft": False, "prerelease": True, "assets": assets, "author": {"email": "PRIVATE_SENTINEL"}, "body": "PRIVATE_SENTINEL"}]}


def asset(identity, count, name="DroidBridge-0.2.0-arm64.dmg"):
    return {"id": identity, "name": name, "download_count": count, "state": "uploaded", "uploader": {"email": "PRIVATE_SENTINEL"}, "browser_download_url": "https://PRIVATE_SENTINEL/"}


class DownloadMetricsTests(unittest.TestCase):
    def report(self, value, previous=None):
        return module.summarize(value, "SloopWorks/DroidBridge", previous, "2026-11-21")

    def test_no_customer_or_uploader_identity_and_formats_stay_separate(self):
        report = self.report(inventory([asset(1, 4), asset(2, 7, "DroidBridge-0.2.0-arm64.zip"), asset(3, 9, "release-manifest.json")]))
        self.assertNotIn("PRIVATE_SENTINEL", json.dumps(report))
        self.assertEqual(report["cumulative_downloads_by_kind"]["mac_installer"], 4)
        self.assertEqual(report["cumulative_downloads_by_kind"]["mac_archive"], 7)
        self.assertEqual(report["cumulative_downloads_by_kind"]["metadata"], 9)
        self.assertIsNone(report["interval_download_delta"])

    def test_deltas_refuse_replaced_deleted_or_reset_assets(self):
        previous = self.report(inventory([asset(1, 10)]))
        self.assertEqual(self.report(inventory([asset(1, 14)]), previous)["interval_download_delta"], 4)
        for current in [[asset(1, 2)], [asset(2, 20)], [asset(1, 14), asset(2, 3)], []]:
            self.assertIsNone(self.report(inventory(current), previous)["interval_download_delta"])

    def test_empty_or_incomplete_inventory_is_not_zero_customer_usage(self):
        result = self.report({"inventory_complete": True, "releases": []})
        self.assertFalse(result["counters_available"])
        self.assertIsNone(result["interval_download_delta"])
        previous = self.report(inventory([asset(1, 1)]))
        self.assertIsNone(self.report(inventory([asset(1, 2)], False), previous)["interval_download_delta"])

    def test_bools_negatives_duplicates_and_repository_mixups_refused(self):
        for value in [True, -1, 2**63, 1.5]:
            with self.assertRaises(ValueError):
                self.report(inventory([asset(1, value)]))
        with self.assertRaises(ValueError):
            self.report(inventory([asset(1, 2), asset(1, 3)]))
        previous = self.report(inventory([asset(1, 2)])); previous["repository"] = "other/project"
        with self.assertRaises(ValueError):
            self.report(inventory([asset(1, 3)]), previous)

    def test_fetches_all_asset_pages_instead_of_nested_release_preview(self):
        release = {"id": 12, "draft": False, "prerelease": False, "assets": [asset(999, 999)]}
        calls = []
        def page(path):
            calls.append(path)
            if "/assets?" not in path:
                return [release]
            if path.endswith("page=1"):
                return [asset(i, i) for i in range(1, 101)]
            return [asset(101, 101)]
        with patch.object(module, "gh_page", page):
            value = module.github_inventory("SloopWorks/DroidBridge")
        self.assertEqual(self.report(value)["asset_count"], 101)
        self.assertTrue(any("releases/12/assets?per_page=100&page=2" in c for c in calls))


if __name__ == "__main__":
    unittest.main()
