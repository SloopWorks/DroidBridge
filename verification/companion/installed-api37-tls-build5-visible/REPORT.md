# Installed build 5 checkpoint — rejected

The actual installed application was `/Users/patrick/Applications/DroidBridge Companion QA5.app`, copied from the read-only installer by the release coordinator. Host SHA-256: `8fba9ef67ffdccf170e211761f92ff4137e5dbf41f2166363a7bf64a2819dc5b`; broker SHA-256: `de0d13759075af09ba4832e3ca10ed4258725411b400cf2e4fa94472a7a164ad`. Only owned emulator-5582 and the explicit private QA data scope were used.

Actual GUI installation/update and Android opening succeeded. After the ad-hoc executable update, connecting with the prior Keychain record failed promptly with `credential_unavailable`. The native local Forget action and confirmation retained existing app exports and settings. The old selected phone trust was revoked through its Settings confirmation; the separate older QA trust was preserved.

Fresh pinned-URI pairing displayed matching comparison codes and Android Trust Mac was clicked. The Mac subsequently rejected polling with “The phone returned a different pairing request.” Android's `pollPair` response omitted `pairing_id` in both pending and approved responses; the new Core guard correctly refused the absent identity. This milestone fails. The newly created orphan trust was removed explicitly through phone Settings. Core certificate/identity checks were not weakened, and no prior credential was restored.

The exact retained nonempty selection is recorded before and after Forget. Both Alpha and Beta remain selected. Successful authenticated re-pair retention is still untested at this checkpoint.

The installed Alerts page's read-only permission check reported Mac notifications “Not requested”; this action did not request or modify authorization. Android notification access remains ungranted. Further authenticated flows await a corrected Android release and freshly installed Mac artifact.

No live native sessions or audio processes were created by this checkpoint. Pairing screenshots/URIs and credentials are excluded from publishable evidence. See `pairing-poll-schema-failure.json`, `post-forget-retention.json`, and `mac-notification-baseline.json`.
