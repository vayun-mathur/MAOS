#!/usr/bin/env python3
"""
sparse_split.py — split a raw partition image into multiple Android *sparse* images,
each small enough for one fastboot `download` (i.e. under the device's max-download-size).

Why: partitions like `super` are multiple GB, but a device only accepts max-download-size
bytes per download (often a few hundred MB). fastboot normally re-chunks large images into
several sparse files and flashes each to the same partition; the MAOS web installer flashes
pre-split chunks instead of implementing sparse in the browser. Each output file is a full
sparse image for the WHOLE partition, but contains real data only for its slice and marks
the rest DONT_CARE, so flashing them in order reconstructs the partition.

Sparse format ref: AOSP system/core/libsparse (sparse_format.h).

USAGE:
    sparse_split.py <raw-image> <out-prefix> [--max-bytes N] [--block-size 4096]

Emits <out-prefix>.0.simg, <out-prefix>.1.simg, ... and prints each filename on stdout.

NOTE: authored against the documented format; validate a real flash on a device before
relying on it.
"""
import argparse
import os
import struct
import sys

SPARSE_MAGIC = 0xED26FF3A
CHUNK_RAW = 0xCAC1
CHUNK_FILL = 0xCAC2
CHUNK_DONT_CARE = 0xCAC3

FILE_HDR_SZ = 28
CHUNK_HDR_SZ = 12


def write_header(f, block_size, total_blocks, total_chunks):
    f.write(
        struct.pack(
            "<IHHHHIIII",
            SPARSE_MAGIC,
            1,  # major
            0,  # minor
            FILE_HDR_SZ,
            CHUNK_HDR_SZ,
            block_size,
            total_blocks,
            total_chunks,
            0,  # image checksum (unused)
        )
    )


def write_dont_care(f, blocks):
    f.write(struct.pack("<HHII", CHUNK_DONT_CARE, 0, blocks, CHUNK_HDR_SZ))


def write_raw(f, data, block_size):
    assert len(data) % block_size == 0
    blocks = len(data) // block_size
    f.write(struct.pack("<HHII", CHUNK_RAW, 0, blocks, CHUNK_HDR_SZ + len(data)))
    f.write(data)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("raw")
    ap.add_argument("out_prefix")
    ap.add_argument("--max-bytes", type=int, default=100 * 1024 * 1024,
                    help="max real data bytes per output file (default 100 MiB)")
    ap.add_argument("--block-size", type=int, default=4096)
    args = ap.parse_args()

    bs = args.block_size
    size = os.path.getsize(args.raw)
    total_blocks = (size + bs - 1) // bs
    # Real-data blocks per output file (keep each file's payload under --max-bytes).
    blocks_per_file = max(1, args.max_bytes // bs)

    outputs = []
    with open(args.raw, "rb") as src:
        idx = 0
        start = 0  # starting block for this output file
        while start < total_blocks:
            end = min(start + blocks_per_file, total_blocks)
            out_path = f"{args.out_prefix}.{idx}.simg"
            with open(out_path, "wb") as out:
                # chunks: [DONT_CARE prefix?] [RAW slice] [DONT_CARE suffix?]
                chunks = 0
                chunks += 1 if start > 0 else 0
                chunks += 1  # the RAW slice
                chunks += 1 if end < total_blocks else 0
                write_header(out, bs, total_blocks, chunks)

                if start > 0:
                    write_dont_care(out, start)

                src.seek(start * bs)
                to_read = (end - start) * bs
                data = src.read(min(to_read, size - start * bs))
                # Zero-pad the final block if the image isn't block-aligned.
                if len(data) % bs != 0:
                    data += b"\x00" * (bs - (len(data) % bs))
                # If this slice runs past EOF (last file), pad remaining blocks with zeros.
                expected = (end - start) * bs
                if len(data) < expected:
                    data += b"\x00" * (expected - len(data))
                write_raw(out, data, bs)

                if end < total_blocks:
                    write_dont_care(out, total_blocks - end)

            outputs.append(out_path)
            print(out_path)
            idx += 1
            start = end

    if not outputs:
        print("no output produced", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
