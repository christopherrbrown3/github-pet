"""Regression tests for bounded PNG input and the declared sprite baseline."""
import hashlib
import json
import shutil
import struct
import tempfile
import tracemalloc
import unittest
import zlib
from pathlib import Path

from png_rgba import MAX_EDGE, MAX_FILE_BYTES, bounds, read_png, sha256_png, write_png
from rig_cut import cut, report
from validate_pack import PACK, check_pack, rig_errors


def chunk(kind, data):
    return struct.pack('>I', len(data)) + kind + data + struct.pack('>I', zlib.crc32(kind + data) & 0xffffffff)


def png(width, height, compressed, trailer=b''):
    header = struct.pack('>IIBBBBB', width, height, 8, 6, 0, 0, 0)
    return b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', header) + chunk(b'IDAT', compressed) + chunk(b'IEND', b'') + trailer


class DesignToolsTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)

    def input(self, data):
        path = self.root / 'input.png'
        path.write_bytes(data)
        return path

    def test_valid_source_frame_and_full_pack(self):
        width, height, rgba = read_png(PACK / 'frames/idle-00.png')
        self.assertEqual((width, height), (256, 256))
        self.assertEqual(bounds(rgba, width, lambda r, g, b, a: a > 8)[3], 232)
        self.assertEqual(check_pack(PACK)['result'], 'pass')

    def test_oversized_header_rejected_before_scanline_allocation(self):
        path = self.input(png(MAX_EDGE + 1, 1, zlib.compress(b'\0' * 5)))
        with self.assertRaisesRegex(ValueError, 'dimensions'):
            read_png(path)
        path = self.input(png(0xffffffff, 1, zlib.compress(b'\0' * 5)))
        with self.assertRaisesRegex(ValueError, 'dimensions'):
            read_png(path)

    def test_small_header_compression_bomb_is_bounded(self):
        # Original implementation allocated ~17.5 MB before rejecting this.
        path = self.input(png(1, 1, zlib.compress(b'\0' * (8 * 1024 * 1024))))
        tracemalloc.start()
        try:
            with self.assertRaisesRegex(ValueError, 'scanline'):
                read_png(path)
            _, peak = tracemalloc.get_traced_memory()
        finally:
            tracemalloc.stop()
        self.assertLess(peak, 2 * 1024 * 1024)

    def test_truncated_and_trailing_compressed_streams_rejected(self):
        data = zlib.compress(b'\0' * 5)
        for compressed in (data[:-1], data + b'junk', data + zlib.compress(b'\0' * 5)):
            with self.subTest(compressed=compressed):
                with self.assertRaises(ValueError):
                    read_png(self.input(png(1, 1, compressed)))

    def test_consecutive_idat_chunks_supported_but_interrupted_data_rejected(self):
        data = zlib.compress(b'\0' * 5)
        header = chunk(b'IHDR', struct.pack('>IIBBBBB', 1, 1, 8, 6, 0, 0, 0))
        prefix = b'\x89PNG\r\n\x1a\n' + header
        split = chunk(b'IDAT', data[:2]) + chunk(b'IDAT', data[2:]) + chunk(b'IEND', b'')
        self.assertEqual(read_png(self.input(prefix + split))[:2], (1, 1))
        interrupted = chunk(b'IDAT', data[:2]) + chunk(b'tEXt', b'a\0b') + chunk(b'IDAT', data[2:]) + chunk(b'IEND', b'')
        with self.assertRaisesRegex(ValueError, 'data order'):
            read_png(self.input(prefix + interrupted))

    def test_malformed_container_rejected(self):
        valid = png(1, 1, zlib.compress(b'\0' * 5))
        for payload in (valid[:-1], valid + b'junk', b'\x89PNG\r\n\x1a\n' + b'\xff\xff\xff\xffIDAT' + b'1234'):
            with self.subTest(size=len(payload)):
                with self.assertRaises(ValueError):
                    read_png(self.input(payload))

    def test_file_and_hash_limits(self):
        path = self.root / 'large.png'
        with path.open('wb') as stream:
            stream.truncate(MAX_FILE_BYTES + 1)
        for operation in (read_png, sha256_png):
            with self.subTest(operation=operation.__name__):
                with self.assertRaisesRegex(ValueError, 'size limit'):
                    operation(path)

    def test_upward_shift_rejected_even_with_matching_new_hash(self):
        copy = self.root / 'pack'
        shutil.copytree(PACK, copy)
        frame = copy / 'frames/idle-00.png'
        width, height, pixels = read_png(frame)
        stride = width * 4
        shifted = pixels[4 * stride:] + bytearray(4 * stride)
        write_png(frame, width, height, shifted)
        manifest_path = copy / 'manifest.json'
        manifest = json.loads(manifest_path.read_text())
        manifest['frameSha256']['frames/idle-00.png'] = hashlib.sha256(frame.read_bytes()).hexdigest()
        manifest_path.write_text(json.dumps(manifest))
        with self.assertRaisesRegex(ValueError, 'Ground anchor mismatch'):
            check_pack(copy)

    def test_faint_alpha_below_anchor_is_not_ignored(self):
        copy = self.root / 'pack'
        shutil.copytree(PACK, copy)
        frame = copy / 'frames/idle-00.png'
        width, height, pixels = read_png(frame)
        pixels[(235 * width + 128) * 4 + 3] = 1
        write_png(frame, width, height, pixels)
        manifest_path = copy / 'manifest.json'
        manifest = json.loads(manifest_path.read_text())
        manifest['frameSha256']['frames/idle-00.png'] = hashlib.sha256(frame.read_bytes()).hexdigest()
        manifest_path.write_text(json.dumps(manifest))
        with self.assertRaisesRegex(ValueError, 'Ground anchor mismatch'):
            check_pack(copy)

    def test_faint_anchor_pixel_cannot_hide_upward_shift(self):
        copy = self.root / 'pack'
        shutil.copytree(PACK, copy)
        frame = copy / 'frames/idle-00.png'
        width, height, pixels = read_png(frame)
        stride = width * 4
        shifted = pixels[4 * stride:] + bytearray(4 * stride)
        # A nearly transparent pixel at the anchor must not certify raised art.
        shifted[(231 * width + 128) * 4 + 3] = 1
        write_png(frame, width, height, shifted)
        manifest_path = copy / 'manifest.json'
        manifest = json.loads(manifest_path.read_text())
        manifest['frameSha256']['frames/idle-00.png'] = hashlib.sha256(frame.read_bytes()).hexdigest()
        manifest_path.write_text(json.dumps(manifest))
        with self.assertRaisesRegex(ValueError, 'Ground anchor mismatch'):
            check_pack(copy)


class RigCutTests(unittest.TestCase):
    def sheet(self, root, rects):
        width = height = 200
        pixels = bytearray(width * height * 4)
        for x0, y0, x1, y1 in rects:
            for y in range(y0, y1):
                for x in range(x0, x1):
                    pixels[(y * width + x) * 4:(y * width + x) * 4 + 4] = b'\x10\x10\x10\xff'
        path = root / 'sheet.png'
        write_png(path, width, height, pixels)
        return path

    def test_islands_in_reading_order_and_gap_rule(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            # Two parts in the top band, one below, one 2 px speck that is ignored.
            path = self.sheet(root, [(120, 10, 180, 60), (10, 20, 60, 50), (10, 120, 60, 190), (150, 150, 152, 151)])
            text, parts, _, ok = report(path, expect=3)
            self.assertTrue(ok, text)
            self.assertEqual([p['box'] for p in parts], [[10, 20, 60, 50], [120, 10, 180, 60], [10, 120, 60, 190]])
            self.assertIn('1 specks', text)
            self.assertFalse(report(path, expect=4)[3])
            cut(path, root / 'out')
            self.assertEqual(read_png(root / 'out' / 'island-00.png')[:2], (58, 38))
            path = self.sheet(root, [(10, 10, 60, 60), (80, 10, 120, 60)])
            self.assertIn('within 20 px', report(path)[0])


class RigSchemaTests(unittest.TestCase):
    def rig(self):
        return {
            'unitScale': 2, 'restScale': 0.96, 'reserve': [47, 20, 217],
            'bones': {'root': {'pivot': [128, 232]}, 'body': {'parent': 'root', 'pivot': [128, 200], 'rot': [-8, 8]},
                      'head': {'parent': 'body', 'pivot': [128, 138], 'rot': [-14, 14]},
                      'hand': {'parent': 'body', 'pivot': [86, 190]}},
            'parts': [{'name': 'body', 'image': 'rig/body.png', 'bone': 'body', 'origin': [84, 122]},
                      {'name': 'eyes', 'image': 'rig/eyes.png', 'bone': 'head', 'origin': [96, 66],
                       'variants': {'closed': 'rig/eyes-closed.png'}},
                      {'name': 'helmet', 'image': 'rig/helmet.png', 'bone': 'head', 'origin': [86, 17], 'hidden': True,
                       'mounts': {'hand': {'bone': 'hand', 'origin': [56, 176]}}}],
            'faces': {'blink': {'eyes': 'closed'}},
            'poses': {'attention': {'channels': {'head.rot': -3}, 'face': 'blink'}},
            'clips': {'new-item': {'durationMs': 1900, 'tracks': {'root.sy': [[0, 1], [460, 1.04, 'out'], [900, 1, 'spring']]},
                                   'worn': {'root.y': [[0, 0]]}, 'follow': [{'bone': 'head', 'of': 'body', 'delayMs': 40, 'gain': 0.6}],
                                   'sway': [{'bones': ['hand'], 'amp': 5, 'periodMs': 1000}],
                                   'swaps': [{'at': 240, 'part': 'helmet', 'variant': 'default'}],
                                   'faces': [{'at': 1700, 'preset': 'blink'}],
                                   'mounts': [{'at': 200, 'part': 'helmet', 'mount': 'hand'},
                                              {'at': 820, 'part': 'helmet', 'mount': 'default', 'blendMs': 260}],
                                   'endsOn': 'attention'}},
        }

    def test_valid_rig_passes(self):
        self.assertEqual(rig_errors(self.rig()), [])

    def test_each_rule_is_enforced(self):
        cases = [
            (lambda r: r['bones']['root'].update(parent='head'), 'parentless'),
            (lambda r: r['bones']['head'].update(parent='body2'), 'unknown parent'),
            (lambda r: r['clips']['new-item']['tracks'].update({'tail.rot': [[0, 1]]}), 'unknown track'),
            (lambda r: r['clips']['new-item']['tracks'].update({'head.rot': [[0, 0], [100, 40]]}), 'outside'),
            (lambda r: r['clips']['new-item']['tracks'].update({'root.y': [[500, 0], [100, 1]]}), 'must rise'),
            (lambda r: r['clips']['new-item']['tracks'].update({'root.y': [[0, 0, 'bounce']]}), 'known ease'),
            (lambda r: r['clips']['new-item'].update(durationMs=2500), 'durationMs'),
            (lambda r: r['clips'].update(wave=r['clips']['new-item']), 'unknown clip'),
            (lambda r: r['clips']['new-item'].update(endsOn='dance'), 'endsOn'),
            (lambda r: r['clips']['new-item'].update(faces=[{'at': 0, 'preset': 'smirk'}]), 'bad face'),
            (lambda r: r['clips']['new-item'].update(mounts=[{'at': 0, 'part': 'helmet', 'mount': 'foot'}]), 'bad mount'),
            (lambda r: r['faces'].update(blink={'eyes': 'sparkly'}), 'variant'),
            (lambda r: r['poses']['attention']['channels'].update({'head.rot': 40}), 'outside'),
            (lambda r: r['clips']['new-item']['worn'].update({'root.sy': [[0, 2]]}), 'outside'),
            (lambda r: r.update(reserve=[217, 20, 47]), 'reserve'),
        ]
        for edit, expected in cases:
            rig = self.rig()
            edit(rig)
            errors = rig_errors(rig)
            self.assertTrue(any(expected in error for error in errors), (expected, errors))


if __name__ == '__main__':
    unittest.main()
