#!/usr/bin/env python3
import argparse
import base64
import plistlib
from datetime import datetime, timezone
from email.utils import format_datetime
from pathlib import Path
from urllib.parse import quote
from xml.sax.saxutils import escape, quoteattr

from cryptography.hazmat.primitives import serialization


def parse_args():
    parser = argparse.ArgumentParser(description="Generate Sparkle appcast for a GitHub Release asset.")
    parser.add_argument("--dmg", required=True, help="Path to the signed DMG file.")
    parser.add_argument("--app", default="build/Release/SimpleRecorder.app", help="Path to the built app.")
    parser.add_argument("--repo", default="bi-boo/meeting-recorder-pro", help="GitHub repo, e.g. owner/name.")
    parser.add_argument("--tag", help="GitHub release tag. Defaults to v<short-version>.")
    parser.add_argument("--private-key", default="config/sparkle_ed25519_private.pem", help="Ed25519 private key PEM.")
    parser.add_argument("--output", default="build/appcast.xml", help="Output appcast XML path.")
    parser.add_argument("--minimum-system-version", default="13.0", help="Minimum macOS version.")
    return parser.parse_args()


def read_app_versions(app_path):
    info_path = Path(app_path) / "Contents" / "Info.plist"
    with info_path.open("rb") as file:
        info = plistlib.load(file)
    short_version = info["CFBundleShortVersionString"]
    build_version = info["CFBundleVersion"]
    return short_version, build_version


def sign_archive(dmg_path, private_key_path):
    private_key = serialization.load_pem_private_key(Path(private_key_path).read_bytes(), password=None)
    signature = private_key.sign(Path(dmg_path).read_bytes())
    return base64.b64encode(signature).decode("ascii")


def github_asset_url(repo, tag, asset_name):
    encoded_asset = quote(asset_name)
    encoded_tag = quote(tag)
    return f"https://github.com/{repo}/releases/download/{encoded_tag}/{encoded_asset}"


def write_appcast(output_path, repo, tag, dmg_path, short_version, build_version, minimum_system_version, signature):
    dmg = Path(dmg_path)
    output = Path(output_path)
    output.parent.mkdir(parents=True, exist_ok=True)

    asset_url = github_asset_url(repo, tag, dmg.name)
    release_url = f"https://github.com/{repo}/releases/tag/{quote(tag)}"
    pub_date = format_datetime(datetime.now(timezone.utc))
    length = dmg.stat().st_size

    xml = f"""<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>会议录音 Pro 更新</title>
    <link>{escape(release_url)}</link>
    <description>会议录音 Pro 版本更新</description>
    <language>zh-CN</language>
    <item>
      <title>Version {escape(short_version)}</title>
      <pubDate>{escape(pub_date)}</pubDate>
      <sparkle:version>{escape(build_version)}</sparkle:version>
      <sparkle:shortVersionString>{escape(short_version)}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>{escape(minimum_system_version)}</sparkle:minimumSystemVersion>
      <enclosure
        url={quoteattr(asset_url)}
        sparkle:edSignature={quoteattr(signature)}
        length={quoteattr(str(length))}
        type="application/octet-stream" />
    </item>
  </channel>
</rss>
"""
    output.write_text(xml, encoding="utf-8")
    return output, asset_url


def main():
    args = parse_args()
    dmg_path = Path(args.dmg)
    private_key_path = Path(args.private_key)

    if not dmg_path.is_file():
        raise SystemExit(f"DMG not found: {dmg_path}")
    if not private_key_path.is_file():
        raise SystemExit(
            "Sparkle private key not found. Expected an ignored local key at "
            f"{private_key_path}. Keep this key private; the app contains only the public key."
        )

    short_version, build_version = read_app_versions(args.app)
    tag = args.tag or f"v{short_version}"
    signature = sign_archive(dmg_path, private_key_path)
    output, asset_url = write_appcast(
        args.output,
        args.repo,
        tag,
        dmg_path,
        short_version,
        build_version,
        args.minimum_system_version,
        signature,
    )

    print(f"appcast: {output}")
    print(f"version: {short_version} ({build_version})")
    print(f"asset: {asset_url}")


if __name__ == "__main__":
    main()
