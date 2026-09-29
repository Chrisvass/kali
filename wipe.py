#!/usr/bin/env python3

import json
import os
import shutil
import subprocess
import sys
import time


def run(cmd, check=True, capture=False):
    print("+", " ".join(cmd))
    return subprocess.run(
        cmd,
        check=check,
        text=True,
        capture_output=capture,
    )


def die(message):
    print(f"\nERROR: {message}", file=sys.stderr)
    sys.exit(1)


def require_root():
    if os.geteuid() != 0:
        die("Run this script as root, e.g. sudo python3 wipe.py")


def apt_install(package):
    if shutil.which("apt-get") is None:
        die(f"Required package '{package}' is missing and apt-get is unavailable.")

    print(f"\nInstalling required package: {package}")
    run(["apt-get", "update"])
    run(["apt-get", "install", "-y", package])


def ensure_command(command, package):
    if shutil.which(command):
        return
    apt_install(package)
    if not shutil.which(command):
        die(f"'{command}' is still unavailable after installing '{package}'.")


def get_disks():
    result = subprocess.run(
        [
            "lsblk", "-J",
            "-o", "NAME,PATH,TYPE,SIZE,MODEL,SERIAL,TRAN,RM,RO,MOUNTPOINTS"
        ],
        check=True, text=True, capture_output=True,
    )
    data = json.loads(result.stdout)
    return data.get("blockdevices", [])


def is_internal_disk(disk):
    if disk.get("type") != "disk" or disk.get("rm") is True:
        return False

    path = disk.get("path", "")
    if path.startswith("/dev/nvme"):
        return True

    transport = (disk.get("tran") or "").lower()
    return transport in ("sata", "ata")


def find_target():
    disks = get_disks()
    internal = [d for d in disks if is_internal_disk(d)]

    if len(internal) != 1:
        print("\nDetected disks:\n")
        for disk in disks:
            print(
                f"  {disk.get('path', '?'):18} "
                f"{disk.get('type', '?'):6} "
                f"{disk.get('size', '?'):10} "
                f"{disk.get('model', '')} "
                f"{disk.get('serial', '')}"
            )
        die(
            f"Found {len(internal)} internal disk(s); "
            "refusing to guess which disk to erase."
        )

    return internal[0]


def ensure_not_mounted(device):
    result = subprocess.run(
        ["lsblk", "-nr", "-o", "MOUNTPOINTS", device],
        check=True, text=True, capture_output=True,
    )

    mounts = [line.strip() for line in result.stdout.splitlines() if line.strip()]
    if mounts:
        die(
            f"{device} appears to have mounted filesystems:\n"
            + "\n".join(mounts)
        )


def stop_swap(device):
    result = subprocess.run(
        ["swapon", "--show=NAME", "--noheadings"],
        check=True, text=True, capture_output=True,
    )

    for line in result.stdout.splitlines():
        swap = line.strip()
        if swap.startswith(device):
            print(f"Disabling swap: {swap}")
            run(["swapoff", swap])


def remove_partition_signatures(device):
    run(["wipefs", "--all", "--force", device], check=False)


def nvme_secure_erase(device):
    print("\nAttempting NVMe secure erase...")
    ensure_command("nvme", "nvme-cli")

    result = run(["nvme", "format", device, "--ses=1", "--force"], check=False)
    return result.returncode == 0


def sata_secure_erase(device):
    print("\nAttempting ATA Secure Erase...")
    ensure_command("hdparm", "hdparm")

    info = subprocess.run(
        ["hdparm", "-I", device],
        text=True, capture_output=True,
    )

    if info.returncode != 0:
        return False

    text = info.stdout.lower()
    if "frozen" in text:
        print(
            "\nWARNING: The drive reports that security operations "
            "may be frozen by the firmware."
        )
        print(
            "A reboot/suspend cycle may be required before ATA Secure "
            "Erase can be used."
        )
        return False

    result = run([
        "hdparm", "--user-master", "u",
        "--security-set-pass", "wipe", device
    ], check=False)

    if result.returncode != 0:
        return False

    try:
        result = run([
            "hdparm", "--user-master", "u",
            "--security-erase-enhanced", "wipe", device
        ], check=False)

        if result.returncode == 0:
            return True

        result = run([
            "hdparm", "--user-master", "u",
            "--security-erase", "wipe", device
        ], check=False)

        return result.returncode == 0
    finally:
        run([
            "hdparm", "--user-master", "u",
            "--security-disable", "wipe", device
        ], check=False)


def fallback_overwrite(device):
    print(
        "\nHardware secure erase failed or is unavailable."
        "\nFalling back to a single overwrite pass."
        "\nThis can be very slow and is not equivalent to SSD sanitize."
    )

    result = run([
        "shred", "--verbose", "--force",
        "--iterations=1", device
    ], check=False)

    if result.returncode != 0:
        die("Fallback overwrite failed.")


def main():
    require_root()

    if not os.path.exists("/sys/firmware/efi"):
        die(
            "This utility expects a modern UEFI system. "
            "Boot the Live USB in UEFI mode."
        )

    target = find_target()
    device = target["path"]
    model = target.get("model") or "unknown"
    serial = target.get("serial") or "unknown"
    size = target.get("size") or "unknown"

    print()
    print("=" * 70)
    print("                     DISK WIPE")
    print("=" * 70)
    print()
    print(f"Device : {device}")
    print(f"Model  : {model}")
    print(f"Serial : {serial}")
    print(f"Size   : {size}")
    print()
    print("ALL DATA ON THIS DISK WILL BE DESTROYED.")
    print()

    ensure_not_mounted(device)
    stop_swap(device)

    confirmation = input(
        'Type "WIPE" (uppercase) to permanently erase this disk: '
    )
    if confirmation != "WIPE":
        print("Cancelled.")
        return

    print("\nFinal confirmation:")
    print(f"    {device} / {model} / {serial}")
    time.sleep(2)

    run(["wipefs", "--all", "--force", device], check=False)

    if device.startswith("/dev/nvme"):
        success = nvme_secure_erase(device)
    else:
        success = sata_secure_erase(device)

    if success:
        print("\nHardware secure erase completed.")
    else:
        fallback_overwrite(device)

    remove_partition_signatures(device)
    run(["partprobe", device], check=False)

    print()
    print("=" * 70)
    print("WIPE COMPLETE")
    print("=" * 70)
    print()
    print("The disk is ready for a new installation.")


if __name__ == "__main__":
    main()
