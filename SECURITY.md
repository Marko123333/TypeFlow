# Security and privacy

TypeFlow requires macOS Input Monitoring and Accessibility because it
observes keyboard events and replaces text in the focused application.

The application:

- processes input locally;
- does not send typed text to a server;
- does not include telemetry;
- pauses while macOS Secure Input is active;
- permanently excludes supported password managers;
- does not write typed words to its debug log;
- ignores its own synthesized keyboard events;
- accepts updates only from a project-owned cryptographically signed feed;
- verifies the DMG hash, exact application certificate, bundle identifier, and
  version before replacing the installed application;
- creates a verified rollback copy before every in-place update.

The current direct-download releases use a pinned self-signed project
certificate because the project does not yet have an Apple Developer Program
membership. This protects update authenticity but does not provide Apple
notarization or remove the Gatekeeper warning shown on first installation.
Details and the release checklist are in `docs/UPDATE_SECURITY.md`.

Do not include passwords, tokens, personal text, or raw keystroke logs in bug
reports. Security issues should be reported privately to the repository owner
until a dedicated security contact is configured.
