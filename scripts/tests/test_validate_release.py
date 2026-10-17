import unittest

from scripts.validate_release import validate


class ReleaseValidationTests(unittest.TestCase):
    def test_first_release(self):
        validate("1.0.3", "4", [[]], "1.0.2+3")

    def test_invalid_versions(self):
        for version in ("v1.0.3", "1.0", "01.0.3", "1.0.3-beta", "1.0.3\n", "$(id)", "1.0.3; ls"):
            with self.subTest(version=version), self.assertRaises(ValueError):
                validate(version, "4", [[]], "1.0.2+3")

    def test_invalid_build_numbers(self):
        for build in ("0", "-1", "04", "4.0", "4\n", "2100000001", "$(id)"):
            with self.subTest(build=build), self.assertRaises(ValueError):
                validate("1.0.3", build, [[]], "1.0.2+3")

    def test_source_version_can_match(self):
        validate("1.0.2", "3", [[]], "1.0.2+3")

    def test_source_version_and_build_must_not_decrease(self):
        for version, build in (("1.0.1", "4"), ("0.9.0", "4"), ("1.0.3", "2")):
            with self.subTest(version=version, build=build), self.assertRaises(ValueError):
                validate(version, build, [[]], "1.0.2+3")

    def test_published_versions_and_builds_must_increase_across_pages(self):
        pages = [[{"tag_name": "v1.0.3", "body": "Build number: 4"}],
                 [{"tag_name": "v1.1.0", "body": "Build number: 10"}]]
        for version, build in (("1.0.4", "11"), ("1.1.1", "10")):
            with self.subTest(version=version, build=build), self.assertRaises(ValueError):
                validate(version, build, pages, "1.0.2+3")
        validate("1.1.1", "11", pages, "1.0.2+3")

    def test_duplicate_draft_is_rejected(self):
        pages = [[{"tag_name": "v1.0.3", "draft": True, "body": None}]]
        with self.assertRaises(ValueError):
            validate("1.0.3", "4", pages, "1.0.2+3")

    def test_unpublished_drafts_do_not_raise_version_floor(self):
        pages = [[{"tag_name": "v2.0.0", "draft": True, "body": "Build number: 20"}]]
        validate("1.0.3", "4", pages, "1.0.2+3")

    def test_android_maximum(self):
        validate("2.0.0", "2100000000", [[]], "1.0.2+3")


if __name__ == "__main__":
    unittest.main()
