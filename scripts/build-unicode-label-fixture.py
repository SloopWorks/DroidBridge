#!/usr/bin/env python3
"""Build original permission-free Unicode catalog APKs. Performs no ADB/device operations."""
from pathlib import Path
import hashlib
import json
import os
import subprocess
import zipfile

ROOT = Path(__file__).resolve().parents[1]
SDK = Path(os.environ.get('ANDROID_HOME', str(Path.home()/'Library/Android/sdk')))
JDK = Path(os.environ.get('DROIDBRIDGE_JAVA_HOME', '/opt/homebrew/opt/openjdk@21/libexec/openjdk.jdk/Contents/Home'))
BT = SDK/'build-tools/35.0.0'
PLATFORM = SDK/'platforms/android-35/android.jar'
OUT = ROOT/'.build/unicode-label-fixture'
SOURCE = ROOT/'android/unicode-label-fixture'

def run(*argv):
    env = os.environ.copy(); env['JAVA_HOME'] = str(JDK)
    subprocess.run([str(a) for a in argv], env=env, check=True, capture_output=True)

def main():
    OUT.mkdir(parents=True, exist_ok=True)
    key = OUT/'debug.jks'
    if not key.exists():
        run(JDK/'bin/keytool', '-genkeypair', '-keystore', key, '-storepass', 'android', '-keypass', 'android', '-alias', 'androiddebugkey', '-dname', 'CN=DroidBridge Unicode Catalog Verification', '-keyalg', 'RSA', '-validity', '3650')
    variants = [
        ('UnicodeCJK-v1', 'dev.droidbridge.unicodefixture.cjk', '界' * 86, 'CJK', '1', '30,100,210', '#1E64D2', 'M12,12L52,12L52,52L12,52Z'),
        ('UnicodeSupplementary-v1', 'dev.droidbridge.unicodefixture.supplementary', 'a' * 255 + '😀', 'Supplementary', '1', '20,150,70', '#149646', 'M32,8L58,54L6,54Z'),
    ]
    results = []
    for name, package, label, short, version, rgb, color, shape in variants:
        target = OUT/name
        for folder in ['classes', 'dex', 'res/drawable']: (target/folder).mkdir(parents=True, exist_ok=True)
        substitutions = {'__PACKAGE__': package, '__LABEL__': label, '__SHORT__': short, '__VERSION__': version, '__RGB__': rgb}
        for original, output in [('MainActivity.java.in', 'MainActivity.java'), ('AndroidManifest.xml.in', 'AndroidManifest.xml')]:
            value = (SOURCE/original).read_text()
            for placeholder, replacement in substitutions.items(): value = value.replace(placeholder, replacement)
            (target/output).write_text(value)
        (target/'res/drawable/fixture_icon.xml').write_text('<vector xmlns:android="http://schemas.android.com/apk/res/android" android:width="64dp" android:height="64dp" android:viewportWidth="64" android:viewportHeight="64"><path android:fillColor="#FFFFFF" android:pathData="M0,0L64,0L64,64L0,64Z"/><path android:fillColor="'+color+'" android:pathData="'+shape+'"/></vector>')
        run(BT/'aapt2', 'compile', '--dir', target/'res', '-o', target/'resources.zip')
        run(BT/'aapt2', 'link', '-o', target/'unsigned.apk', '--manifest', target/'AndroidManifest.xml', '-I', PLATFORM, target/'resources.zip')
        run(JDK/'bin/javac', '-source', '8', '-target', '8', '-encoding', 'UTF-8', '-classpath', PLATFORM, '-d', target/'classes', target/'MainActivity.java')
        run(BT/'d8', '--lib', PLATFORM, '--min-api', '33', '--output', target/'dex', *sorted((target/'classes').rglob('*.class')))
        with zipfile.ZipFile(target/'unsigned.apk', 'a', compression=zipfile.ZIP_DEFLATED) as archive: archive.write(target/'dex/classes.dex', 'classes.dex')
        apk = OUT/(name+'.apk')
        run(BT/'apksigner', 'sign', '--ks', key, '--ks-pass', 'pass:android', '--out', apk, target/'unsigned.apk')
        run(BT/'apksigner', 'verify', '--verbose', apk)
        results.append({'name': name, 'package': package, 'label': label, 'label_scalars': len(label), 'label_utf16_units': len(label.encode('utf-16-le')) // 2, 'label_utf8_bytes': len(label.encode('utf-8')), 'version_code': int(version), 'bytes': apk.stat().st_size, 'sha256': hashlib.sha256(apk.read_bytes()).hexdigest()})
    (OUT/'manifest.json').write_text(json.dumps(results, indent=2))
    print(json.dumps(results, indent=2))

if __name__ == '__main__': main()
