#!/usr/bin/env python3
"""Builds the OCR ("deep") index for Project Assistant on the NAS: scanned PDFs, photos and email archives.

The extension indexes project files on the user's computer, but it can't read scanned PDFs or photos of
documents — they have no text layer. This script runs on the HP (or a Pi), next to the mirrored files, and
OCRs exactly those: PDFs whose pages have little or no text, and images. It writes
<root>/.assistant/deep-index.jsonl.gz, which the extension fetches over WebDAV and applies to the same files.
No AI service and no tokens are involved; it uses Tesseract and Poppler on the server.

It also unpacks Outlook mailboxes the extension can't open itself — .pst archives (with readpst) and saved .msg
emails (with msgconvert) — so project emails that never reach Outlook on the web become searchable too. Each email
becomes one "page" of its file, newest first: sender, date, subject, folder, attachment names and the text.

Only the project folders are read: the extension lists them in <root>/.assistant/project-folders.json
(so movies, posters and other files on the NAS are never touched). --folder adds folders by hand.

Each line: {"path": "Projects/x/y.pdf", "size": 123, "mtime": 1700000000000, "method": "ocr",
            "pages": [[1, "text of page 1"], [2, "…"]]}
Files whose size and modification time haven't changed are taken from the previous index (no repeat OCR).

Usage: assistant-ocr-index.py ROOT [--max-pages 300] [--max-minutes 0] [--owner www-data] [--lang eng]
"""
import argparse
import email
import email.policy
import email.utils
import gzip
import html
import re
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time

PDF = {'.pdf'}
IMAGES = {'.png', '.jpg', '.jpeg', '.tif', '.tiff', '.bmp', '.gif', '.webp'}
MAIL = {'.pst', '.msg'}
MAIL_CHARS_PER_EMAIL = 6000
SKIP_DIRS = {'.assistant', '.mailmirror', '@eadir', '#recycle', '.recycle', 'lost+found', '.snapshot', '.snapshots', 'metadata', '.trickplay'}
MIN_CHARS_PER_PAGE = 60  # below this a PDF page counts as scanned
OUT_REL = '.assistant/deep-index.jsonl.gz'


def log(*a):
    print(time.strftime('%Y-%m-%d %H:%M:%S'), *a, flush=True)


def run(cmd, timeout=300):
    r = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=timeout)
    if r.returncode != 0:
        raise RuntimeError(f"{cmd[0]} failed: {r.stderr.decode('utf-8', 'replace')[:200]}")
    return r.stdout.decode('utf-8', 'replace')


def pdf_pages_text(path, max_pages):
    """Text layer per page (pdftotext puts a form feed between pages)."""
    try:
        out = run(['pdftotext', '-q', '-l', str(max_pages), '-enc', 'UTF-8', path, '-'], timeout=600)
    except Exception:
        return []
    pages = out.split('\f')
    if pages and not pages[-1].strip():
        pages.pop()
    return pages


def ocr_image(path, lang):
    return run(['tesseract', path, '-', '-l', lang, '--psm', '3'], timeout=300).strip()


def ocr_pdf(path, pages_text, max_pages, lang, deadline):
    """OCR only the pages that have (almost) no text; keep the text layer of the others."""
    out = []
    tmp = tempfile.mkdtemp(prefix='ocr-')
    try:
        for i, t in enumerate(pages_text[:max_pages], start=1):
            if deadline and time.time() > deadline:
                break
            if len(t.strip()) >= MIN_CHARS_PER_PAGE:
                out.append([i, t.strip()])
                continue
            png = os.path.join(tmp, f'p{i}')
            run(['pdftoppm', '-r', '200', '-gray', '-png', '-f', str(i), '-l', str(i), '-singlefile', path, png], timeout=300)
            text = ocr_image(png + '.png', lang)
            os.unlink(png + '.png')
            if text:
                out.append([i, text])
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    return out


DATE_RE = re.compile(r'[A-Z][a-z]{2}, \d{1,2} [A-Z][a-z]{2} \d{4} \d{1,2}:\d{2}(:\d{2})? [+-]\d{4}')


def mail_date(value):
    for v in (value or '', *(m.group(0) for m in DATE_RE.finditer(value or ''))):
        try:
            d = email.utils.parsedate_to_datetime(v)
            if d:
                return d.timestamp()
        except Exception:
            continue
    return 0


def html_to_text(h):
    h = re.sub(r'(?is)<(script|style).*?</\1>', ' ', h)
    h = re.sub(r'(?i)<br\s*/?>|</p>|</div>|</tr>|</li>', '\n', h)
    return html.unescape(re.sub(r'<[^>]+>', ' ', h))


def eml_text(path, folder=''):
    """(timestamp, text) for one .eml file."""
    with open(path, 'rb') as f:
        msg = email.message_from_binary_file(f, policy=email.policy.default)
    body = ''
    try:
        part = msg.get_body(preferencelist=('plain', 'html'))
        if part is not None:
            body = part.get_content()
            if part.get_content_type() == 'text/html':
                body = html_to_text(body)
    except Exception:
        body = ''
    body = re.sub(r'[ \t]+', ' ', re.sub(r'\n{3,}', '\n\n', body or '')).strip()
    try:
        attachments = [a.get_filename() for a in msg.iter_attachments() if a.get_filename()]
    except Exception:
        attachments = []
    head = [f"Subject: {msg.get('subject', '') or '(no subject)'}", f"From: {msg.get('from', '')}"]
    if msg.get('to'):
        head.append(f"To: {str(msg.get('to'))[:300]}")
    if msg.get('cc'):
        head.append(f"Cc: {str(msg.get('cc'))[:300]}")
    head.append(f"Date: {msg.get('date', '')}")
    if folder:
        head.append(f'Folder: {folder}')
    if attachments:
        head.append('Attachments: ' + ', '.join(attachments[:20]))
    text = '\n'.join(head) + '\n\n' + body
    return mail_date(str(msg.get('date', ''))), text[:MAIL_CHARS_PER_EMAIL]


def mail_pages(path, ext, max_chars, deadline):
    """Unpacks a .pst or .msg into [[n, email text], ...], newest email first."""
    tmp = tempfile.mkdtemp(prefix='mail-')
    try:
        if ext == '.pst':
            run(['readpst', '-e', '-q', '-8', '-t', 'e', '-j', '0', '-o', tmp, path], timeout=7200)
        else:
            run(['msgconvert', '--outfile', os.path.join(tmp, 'message.eml'), path], timeout=300)
        mails = []
        for dirpath, _, files in os.walk(tmp):
            for name in files:
                if not name.lower().endswith('.eml'):
                    continue
                if deadline and time.time() > deadline:
                    break
                folder = os.path.relpath(dirpath, tmp).replace(os.sep, '/')
                try:
                    mails.append(eml_text(os.path.join(dirpath, name), '' if folder == '.' else folder))
                except Exception:
                    continue
        mails.sort(key=lambda m: -m[0])
        pages, used = [], 0
        for i, (_, text) in enumerate(mails, start=1):
            if used + len(text) > max_chars:
                break
            pages.append([i, text])
            used += len(text)
        return pages, len(mails)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def load_previous(out_path):
    prev = {}
    try:
        with gzip.open(out_path, 'rt', encoding='utf-8') as f:
            for line in f:
                try:
                    r = json.loads(line)
                    prev[r['path']] = r
                except Exception:
                    continue
    except FileNotFoundError:
        pass
    except Exception as e:
        log('previous index unreadable, rebuilding:', e)
    return prev


def walk(root):
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = sorted(d for d in dirnames if d.lower() not in SKIP_DIRS and not d.startswith('.'))
        for name in sorted(filenames):
            if name.startswith('.') or name.startswith('~$'):
                continue
            ext = os.path.splitext(name)[1].lower()
            if ext in PDF or ext in IMAGES or ext in MAIL:
                yield os.path.join(dirpath, name), ext


def main():
    ap = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    ap.add_argument('root')
    ap.add_argument('--max-pages', type=int, default=300)
    ap.add_argument('--max-minutes', type=float, default=0, help='stop after this long (0 = no limit); the rest is done next run')
    ap.add_argument('--owner', default='', help='chown the index to this user (the WebDAV server user)')
    ap.add_argument('--lang', default='eng', help='Tesseract language(s), e.g. eng+fra')
    ap.add_argument('--folder', action='append', default=[], help='a project folder (NAS path) to include; repeatable')
    ap.add_argument('--max-mail-chars', type=int, default=8_000_000, help='most text kept per mailbox (newest emails first)')
    a = ap.parse_args()
    root = os.path.abspath(a.root)
    out_path = os.path.join(root, OUT_REL)
    folders = list(a.folder)
    try:
        with open(os.path.join(root, '.assistant', 'project-folders.json'), encoding='utf-8') as f:
            folders += [x for x in json.load(f).get('folders', []) if isinstance(x, str)]
    except FileNotFoundError:
        pass
    except Exception as e:
        log('project-folders.json unreadable:', e)
    scan_dirs = []
    for x in dict.fromkeys(folders):
        d = os.path.abspath(os.path.join(root, x.strip('/')))
        if (d == root or d.startswith(root + os.sep)) and os.path.isdir(d):
            scan_dirs.append(d)
    if not scan_dirs:
        log('no project folders listed yet (the extension writes .assistant/project-folders.json after its first index run)')
    os.makedirs(os.path.dirname(out_path), exist_ok=True)
    for tool in ('pdftotext', 'pdftoppm', 'tesseract'):
        if not shutil.which(tool):
            log(f'{tool} is not installed (apt-get install poppler-utils tesseract-ocr)')
            return 2
    has_readpst = bool(shutil.which('readpst'))
    has_msgconvert = bool(shutil.which('msgconvert'))
    prev = load_previous(out_path)
    deadline = time.time() + a.max_minutes * 60 if a.max_minutes else 0
    records, reused, ocred, skipped, failed = [], 0, 0, 0, 0
    for path, ext in (item for d in scan_dirs for item in walk(d)):
        rel = os.path.relpath(path, root).replace(os.sep, '/')
        try:
            st = os.stat(path)
        except OSError:
            continue
        mtime = int(st.st_mtime * 1000)
        old = prev.get(rel)
        if old and old.get('size') == st.st_size and old.get('mtime') == mtime:
            records.append(old)
            reused += 1
            continue
        if deadline and time.time() > deadline:
            if old:
                records.append(old)  # stale but better than nothing until the next run
            continue
        try:
            method = 'ocr'
            if ext in MAIL:
                if (ext == '.pst' and not has_readpst) or (ext == '.msg' and not has_msgconvert):
                    skipped += 1
                    continue
                pages, total = mail_pages(path, ext, a.max_mail_chars, deadline)
                method = ext[1:]
                if pages:
                    log('mail', rel, f'{len(pages)} of {total} email(s)')
            elif ext in IMAGES:
                text = ocr_image(path, a.lang)
                pages = [[1, text]] if text else []
            else:
                pages_text = pdf_pages_text(path, a.max_pages)
                if not pages_text:
                    skipped += 1
                    continue
                if all(len(t.strip()) >= MIN_CHARS_PER_PAGE for t in pages_text):
                    skipped += 1  # has a proper text layer; the extension reads it itself
                    continue
                pages = ocr_pdf(path, pages_text, a.max_pages, a.lang, deadline)
            if pages:
                records.append({'path': rel, 'size': st.st_size, 'mtime': mtime, 'method': method, 'pages': pages})
                ocred += 1
                if method == 'ocr':
                    log('OCR', rel, f'{len(pages)} page(s)')
        except Exception as e:
            failed += 1
            log('failed', rel, e)
    if not scan_dirs and not prev:
        return 0
    tmp = out_path + '.tmp'
    with gzip.open(tmp, 'wt', encoding='utf-8') as f:
        for r in records:
            f.write(json.dumps(r, ensure_ascii=False) + '\n')
    os.replace(tmp, out_path)
    if a.owner:
        try:
            shutil.chown(out_path, a.owner, a.owner)
            shutil.chown(os.path.dirname(out_path), a.owner, a.owner)
        except Exception as e:
            log('chown failed:', e)
    log(f'done: {ocred} OCRed or unpacked, {reused} unchanged, {skipped} with a text layer (read by the extension), {failed} failed → {out_path}')
    return 0


if __name__ == '__main__':
    sys.exit(main())
