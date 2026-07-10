#!/usr/bin/env python3
"""Validate that a macOS audio file decodes, has duration, and is not silent."""

from __future__ import annotations

import argparse
import array
import math
import os
import struct
import subprocess
import sys
import tempfile
from pathlib import Path


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("path", type=Path)
    parser.add_argument("--minimum-duration", type=float, default=1.0)
    parser.add_argument("--minimum-peak", type=float, default=0.001)
    parser.add_argument("--minimum-rms", type=float, default=0.0001)
    return parser.parse_args()


def run_checked(command: list[str]) -> subprocess.CompletedProcess[str]:
    result = subprocess.run(command, text=True, capture_output=True, check=False)
    if result.returncode != 0:
        detail = (result.stderr or result.stdout).strip()
        raise RuntimeError(f"command failed ({result.returncode}): {' '.join(command)}\n{detail}")
    return result


def wave_chunks(path: Path) -> tuple[int, int, int, int, int]:
    with path.open("rb") as handle:
        header = handle.read(12)
        if len(header) != 12 or header[:4] != b"RIFF" or header[8:] != b"WAVE":
            raise RuntimeError("afconvert output is not a RIFF/WAVE file")

        channels = sample_rate = bits_per_sample = 0
        data_offset = data_size = 0
        while True:
            chunk_header = handle.read(8)
            if not chunk_header:
                break
            if len(chunk_header) != 8:
                raise RuntimeError("truncated WAVE chunk header")
            chunk_id, chunk_size = struct.unpack("<4sI", chunk_header)
            chunk_start = handle.tell()
            if chunk_id == b"fmt ":
                payload = handle.read(min(chunk_size, 40))
                if len(payload) < 16:
                    raise RuntimeError("truncated WAVE fmt chunk")
                _, channels, sample_rate, _, _, bits_per_sample = struct.unpack(
                    "<HHIIHH", payload[:16]
                )
            elif chunk_id == b"data":
                data_offset = chunk_start
                data_size = chunk_size
            handle.seek(chunk_start + chunk_size + (chunk_size % 2))

        if not channels or not sample_rate or bits_per_sample != 16 or not data_size:
            raise RuntimeError(
                "unsupported or empty WAVE output "
                f"(channels={channels}, sample_rate={sample_rate}, bits={bits_per_sample}, data={data_size})"
            )
        return channels, sample_rate, bits_per_sample, data_offset, data_size


def pcm_metrics(path: Path) -> tuple[float, float, float]:
    channels, sample_rate, bits_per_sample, data_offset, data_size = wave_chunks(path)
    bytes_per_sample = bits_per_sample // 8
    duration = data_size / (sample_rate * channels * bytes_per_sample)
    sample_count = 0
    peak = 0
    sum_squares = 0.0
    leftover = b""

    with path.open("rb") as handle:
        handle.seek(data_offset)
        remaining = data_size
        while remaining > 0:
            block = handle.read(min(1_048_576, remaining))
            if not block:
                raise RuntimeError("truncated WAVE PCM data")
            remaining -= len(block)
            block = leftover + block
            complete = len(block) - (len(block) % bytes_per_sample)
            leftover = block[complete:]
            samples = array.array("h")
            samples.frombytes(block[:complete])
            if sys.byteorder != "little":
                samples.byteswap()
            if samples:
                peak = max(peak, max(abs(value) for value in samples))
                sum_squares += math.fsum(value * value for value in samples)
                sample_count += len(samples)

    if sample_count == 0:
        raise RuntimeError("decoded audio contains no PCM samples")
    return duration, peak / 32768.0, math.sqrt(sum_squares / sample_count) / 32768.0


def main() -> int:
    args = parse_args()
    source = args.path.expanduser().resolve()
    if not source.is_file():
        print(f"audio file not found: {source}", file=sys.stderr)
        return 2

    temp_path: Path | None = None
    try:
        afinfo = run_checked(["/usr/bin/afinfo", str(source)])
        if "estimated duration" not in afinfo.stdout:
            raise RuntimeError("afinfo did not report an estimated duration")

        with tempfile.NamedTemporaryFile(prefix="meeting-recorder-qa-", suffix=".wav", delete=False) as temp:
            temp_path = Path(temp.name)
        run_checked(
            [
                "/usr/bin/afconvert",
                str(source),
                str(temp_path),
                "-f",
                "WAVE",
                "-d",
                "LEI16",
            ]
        )
        duration, peak, rms = pcm_metrics(temp_path)
        print(f"duration={duration:.3f}s peak={peak:.6f} rms={rms:.6f} file={source}")

        failures = []
        if duration < args.minimum_duration:
            failures.append(f"duration {duration:.3f}s < {args.minimum_duration:.3f}s")
        if peak < args.minimum_peak:
            failures.append(f"peak {peak:.6f} < {args.minimum_peak:.6f}")
        if rms < args.minimum_rms:
            failures.append(f"rms {rms:.6f} < {args.minimum_rms:.6f}")
        if failures:
            print("invalid audio: " + "; ".join(failures), file=sys.stderr)
            return 1
        return 0
    except (OSError, RuntimeError) as error:
        print(f"audio validation failed: {error}", file=sys.stderr)
        return 1
    finally:
        if temp_path is not None:
            try:
                os.unlink(temp_path)
            except FileNotFoundError:
                pass


if __name__ == "__main__":
    raise SystemExit(main())
