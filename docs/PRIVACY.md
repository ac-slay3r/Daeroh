# Daeroh privacy — development build

Daeroh is a private, unreleased Android downstream of Hermes Console. It does **not** use XPeta Lab's privacy policy as its own; [the upstream policy](PRIVACY_POLICY.md) describes the upstream app and developer, not Daeroh.

Current source sends conversation content and attachments to the Hermes server you configure; optional speech/model/catalog services can contact their selected providers. Connection credentials use Android secure storage. The inherited code includes microphone, camera, notifications, local files, and network features. Transport to DNS names requires HTTPS/WSS; cleartext is limited to literal private IP destinations.

No Daeroh-operated telemetry or account service has been added. This statement is not a published release privacy policy; behavior and permissions still require on-device verification before any public distribution. Do not assume the upstream developer receives, supports, or maintains this downstream's data or releases.
