# Original desktop input verification applications

These test-only APKs provide two independent packages, readable editable echoes,
tap/key counters, explicit clipboard sentinels and an optional 60 Hz changing
view. Their normal IME behavior stays enabled so the host must enforce its
virtual-display keyboard policy. Activity recreation preserves text and counters.
They request no permissions, collect no data and have no network client.

Build with `python3 scripts/build-desktop-input-fixture.py`. This builds only;
installation requires an explicit handoff of the owned emulator. Outputs under
`.build/desktop-input-fixture/` include:

- `InputAlpha-v1.apk`: `dev.droidbridge.inputalpha`, blue icon.
- `InputAlpha-v2.apk`: same package/signature, changed label and green icon for
  real catalog-delta and wrapper-update checks.
- `InputBeta-v1.apk`: `dev.droidbridge.inputbeta`, red icon.

Use actual Mac window activation and typing to enter different strings into
Alpha and Beta, then inspect each visible echo and tap count. Repeat after
resizing and on both rendering backends. Clicking Copy or Read is required for
each clipboard operation. The motion source counts Android frames; it alone
does not prove the Mac decoder's rate or an encoder ceiling.

Never distribute these fixtures as part of the product. Their local debug key is
only a disposable verification identity. The source and artwork are original.
