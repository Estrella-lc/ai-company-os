"""Fixed, bounded adapters for mature libraries. Never execute downloaded skill scripts."""
import hashlib
import io
import json
import os
import socket
import sys
import zipfile
from importlib.metadata import version
from pathlib import Path

from docx import Document
from docx.oxml.ns import qn
from pypdf import PdfReader

LIMIT = 2 * 1024 * 1024
PROFILES = ('pdf_extract_v1', 'docx_extract_v1', 'docx_create_v1')


def digest(data):
    return hashlib.sha256(data).hexdigest()


def read_docx(data):
    with zipfile.ZipFile(io.BytesIO(data)) as archive:
        entries = archive.infolist()
        if len(entries) > 1000 or sum(x.file_size for x in entries) > 16 * LIMIT:
            raise ValueError('docx_expansion_limit')
        if any(x.filename.endswith('vbaProject.bin') for x in entries):
            raise ValueError('macros_not_supported')
        for entry in entries:
            if entry.filename.endswith('.rels') and b'TargetMode="External"' in archive.read(entry):
                raise ValueError('external_relationship_not_supported')
    doc = Document(io.BytesIO(data))
    # Preserve top-level paragraph/table order. Do not claim nested table/layout reconstruction.
    blocks = []
    for block in doc.iter_inner_content():
        if hasattr(block, 'rows'):
            blocks.extend('\t'.join(cell.text for cell in row.cells) for row in block.rows)
        else:
            blocks.append(block.text)
    text = '\n'.join(blocks)
    if not text.strip():
        raise ValueError('no_extractable_text')
    return text


def extract_pdf(data):
    reader = PdfReader(io.BytesIO(data), strict=True)
    if reader.is_encrypted:
        raise ValueError('encrypted_pdf_not_supported')
    if not 1 <= len(reader.pages) <= 30:
        raise ValueError('pdf_page_limit')
    if reader.trailer['/Root'].get('/OpenAction'):
        raise ValueError('active_pdf_not_supported')
    pages = [page.extract_text() or '' for page in reader.pages]
    if any(not text.strip() for text in pages):
        raise ValueError('ocr_required_or_blank_page')
    return '\n\n'.join(pages)


def process(profile, data):
    if profile not in PROFILES or not 1 <= len(data) <= LIMIT:
        raise ValueError('invalid_profile_or_size')
    if profile == 'pdf_extract_v1':
        if not data.startswith(b'%PDF-'):
            raise ValueError('pdf_signature')
        text = extract_pdf(data)
        output = text.encode('utf-8')
    elif profile == 'docx_extract_v1':
        text = read_docx(data)
        output = text.encode('utf-8')
    else:
        text = data.decode('utf-8-sig')
        if not text.strip() or len(text) > 20000 or any(ord(c) < 32 and c not in '\n\r\t' for c in text):
            raise ValueError('invalid_text_input')
        text = text.replace('\r\n', '\n').replace('\r', '\n')
        doc = Document()
        style = doc.styles['Normal']
        style.font.name = 'Calibri'
        style.element.rPr.rFonts.set(qn('w:eastAsia'), 'Microsoft YaHei')
        for line in text.split('\n'):
            doc.add_paragraph(line)
        stream = io.BytesIO()
        doc.save(stream)
        output = stream.getvalue()
        if read_docx(output) != text:
            raise ValueError('docx_roundtrip_mismatch')
    if len(output) > LIMIT or len(text) > 100000:
        raise ValueError('output_limit')
    return output, {'passed': True, 'scope': profile, 'input_sha256': digest(data),
                    'output_sha256': digest(output), 'output_bytes': len(output),
                    'characters': len(text), 'preview': text[:1000],
                    'engine': {'pypdf': version('pypdf'), 'python-docx': version('python-docx')},
                    'quality_checks': ['input_format', 'bounded_content', 'output_nonempty', 'sha256',
                                       'docx_roundtrip' if profile == 'docx_create_v1' else 'text_extraction'],
                    'limitations': '文本内容处理；不包含OCR、嵌套表格、原排版还原或语义真实性验收。'}


def pdf_fixture(text='PDF fixture 2026'):
    from reportlab.pdfgen import canvas
    stream = io.BytesIO()
    c = canvas.Canvas(stream)
    c.drawString(72, 720, text)
    c.save()
    return stream.getvalue()


def fixtures():
    from reportlab.pdfbase import pdfmetrics
    from reportlab.pdfbase.cidfonts import UnicodeCIDFont
    from reportlab.pdfgen import canvas
    network_disabled = False
    try:
        socket.create_connection(('1.1.1.1', 443), timeout=1)
    except OSError:
        network_disabled = True
    root_read_only = False
    try:
        Path('/document-isolation-probe').write_text('probe')
    except OSError:
        root_read_only = True
    isolation = {'network_disabled': network_disabled, 'unprivileged': os.geteuid() == 65534,
                 'root_read_only': root_read_only,
                 'secrets_absent': not any(k in os.environ for k in ('GEMINI_API_KEY', 'SUPABASE_SERVICE_ROLE_KEY', 'ACTIONS_ID_TOKEN_REQUEST_TOKEN'))}
    assert all(isolation.values()), isolation
    cases = []
    def expect(name, callback):
        callback()
        cases.append(name)
    def equal(a, b):
        assert a == b, (a, b)
    def rejected(profile, data):
        try:
            process(profile, data)
        except Exception:
            return
        raise AssertionError('invalid file accepted')
    expect('pdf_ascii', lambda: equal(process('pdf_extract_v1', pdf_fixture())[0].strip(), b'PDF fixture 2026'))
    pdfmetrics.registerFont(UnicodeCIDFont('STSong-Light'))
    stream = io.BytesIO()
    c = canvas.Canvas(stream)
    c.setFont('STSong-Light', 12)
    c.drawString(72, 720, '中文验证 2026')
    c.save()
    expect('pdf_chinese', lambda: equal(process('pdf_extract_v1', stream.getvalue())[0].decode().strip(), '中文验证 2026'))
    expect('pdf_corrupt', lambda: rejected('pdf_extract_v1', b'%PDF-broken'))
    from pypdf import PdfWriter
    writer = PdfWriter()
    writer.add_blank_page(width=100, height=100)
    stream = io.BytesIO()
    writer.write(stream)
    expect('pdf_scan_or_blank_blocked', lambda: rejected('pdf_extract_v1', stream.getvalue()))
    writer.encrypt('synthetic-password')
    stream = io.BytesIO()
    writer.write(stream)
    expect('pdf_encrypted_blocked', lambda: rejected('pdf_extract_v1', stream.getvalue()))
    text = '公司测试\nHello 2026\n第二段'
    output, _ = process('docx_create_v1', text.encode())
    expect('docx_chinese_roundtrip', lambda: equal(process('docx_extract_v1', output)[0].decode(), text))
    doc = Document()
    doc.add_paragraph('表前')
    table = doc.add_table(rows=1, cols=2)
    table.cell(0, 0).text = '名称'
    table.cell(0, 1).text = '金额99'
    doc.add_paragraph('表后')
    stream = io.BytesIO()
    doc.save(stream)
    expect('docx_table_order', lambda: equal(process('docx_extract_v1', stream.getvalue())[0].decode(), '表前\n名称\t金额99\n表后'))
    expect('docx_corrupt', lambda: rejected('docx_extract_v1', b'PKbroken'))
    expect('empty_text', lambda: rejected('docx_create_v1', b' '))
    expect('size_limit', lambda: rejected('pdf_extract_v1', b'x' * (LIMIT + 1)))
    Path('/out/synthetic-input.pdf').write_bytes(pdf_fixture())
    Path('/out/synthetic-input.docx').write_bytes(output)
    sample, sample_report = process('docx_create_v1', text.encode())
    Path('/out/synthetic-output.docx').write_bytes(sample)
    report = {'passed': True, 'scope': 'document_processing_v1', 'profiles': list(PROFILES),
              'case_count': len(cases), 'passed_count': len(cases), 'cases': cases,
              'engine': sample_report['engine'], 'isolation': isolation, 'third_party_scripts_executed': False}
    Path('/out/verification.json').write_text(json.dumps(report, ensure_ascii=False), encoding='utf-8')
    print(json.dumps(report))


if __name__ == '__main__':
    try:
        if '--fixture' in sys.argv:
            fixtures()
        else:
            request = json.loads(Path('/request/config.json').read_text())
            output, report = process(request['profile'], Path('/request/input').read_bytes())
            Path('/out/result').write_bytes(output)
            Path('/out/report.json').write_text(json.dumps(report, ensure_ascii=False), encoding='utf-8')
            print(json.dumps({'passed': True, 'output_sha256': report['output_sha256']}))
    except Exception as exc:
        print(json.dumps({'passed': False, 'error': str(exc)[:160]}))
        sys.exit(1)
