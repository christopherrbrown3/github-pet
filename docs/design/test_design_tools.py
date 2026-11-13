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
from validate_pack import PACK, check_pack


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


if __name__ == '__main__':
    unittest.main()
