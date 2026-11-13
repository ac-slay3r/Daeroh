# One-time pairing code design note

The current `hermes://pair` contract carries a long-lived Gateway token and remains supported for compatibility. A safer replacement requires a Hermes Platform-owned endpoint; Daeroh must not emulate it locally.

## Proposed protocol

1. An authenticated local Hermes CLI command asks the server for a one-time pairing code bound to a selected literal tailnet/private host, Gateway port, and optional Bridge capability. The server records only a hash of the random code, a 5-minute expiry, single-use state, and a narrow audience.
2. The CLI renders a QR containing `hermes://pair?host=...&port=...&code=...` rather than any reusable API or Bridge token. It never prints the URI except on a TTY with an explicit show flag.
3. After scan, Daeroh sends the code only over the selected approved transport to a new Hermes endpoint. The endpoint atomically consumes it, returns a scoped pairing credential, and rejects replay, expiry, host/port mismatch, and unauthorized origin.
4. Daeroh stores the resulting credential only in Android Keystore. The server endpoint rate-limits attempts, redacts codes from all logs, and returns body-free error categories.

## Hermes Platform work required

This needs a versioned public Hermes CLI command and authenticated server endpoint with atomic redemption and test coverage. It is deliberately not implemented in this repository.
