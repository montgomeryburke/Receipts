#!/usr/bin/env python3
# Project Assistant — the HP command endpoint (<NAS address>/.run), installed by setup-webdav.sh --enable-commands.
# Apache has already checked the NAS login; this also needs the separate command key (X-Command-Key header), so the
# NAS password alone can't run commands. The command runs as the limited "nas-runner" user through sudo, with a
# time limit, one at a time, and is written to the log.
import fcntl
import hmac
import json
import os
import subprocess
import sys
import time

KEY_FILE = os.environ.get('NAS_COMMAND_KEY_FILE', '/etc/nas-uploader-command-key')
LOG_FILE = os.environ.get('NAS_COMMAND_LOG', '/var/log/nas-uploader-commands.log')
LOCK_FILE = os.environ.get('NAS_COMMAND_LOCK', '/run/lock/nas-uploader-command.lock')
RUN_COMMAND = os.environ.get('NAS_RUN_COMMAND', '/usr/local/lib/nas-uploader/run-command')
# Tests run the runner directly (no sudo); on the NAS it always goes through sudo as nas-runner.
RUNNER = [sys.executable, RUN_COMMAND] if os.environ.get('NAS_RUNNER_DIRECT') == '1' else ['sudo', '-n', '-u', 'nas-runner', RUN_COMMAND]


def reply(status, data):
    body = json.dumps(data).encode()
    sys.stdout.write(f'Status: {status}\r\nContent-Type: application/json\r\nCache-Control: no-store\r\nContent-Length: {len(body)}\r\n\r\n')
    sys.stdout.flush()
    sys.stdout.buffer.write(body)
    sys.stdout.flush()


def log(entry):
    try:
        with open(LOG_FILE, 'a', encoding='utf-8') as f:
            f.write(json.dumps(entry) + '\n')
    except OSError:
        pass


def main():
    if os.environ.get('REQUEST_METHOD') != 'POST':
        return reply('405 Method Not Allowed', {'error': 'POST only'})
    try:
        with open(KEY_FILE, encoding='utf-8') as f:
            key = f.read().strip()
    except OSError:
        return reply('503 Service Unavailable', {'error': 'commands are not switched on (setup-webdav.sh --enable-commands)'})
    given = os.environ.get('HTTP_X_COMMAND_KEY', '')
    who = os.environ.get('REMOTE_USER', '')
    ip = os.environ.get('HTTP_X_FORWARDED_FOR') or os.environ.get('REMOTE_ADDR', '')
    if not key or not hmac.compare_digest(given.encode(), key.encode()):
        log({'at': time.strftime('%Y-%m-%dT%H:%M:%S'), 'user': who, 'ip': ip, 'refused': 'wrong command key'})
        return reply('403 Forbidden', {'error': 'wrong command key'})
    try:
        length = min(int(os.environ.get('CONTENT_LENGTH') or 0), 65536)
    except ValueError:
        length = 0
    raw = sys.stdin.buffer.read(length) if length else b''
    try:
        req = json.loads(raw or b'{}')
    except ValueError:
        return reply('400 Bad Request', {'error': 'bad JSON'})
    cmd = str(req.get('cmd') or '')
    if not cmd.strip():
        return reply('400 Bad Request', {'error': 'no command'})
    home = os.path.realpath(os.environ.get('NAS_RUNNER_HOME', '') or '/')
    cwd = os.path.realpath(str(req.get('cwd') or home))
    if not (cwd == home or cwd.startswith(home.rstrip('/') + '/')):
        return reply('400 Bad Request', {'error': f'the folder must be inside the shared folder ({home})'})
    os.makedirs(os.path.dirname(LOCK_FILE), exist_ok=True)
    with open(LOCK_FILE, 'w') as lock:
        # One command at a time; wait up to 10 s for the one before.
        for _ in range(100):
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                break
            except OSError:
                time.sleep(0.1)
        else:
            return reply('409 Conflict', {'error': 'another command is still running'})
        t0 = time.time()
        try:
            p = subprocess.run(RUNNER, input=json.dumps({'cmd': cmd, 'cwd': cwd, 'timeout': req.get('timeout') or 60}).encode(), capture_output=True, timeout=660)
            out = json.loads(p.stdout or b'{}') if p.returncode == 0 else {'error': (p.stderr or b'').decode('utf-8', 'replace')[-2000:] or f'runner failed ({p.returncode})'}
        except (subprocess.TimeoutExpired, ValueError) as e:
            out = {'error': f'runner failed: {e}'}
    log({'at': time.strftime('%Y-%m-%dT%H:%M:%S', time.localtime(t0)), 'user': who, 'ip': ip, 'cmd': cmd[:2000], 'cwd': cwd, 'exit': out.get('exit'), 'ms': out.get('ms'), 'error': out.get('error')})
    return reply('200 OK' if 'error' not in out else '500 Internal Server Error', out)


if __name__ == '__main__':
    main()
