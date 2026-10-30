#!/usr/bin/env python3
"""Create/reuse an owned local distribution identity; no key/password enters Git or argv."""
import os, pathlib, secrets, subprocess
root = pathlib.Path.home() / 'Library/Application Support/DroidBridge/AndroidSigning'
root.mkdir(mode=0o700, parents=True, exist_ok=True)
config = root / 'signing.properties'
if not config.exists():
    password = secrets.token_hex(32)
    passfile = root / 'password.tmp'
    with os.fdopen(os.open(passfile, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600), 'w') as handle:
        handle.write(password)
    try:
        keystore = root / 'release.jks'
        subprocess.run(['keytool', '-genkeypair', '-keystore', str(keystore), '-storepass:file', str(passfile),
                        '-keypass:file', str(passfile), '-alias', 'droidbridge-local-release', '-keyalg', 'RSA',
                        '-keysize', '3072', '-validity', '3650', '-dname', 'CN=DroidBridge Local Distribution'], check=True)
        keystore.chmod(0o600)
        with os.fdopen(os.open(config, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600), 'w') as handle:
            handle.write(f'store_file={keystore}\nstore_password={password}\nkey_alias=droidbridge-local-release\nkey_password={password}\n')
    finally:
        passfile.unlink(missing_ok=True)
print(config)
