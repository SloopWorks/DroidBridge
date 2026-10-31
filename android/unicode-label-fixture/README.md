# Unicode catalog fixtures

Original permission-free Android applications used only for catalog boundary QA.
Build with `python3 scripts/build-unicode-label-fixture.py`; the command performs
no ADB/device operations. Output APKs and source/label metadata are in
`.build/unicode-label-fixture/`.

- `dev.droidbridge.unicodefixture.cjk`:86 CJK Unicode scalars,258 UTF8 bytes.
- `dev.droidbridge.unicodefixture.supplementary`:255 ASCII scalars followed by
  one supplementary emoji,256 scalars /257 UTF16 units /259 UTF8 bytes. The old
  UTF16 truncation split the final surrogate pair.

Both have an original vector launcher icon and a simple native Activity displaying
the public synthetic label/scalar count. No permissions, services, network,
clipboard access or input logging. Install only in an explicitly owned QA scope;
remove these two exact disposable packages after verification. They never replace
Alpha, Beta or the companion, and are never bundled into DroidBridge.
