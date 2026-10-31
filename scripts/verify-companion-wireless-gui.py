#!/usr/bin/env python3
"""Installed native Pair/Connect against real Android adbd TLS, owned emulator only.

Requires exclusive GUI/device handoff and a running verify-companion-installed
observer in the explicit private QA root. No code enters argv/stdout/evidence.
Emulator redirection makes its NAT TLS listener reachable; this is not a claim
of physical LAN coverage. Original wireless-debugging policy is restored.
"""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import re
import socket
import stat
import subprocess
import time


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--serial', choices=['emulator-5580', 'emulator-5582'], required=True)
    parser.add_argument('--adb', type=Path, required=True)
    parser.add_argument('--qa-root', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    root = args.qa_root.resolve(strict=True)
    info = root.stat()
    assert info.st_uid == os.getuid() and stat.S_IMODE(info.st_mode) == 0o700
    assert not args.output.exists(), 'Retain earlier attempts'
    args.output.mkdir(parents=True)
    spec = importlib.util.spec_from_file_location('installed_flow', Path(__file__).with_name('verify-companion-installed.py'))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    flow = module.InstalledFlow.__new__(module.InstalledFlow)
    flow.args, flow.root, flow.output = args, root, args.output
    flow.sequence = json.loads((root / 'receipt.json').read_text())['id']
    flow.process, flow.events = None, []
    redirections, aliases, observations = [], [], []
    original = flow.adb('shell', 'settings', 'get', 'global', 'adb_wifi_enabled').strip()
    assert original in ['0', '1'], 'Unknown wireless-debugging baseline'
    development_original = flow.adb('shell', 'settings', 'get', 'global', 'development_settings_enabled').strip()
    report = {'passed': False, 'serial': args.serial, 'wireless_baseline': original,
              'boundary': 'Actual installed native Pair/Connect controls -> real Android adbd TLS via emulator-owned NAT redirection',
              'physical_lan_verified': False, 'companion_alias_admission_verified_by_this_test': False}

    def tap(node):
        values = list(map(int, re.findall(r'\d+', node.get('bounds', ''))))
        assert len(values) == 4
        flow.adb('shell', 'input', 'tap', str((values[0] + values[2]) // 2), str((values[1] + values[3]) // 2))

    def phone(text, optional=False):
        for _ in range(8):
            for node in flow.nodes():
                if node.get('text', '').casefold() == text.casefold():
                    tap(node)
                    return True
            if optional:
                return False
            time.sleep(.15)
        raise RuntimeError('Missing Android control: ' + text)

    def enter_wireless():
        flow.adb('shell', 'am', 'start', '--display', '0', '-W', '-a', 'android.settings.APPLICATION_DEVELOPMENT_SETTINGS')
        flow.adb('shell', 'input', 'tap', '10', '400')
        for _ in range(14):
            nodes = flow.nodes()
            if any(n.get('text') == 'Use wireless debugging' for n in nodes):
                return
            node = next((n for n in nodes if n.get('text') == 'Wireless debugging'), None)
            if node is not None:
                tap(node)
                return
            flow.adb('shell', 'input', 'swipe', '640', '2200', '640', '900', '300')
        raise RuntimeError('Android Wireless debugging screen unavailable')

    def address():
        for _ in range(15):
            matches = [n.get('text') for n in flow.nodes() if re.fullmatch(r'10\.0\.2\.\d+:\d+', n.get('text', ''))]
            if matches:
                return matches[0]
            time.sleep(.2)
        raise RuntimeError('Real Android TLS listener address unavailable')

    def redirect(guest):
        for _ in range(4):
            with socket.socket() as reservation:
                reservation.bind(('127.0.0.1', 0))
                host = reservation.getsockname()[1]
            response = flow.adb('emu', 'redir', 'add', f'tcp:{host}:{guest}')
            if 'KO' not in response and 'OK' in response:
                redirections.append((host, guest))
                return f'127.0.0.1:{host}'
        raise RuntimeError('Could not reserve an emulator-owned redirection')

    def wait_result(expected, timeout=30):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            value = flow.action('status', window='Connect over Wi-Fi')
            texts = value.get('texts', [])
            if any(expected.casefold() in text.casefold() for text in texts):
                observations.append({'expected': expected, 'texts': texts})
                return value
            time.sleep(.1)
        raise RuntimeError('Native wireless operation did not confirm: ' + expected)

    def connect(endpoint):
        flow.action('set_field', window='Connect over Wi-Fi', label='Wireless ADB connection address', value=endpoint)
        flow.action('click', window='Connect over Wi-Fi', title='Connect')
        wait_result('connected to ' + endpoint)
        aliases.append(endpoint)
        check = subprocess.run([str(args.adb), '-s', endpoint, 'shell', 'getprop', 'ro.serialno'], check=True, capture_output=True, timeout=15).stdout
        assert check == flow.adb('shell', 'getprop', 'ro.serialno', binary=True), 'TLS endpoint was not the same owned emulator'

    try:
        if development_original != '1':
            flow.adb('shell', 'settings', 'put', 'global', 'development_settings_enabled', '1')
        enter_wireless()
        if original == '0':
            phone('Use wireless debugging')
            phone('ALLOW', optional=True)
        first = address()
        phone('Pair device with pairing code')
        text = '\n'.join(n.get('text', '') for n in flow.nodes())
        secret = re.search(r'(?m)^\d{6}$', text)
        pair_address = re.search(r'10\.0\.2\.\d+:(\d+)', text)
        assert secret and pair_address, 'Pairing code/listener unavailable'
        pairing = redirect(int(pair_address.group(1)))
        connection = redirect(int(first.rsplit(':', 1)[1]))
        flow.action('click', label='Companion section Connection')
        flow.action('click', title='Set Up Wi-Fi ADB…')
        flow.action('set_field', window='Connect over Wi-Fi', label='Wireless ADB pairing address', value=pairing)
        flow.action('set_field', window='Connect over Wi-Fi', label='Wireless ADB pairing code', value=secret.group())
        secret, text = None, None
        flow.action('click', window='Connect over Wi-Fi', title='Pair')
        wait_result('Successfully paired')
        connect(connection)
        if not any(n.get('text') == 'Use wireless debugging' for n in flow.nodes()):
            enter_wireless()
        phone('Use wireless debugging')
        phone('Use wireless debugging')
        phone('ALLOW', optional=True)
        changed = address()
        assert changed != first, 'Android did not issue a changed TLS endpoint; do not substitute a mock'
        next_connection = redirect(int(changed.rsplit(':', 1)[1]))
        connect(next_connection)
        report.update(passed=True, native_pair_succeeded=True, native_connect_succeeded=True,
                      changed_android_endpoint=True, native_connect_changed_endpoint_succeeded=True,
                      same_owned_emulator_verified=True, pairing_code_logged=False,
                      observations=observations, actions=flow.events)
    except Exception as error:
        report['error'] = str(error)
    finally:
        cleanup = []
        for alias in aliases:
            result = subprocess.run([str(args.adb), 'disconnect', alias], capture_output=True, timeout=15)
            cleanup.append({'operation': 'disconnect_exact_alias', 'alias': alias, 'exit': result.returncode})
        for host, guest in reversed(redirections):
            result = flow.adb('emu', 'redir', 'del', f'tcp:{host}')
            cleanup.append({'operation': 'delete_exact_owned_redirection', 'host_port': host, 'guest_port': guest, 'ok': 'KO' not in result})
        if flow.adb('shell', 'settings', 'get', 'global', 'adb_wifi_enabled').strip() != original:
            enter_wireless()
            phone('Use wireless debugging')
        report['wireless_restored'] = flow.adb('shell', 'settings', 'get', 'global', 'adb_wifi_enabled').strip() == original
        if development_original == 'null':
            flow.adb('shell', 'settings', 'delete', 'global', 'development_settings_enabled')
        else:
            flow.adb('shell', 'settings', 'put', 'global', 'development_settings_enabled', development_original)
        report['development_settings_baseline'] = development_original
        report['development_settings_restored'] = flow.adb('shell', 'settings', 'get', 'global', 'development_settings_enabled').strip() == development_original
        report['cleanup'] = cleanup
        try:
            pending = json.loads((root / 'command.json').read_text())
            if pending.get('label') == 'Wireless ADB pairing code':
                (root / 'command.json').unlink()
        except (FileNotFoundError, json.JSONDecodeError):
            pass
        report['passed'] = report['passed'] and report['wireless_restored'] and all(x.get('ok', True) and x.get('exit', 0) == 0 for x in cleanup)
        (args.output / 'result.json').write_text(json.dumps(report, indent=2))
    print(json.dumps({key: report.get(key) for key in ['passed', 'wireless_baseline', 'wireless_restored', 'error']}))
    if not report['passed']:
        raise SystemExit(1)


if __name__ == '__main__':
    main()
