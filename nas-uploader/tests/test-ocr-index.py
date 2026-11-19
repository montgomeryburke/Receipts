#!/usr/bin/env python3
# Checks server/assistant-ocr-index.py on a throwaway shared folder: symlinks never lead it outside the folder,
# Word headers/footers and Excel inline text are read, and an oversized ("zip bomb") part is skipped.
# Needs pdftotext, pdftoppm and tesseract installed (the script refuses to run without them).
#   python3 -I tests/test-ocr-index.py
import gzip
import json
import os
import subprocess
import sys
import tempfile
import zipfile

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPT = os.path.join(HERE, '..', 'server', 'assistant-ocr-index.py')
failures = 0


def check(name, ok):
    global failures
    print(f"  {'✔' if ok else '✘'} {name}")
    failures += 0 if ok else 1


def docx(path, body, header):
    with zipfile.ZipFile(path, 'w') as z:
        z.writestr('[Content_Types].xml', '<Types/>')
        z.writestr('word/document.xml', f'<w:document><w:body><w:p><w:r><w:t>{body}</w:t></w:r></w:p></w:body></w:document>')
        z.writestr('word/header1.xml', f'<w:hdr><w:p><w:r><w:t>{header}</w:t></w:r></w:p></w:hdr>')


def xlsx(path):
    with zipfile.ZipFile(path, 'w') as z:
        z.writestr('xl/sharedStrings.xml', '<sst><si><t>Shared cell</t></si></sst>')
        z.writestr('xl/worksheets/sheet1.xml', '<worksheet><sheetData><row r="1"><c r="A1" t="s"><v>0</v></c><c r="B1"/><c r="C1" t="inlineStr"><is><t>Inline cell</t></is></c><c r="D1"><v>42</v></c></row></sheetData></worksheet>')


def bomb(path):
    # A part that claims to unpack to more than the limit: skipped, not read into memory.
    with zipfile.ZipFile(path, 'w', zipfile.ZIP_DEFLATED) as z:
        z.writestr('word/document.xml', '<w:document>' + 'A' * 70_000_000 + '</w:document>')


with tempfile.TemporaryDirectory() as work:
    root = os.path.join(work, 'share')
    outside = os.path.join(work, 'outside')
    os.makedirs(os.path.join(root, 'Docs'))
    os.makedirs(os.path.join(root, '.assistant'))
    os.makedirs(outside)
    with open(os.path.join(outside, 'secret.txt'), 'w') as f:
        f.write('TOP SECRET outside the share')
    with open(os.path.join(root, 'Docs', 'notes.txt'), 'w') as f:
        f.write('Pour date notes inside the share')
    os.symlink(os.path.join(outside, 'secret.txt'), os.path.join(root, 'Docs', 'linked-secret.txt'))  # a file link
    os.symlink(outside, os.path.join(root, 'Link'))  # a folder link, listed as a project folder below
    docx(os.path.join(root, 'Docs', 'spec.docx'), 'Body text', 'Drawing S-101 header')
    xlsx(os.path.join(root, 'Docs', 'quantities.xlsx'))
    bomb(os.path.join(root, 'Docs', 'bomb.docx'))
    with open(os.path.join(root, '.assistant', 'project-folders.json'), 'w') as f:
        json.dump({'folders': ['Link', '../outside'], 'nasOnly': ['Docs', 'Link']}, f)
    r = subprocess.run([sys.executable, '-I', SCRIPT, root], capture_output=True, text=True, timeout=600)
    print('• OCR / full-text index on a throwaway shared folder')
    check('script succeeded', r.returncode == 0)
    if r.returncode:
        print(r.stdout[-2000:], r.stderr[-2000:])
    index = os.path.join(root, '.assistant', 'deep-index.jsonl.gz')
    text = ''
    if os.path.exists(index):
        with gzip.open(index, 'rt', encoding='utf-8') as f:
            text = f.read()
    check('reads files inside the share', 'Pour date notes inside the share' in text)
    check('never follows a symlinked file outside the share', 'TOP SECRET' not in text)
    check('a symlinked or ../ project folder outside the share is ignored', 'outside the share' not in text.replace('inside the share', ''))
    check('Word headers are read', 'Drawing S-101 header' in text)
    check('Excel shared and inline cells are read', 'Shared cell' in text and 'Inline cell' in text and '42' in text)
    check('an oversized part is skipped, the run goes on', 'too large unpacked' in (r.stdout + r.stderr) and 'Pour date notes' in text)
    check('no temp file left next to the index', not [n for n in os.listdir(os.path.join(root, '.assistant')) if n.endswith('.tmp')])

print('ocr index: all checks passed' if not failures else f'ocr index: {failures} check(s) failed')
sys.exit(1 if failures else 0)
