# Daeroh

Daeroh is AC's independent Android client for [Hermes Agent](https://github.com/NousResearch/hermes-agent), maintained as a **private, standalone downstream** of [XPeta Lab's Hermes Console](https://github.com/xP3ta/hermes-console). It is not affiliated with XPeta Lab or Nous Research. The original Git history, tags, GPL-3.0-only license, notices, and [upstream README](docs/UPSTREAM_README.md) are retained.

**Status:** development build, not published. The Android package ID is `cool.n0thing.daeroh`; updates must be signed with Daeroh's own signing key. An inherited upstream installer or release workflow must not be used for Daeroh without review.

The first downstream changes guard app-lock pairing links and restrict cleartext transport to literal private IP addresses, with redirect protection. See [DOWNSTREAM.md](DOWNSTREAM.md) for maintenance boundaries and upstream-sync policy.

This source is licensed under [GPL-3.0-only](LICENSE). Before distributing binaries, provide corresponding source and preserve copyright and license notices.
