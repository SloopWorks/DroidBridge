# Pinned scrcpy hover policy review

Read-only review by Android expert. Installed scrcpy reports5.0.1; its actual --help documents --no-mouse-hover as suppressing buttonless motion. Pinned Vendor/scrcpy/doc/mouse.md documents the SDK mouse option; app/src/mouse_sdk.c63 returns only when hover is disabled AND buttons_state is0. Pressed-button motion/drag remains, while clicks and scroll use their existing paths.

Root's API35 evidence and installed API37 fallback-no-hover-diagnostic.json show the same virtual-display input symptom across versions; the API37 diagnostic with this single additional flag recorded taps1. Native already emits no hover. Universal --no-mouse-hover for DroidBridge's pinned SDK mouse backend is therefore a defensible reliability policy. It removes hover-only tooltips/rollovers, which must be documented. It does not require Android root, system settings changes or a weakened input path. Root owns implementation and actual final installed mouse acceptance; this source/evidence review alone does not pass the final artifact.

Version-specific assertions in scripts/verify-hidden-ime-fallback.py and scripts/verify-audio-fallback.py need to match the universal policy alongside production/unit tests. No Mac/Streaming source was edited by this agent.
