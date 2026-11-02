#!/usr/bin/env python3
"""Capture English fictional scenes on a synthetic backdrop; this uses the visible display."""
import os
import json
import subprocess
import time
import signal
import importlib.util
from pathlib import Path
root = Path(__file__).resolve().parents[2]
import sys
spec = importlib.util.spec_from_file_location('media', root / 'scripts/media/media.py')
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
work = root / 'build/media-refresh/english'
work.mkdir(parents=True, exist_ok=True)
shots = [s for s in m.SHOTS if s['language'] == 'en' and (len(sys.argv) == 1 or s['file'] in sys.argv[1:])]
for source, target in [('geometry.swift', 'geometry'), ('backdrop.swift', 'background')]:
    subprocess.run(['swiftc', str(root / 'scripts/media' / source), '-o', str(m.WORK / target)], check=True)
m.check()
clip = json.loads(subprocess.check_output([str(m.WORK / 'geometry')]))
manifest = []
bg = subprocess.Popen([str(m.WORK / 'background')], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
try:
    for i, shot in enumerate(shots):
        if bg.poll() is None:
            bg.terminate()
            bg.wait(timeout=8)
        bg = subprocess.Popen([str(m.WORK / 'background')] + [Path(shot['file']).stem.removeprefix('bg-') if Path(shot['file']).stem.startswith('bg-') else shot['theme']], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        time.sleep(0.15)
        folder = work / Path(shot['file']).stem
        folder.mkdir(exist_ok=True)
        env = {k: v for k, v in os.environ.items() if not k.startswith('AGENT_FLOAT_')}
        env.update(m.environment(shot))
        env['AGENT_FLOAT_OPEN_REPLY_NO_KEY'] = '1'
        env['AGENT_FLOAT_FAKE_REPLY_STAGE_DELAY'] = '0.25'
        is_reply = shot['scene'] in ['choice', 'multi', 'body', 'permission']
        if is_reply:
            env['AGENT_FLOAT_OPEN_REPLY'] = '0'
            env['AGENT_FLOAT_OPEN_REPLY_SESSION'] = 'fake-media-target'
            if shot['scene'] != 'permission':
                env['AGENT_FLOAT_OPEN_REPLY_SEND'] = '1'
                env['AGENT_FLOAT_OPEN_REPLY_SEND_DELAY'] = '2.0'
            if shot['scene'] == 'multi':
                env['AGENT_FLOAT_OPEN_REPLY_STEPS'] = '0;1'
            elif shot['scene'] == 'body':
                env['AGENT_FLOAT_OPEN_REPLY_TEXT'] = 'Yes, move it to server configuration.'
            elif shot['scene'] == 'choice':
                env['AGENT_FLOAT_OPEN_REPLY_SELECT'] = '0'
        log = open(folder / 'app.log', 'w')
        p = subprocess.Popen([str(m.EXECUTABLE)], env=env, stdout=log, stderr=log)
        (work / 'current.json').write_text(json.dumps({'pid': p.pid, 'shot': shot['file']}))
        try:
            deadline = time.monotonic() + 25
            while 'refresh sessions=' not in (folder / 'app.log').read_text():
                if p.poll() is not None:
                    raise RuntimeError(f'app exited: {p.returncode}')
                if time.monotonic() > deadline:
                    raise RuntimeError('app startup timeout')
                time.sleep(0.15)
            time.sleep(0.25)
            if shot['scene'] in ['mixed', 'choice', 'multi', 'body', 'permission']:
                os.kill(p.pid, signal.SIGUSR1)
            time.sleep(1.8)
            windows = json.loads(subprocess.check_output([str(m.WORK / 'geometry'), str(p.pid)]))
            windows = [w for w in windows if w.get('kCGWindowLayer') == 3 and w['kCGWindowBounds']['Height'] >= 28]
            if not windows:
                raise RuntimeError('no panel')
            bounds = [w['kCGWindowBounds'] for w in windows]
            x = min((b['X'] for b in bounds)) - 20
            y = min((b['Y'] for b in bounds)) - 20
            right = max((b['X'] + b['Width'] for b in bounds)) + 20
            bottom = max((b['Y'] + b['Height'] for b in bounds)) + 20
            width = int(right - x)
            height = int(bottom - y)
            if width / height < shot['size'][0] / shot['size'][1]:
                width = int(height * shot['size'][0] / shot['size'][1])
            else:
                height = int(width * shot['size'][1] / shot['size'][0])
            x = right - width
            x = min(x, clip['x'] + clip['width'] - width - 20)
            y = min(y, clip['y'] + clip['height'] - height - 20)
            if not (clip['x'] <= x and x + width <= clip['x'] + clip['width'] and (clip['y'] <= y) and (y + height <= clip['y'] + clip['height'])):
                raise RuntimeError(f'outside synthetic backdrop {(x, y, width, height)}')
            if shot['scene'] == 'mixed':
                os.kill(p.pid, signal.SIGUSR2)
                time.sleep(0.7)
            for frame in range(3):
                path = folder / f'{frame:02}.png'
                subprocess.run([str(m.WORK / 'geometry'), str(p.pid)], stdout=subprocess.DEVNULL, check=True)
                subprocess.run(['/usr/sbin/screencapture', '-x', f'-R{int(x)},{int(y)},{width},{height}', str(path)], check=True)
                try:
                    subprocess.run([str(m.WORK / 'geometry'), str(p.pid)], stdout=subprocess.DEVNULL, check=True)
                except subprocess.CalledProcessError:
                    path.unlink(missing_ok=True)
                    raise
                if frame == 0 and shot['scene'] == 'mixed':
                    os.kill(p.pid, signal.SIGUSR1)
                    time.sleep(0.25)
                elif frame == 1 and shot['scene'] == 'mixed':
                    time.sleep(0.7)
                elif frame == 0 and shot['scene'] == 'new':
                    time.sleep(10)
                elif frame == 0 and is_reply and (shot['scene'] != 'permission'):
                    time.sleep(1.3)
                elif frame == 1 and is_reply and (shot['scene'] != 'permission'):
                    time.sleep(1.5)
                else:
                    time.sleep(0.25)
            out = root / 'docs/media' / shot['file']
            out.parent.mkdir(parents=True, exist_ok=True)
            subprocess.run(['ffmpeg', '-hide_banner', '-loglevel', 'error', '-y', '-framerate', '2', '-i', str(folder / '%02d.png'), '-vf', f"scale={shot['size'][0]}:{shot['size'][1]}:flags=lanczos,split[a][b];[a]palettegen[p];[b][p]paletteuse", '-loop', '0', str(out)], check=True)
            manifest.append({'file': shot['file'], 'language': 'en', 'scene': shot['scene'], 'agent': shot['agent'], 'synthetic_background': True, 'fake_sessions': True, 'frames': 3, 'size': shot['size']})
            print(f"{i + 1}/{len(shots)} {shot['file']}", flush=True)
        finally:
            if p.poll() is None:
                p.terminate()
                p.wait(timeout=8)
            log.close()
finally:
    if bg.poll() is None:
        bg.terminate()
        bg.wait(timeout=8)
    (work / ('manifest-' + str(int(time.time())) + '.json')).write_text(json.dumps(manifest, indent=2) + '\n')
