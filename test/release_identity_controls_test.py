"""Release source-authorisation controls, including the pinned GitHub merge."""
from __future__ import annotations

import unittest
import os
from unittest import mock

from tool.release import verify_release_identity as identity

ROOT_POLICY = __import__("pathlib").Path(__file__).resolve().parents[1] / "tool/release/release_contract.json"
MERGE = "0405b5b181f56159f260c235b3a5206a0d7499b1"


class ReleaseIdentityControlsTest(unittest.TestCase):
    @unittest.skipUnless(os.environ.get("DAEROH_LIVE_GITHUB_IDENTITY") == "1", "opt-in live GitHub identity control")
    def test_main_merge_is_github_verified_and_authorized(self) -> None:
        # Live, read-only GitHub API control for the committed release contract.
        identity.github_identity(MERGE, ROOT_POLICY)

    def test_web_flow_committer_cannot_substitute_author_recorded_api_fixture(self) -> None:
        with self.assertRaisesRegex(identity.IdentityError, "author is not authorized"):
            identity.check_identity("different-author", "web-flow", {"verified": True, "reason": "valid"}, ROOT_POLICY)

    def test_unverified_commit_recorded_api_fixture_fails(self) -> None:
        with self.assertRaisesRegex(identity.IdentityError, "signature is not verified"):
            identity.check_identity("ac-slay3r", "web-flow", {"verified": False, "reason": "unsigned"}, ROOT_POLICY)

    def test_github_outage_fails_closed(self) -> None:
        with mock.patch("urllib.request.urlopen", side_effect=OSError("offline")):
            with self.assertRaisesRegex(identity.IdentityError, "could not be verified"):
                identity.github_identity(MERGE, ROOT_POLICY)


if __name__ == "__main__":
    unittest.main()
