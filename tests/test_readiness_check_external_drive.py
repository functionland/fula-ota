"""readiness-check drive guard: auto-format only EMPTY new drives, never data,
and the restart escalation never re-partitions.

subprocess.run is replaced by a fake that answers each read-only command from a
small in-memory device model and records every call, so the tests can assert
exactly which (if any) destructive commands would run.
"""

import inspect
import re
import subprocess

import pytest

from conftest import readiness

GIB = 1024 ** 3
DESTRUCTIVE = ("wipefs", "parted", "mkfs.ext4", "rm")


class FakeDevice:
    """blkid/lsblk/findmnt/df/find answers for one or more external disks."""

    def __init__(self, partitions, root_source="/dev/mmcblk0p1", mergerfs_branches=("/media/pi/sda1",),
                 fail_on=None, find_returncode=0):
        # partitions: {"/dev/sdb1": {"disk": "/dev/sdb", "fstype": "exfat", "size": 2000*GIB,
        #                            "mount": "/media/pi/sdb1", "used": 50*2**20, "files": 3}}
        self.parts = partitions
        self.root_source = root_source
        self.branches = mergerfs_branches
        self.fail_on = fail_on or ()
        self.find_returncode = find_returncode
        self.calls = []
        self.unmounted = set()

    def _cp(self, cmd, stdout="", returncode=0):
        return subprocess.CompletedProcess(cmd, returncode, stdout=stdout, stderr="")

    def run(self, cmd, **kwargs):
        self.calls.append(list(cmd))
        prog = cmd[1] if cmd[0] == "sudo" else cmd[0]
        args = cmd[2:] if cmd[0] == "sudo" else cmd[1:]
        if prog in self.fail_on:
            if kwargs.get("check"):
                raise subprocess.CalledProcessError(1, cmd)
            return self._cp(cmd, returncode=1)
        if prog == "blkid":
            lines = ['/dev/sda1: UUID="u0" BLOCK_SIZE="4096" TYPE="ext4" PARTUUID="p0"']
            for dev, p in self.parts.items():
                lines.append('%s: UUID="u" TYPE="%s" PTTYPE="gpt"' % (dev, p["fstype"]))
            lines.append('/dev/mmcblk0p1: UUID="r" TYPE="ext4"')
            return self._cp(cmd, "\n".join(lines) + "\n")
        if prog == "lsblk":
            dev = args[-1]
            if "SIZE" in args:
                return self._cp(cmd, "%d\n" % self.parts[dev]["size"])
            if "PKNAME" in args:
                if dev in self.parts:
                    return self._cp(cmd, self.parts[dev]["disk"].replace("/dev/", "") + "\n")
                if dev.startswith("/dev/mmcblk0p"):
                    return self._cp(cmd, "mmcblk0\n")
                return self._cp(cmd, "\n")
            if "NAME,TYPE" in args:
                rows = ["%s disk" % dev] + ["%s part" % d for d, p in self.parts.items() if p["disk"] == dev]
                return self._cp(cmd, "\n".join(rows) + "\n")
            if "FSTYPE" in args:
                p = self.parts.get(dev)
                return self._cp(cmd, (p["fstype"] if p else "") + "\n")
        if prog == "findmnt":
            if "-S" in args:
                dev = args[args.index("-S") + 1]
                p = self.parts.get(dev)
                if p and p.get("mount") and dev not in self.unmounted:
                    return self._cp(cmd, p["mount"] + "\n")
                return self._cp(cmd, "")
            if args[-1] in ("/", "/boot"):
                return self._cp(cmd, (self.root_source if args[-1] == "/" else "") + "\n")
        if prog == "df":
            mp = args[-1]
            used = next(p["used"] for p in self.parts.values() if p.get("mount") == mp)
            return self._cp(cmd, "Used\n%d\n" % used)
        if prog == "bash":  # bounded `find | head` emptiness probe
            mp = cmd[4]
            files = next(p["files"] for p in self.parts.values() if p.get("mount") == mp)
            limit = int(cmd[5])
            return self._cp(cmd, "f\n" * min(files, limit), returncode=self.find_returncode)
        if prog == "umount":
            for dev, p in self.parts.items():
                if p.get("mount") == args[-1]:
                    self.unmounted.add(dev)
            return self._cp(cmd)
        return self._cp(cmd)  # systemctl, wipefs, parted, udevadm, mkfs, touch ...

    def destructive_calls(self):
        out = []
        for c in self.calls:
            prog = c[1] if c[0] == "sudo" else c[0]
            if prog in DESTRUCTIVE:
                out.append(c)
        return out


@pytest.fixture
def device(monkeypatch, tmp_path):
    def make(**kw):
        dev = FakeDevice(**kw)
        monkeypatch.setattr(readiness.subprocess, "run", dev.run)
        monkeypatch.setattr(readiness, "_append_event", lambda *a, **k: None)
        monkeypatch.setattr(readiness, "_pool_branches", lambda: set(dev.branches))
        monkeypatch.setattr(readiness, "DRIVE_FORMAT_STATE_PATH", str(tmp_path / "drive.state"))
        readiness._drive_skip_logged.clear()
        return dev
    return make


def _new_exfat(**over):
    p = {"disk": "/dev/sdb", "fstype": "exfat", "size": 2000 * GIB,
         "mount": "/media/pi/sdb1", "used": 50 * 2 ** 20, "files": 3}
    p.update(over)
    return {"/dev/sdb1": p}


def test_empty_new_drive_is_formatted_alone_then_reboot_requested(device):
    dev = device(partitions=_new_exfat())
    assert readiness.check_external_drive() is True
    destructive = dev.destructive_calls()
    assert ["sudo", "wipefs", "-a", "/dev/sdb"] in destructive
    assert ["sudo", "mkfs.ext4", "-F", "/dev/sdb1"] in destructive
    assert any(c[:3] == ["sudo", "parted", "-s"] and c[3] == "/dev/sdb" for c in destructive)
    # Only the new disk is touched; never rm, never the pool disk.
    assert not any("rm" in c for c in destructive)
    assert not any(a.startswith("/dev/sda") for c in destructive for a in c)
    assert ["sudo", "touch", readiness.COMMAND_REBOOT_PATH] in dev.calls


@pytest.mark.parametrize("override,reason_fragment", [
    ({"used": 5 * GIB}, "holds data"),
    ({"files": 500}, "holds data"),
    ({"mount": None}, "not mounted"),
])
def test_drive_with_data_or_unverifiable_is_never_touched(device, override, reason_fragment, tmp_path):
    dev = device(partitions=_new_exfat(**override))
    assert readiness.check_external_drive() is False
    assert dev.destructive_calls() == []
    assert reason_fragment in (tmp_path / "drive.state").read_text()


def test_tiny_raw_partition_is_ignored_but_large_raw_partition_blocks(device):
    msr = {"disk": "/dev/sdb", "fstype": "", "size": 16 * 2 ** 20, "mount": None, "used": 0, "files": 0}
    dev = device(partitions={**_new_exfat(), "/dev/sdb2": msr})
    assert readiness.check_external_drive() is True              # MSR alone does not block
    assert any(c[1:3] == ["mkfs.ext4", "-F"] for c in dev.calls if c[0] == "sudo")

    hidden = {"disk": "/dev/sdb", "fstype": "", "size": 900 * GIB, "mount": None, "used": 0, "files": 0}
    dev = device(partitions={**_new_exfat(), "/dev/sdb2": hidden})
    assert readiness.check_external_drive() is False             # e.g. an encrypted volume
    assert dev.destructive_calls() == []


def test_partition_mounted_outside_media_pi_is_never_touched(device):
    dev = device(partitions=_new_exfat(mount="/mnt/backup"))
    assert readiness.check_external_drive() is False
    assert dev.destructive_calls() == []


def test_find_failure_counts_as_not_empty(device):
    dev = device(partitions=_new_exfat(), find_returncode=1)
    assert readiness.check_external_drive() is False
    assert dev.destructive_calls() == []


def test_small_or_ext4_drives_are_ignored(device):
    dev = device(partitions=_new_exfat(size=200 * GIB))
    assert readiness.check_external_drive() is False
    assert dev.destructive_calls() == []


def test_pool_member_is_never_touched(device):
    dev = device(partitions=_new_exfat(mount="/media/pi/sda1"), mergerfs_branches=("/media/pi/sda1",))
    assert readiness.check_external_drive() is False
    assert dev.destructive_calls() == []


def test_failed_unmount_aborts_before_any_wipe(device):
    dev = device(partitions=_new_exfat(), fail_on=("umount",))
    assert readiness.check_external_drive() is False
    assert dev.destructive_calls() == []


def test_failed_wipe_stops_the_sequence(device):
    dev = device(partitions=_new_exfat(), fail_on=("wipefs",))
    assert readiness.check_external_drive() is False
    progs = [c[1] for c in dev.calls if c[0] == "sudo"]
    assert "parted" not in progs and "mkfs.ext4" not in progs


def test_never_raises(device, monkeypatch):
    device(partitions=_new_exfat())
    def boom(*a, **k):
        raise RuntimeError("blkid exploded")
    monkeypatch.setattr(readiness, "_drive_format_candidates", boom)
    assert readiness.check_external_drive() is False


# ---------------------------------------------------------------------------
# Escalation and caller wiring (source-level guards)
# ---------------------------------------------------------------------------

def test_escalation_reboots_and_never_repartitions():
    src = inspect.getsource(readiness.monitor_docker_logs_and_restart)
    assert "COMMAND_PARTITION_PATH" not in src
    assert src.count("COMMAND_REBOOT_PATH") >= 2


def test_external_drive_check_never_feeds_the_escalation():
    src = inspect.getsource(readiness.monitor_docker_logs_and_restart)
    m = re.search(r"if check_external_drive\(\):\n\s*(\S.*)", src)
    assert m and m.group(1).strip() == "return"
    assert "restart_attempts = 4" not in src


def test_old_destructive_helpers_are_gone():
    assert not hasattr(readiness, "format_drive")
    assert not hasattr(readiness, "safe_run")
    src = inspect.getsource(readiness)
    assert 'rm", "-rf", "/uniondrive"' not in src


# ---------------------------------------------------------------------------
# One-shot storage-access trigger
# ---------------------------------------------------------------------------

@pytest.fixture
def trigger_env(monkeypatch, tmp_path):
    fula_sh = tmp_path / "fula.sh"
    rev_file = tmp_path / "rev"
    calls = []

    def fake_run(cmd, **kw):
        calls.append(cmd)
        return subprocess.CompletedProcess(cmd, 0, stdout=b"", stderr=b"")

    monkeypatch.setattr(readiness, "FULA_PATH", str(tmp_path))
    monkeypatch.setattr(readiness, "STORAGE_ACCESS_REV_FILE", str(rev_file))
    monkeypatch.setattr(readiness, "_last_storage_access_attempt", 0.0)
    monkeypatch.setattr(readiness, "fula_start_in_progress", lambda: False)
    monkeypatch.setattr(readiness, "_append_event", lambda *a, **k: None)
    monkeypatch.setattr(readiness.subprocess, "run", fake_run)
    return fula_sh, rev_file, calls


def test_trigger_runs_storage_access_when_rev_changes(trigger_env):
    fula_sh, rev_file, calls = trigger_env
    fula_sh.write_text("#!/bin/bash\nSTORAGE_ACCESS_REV=2\n")
    assert readiness.apply_storage_access_rev() is True
    assert calls and calls[0][-1] == "storage-access"
    assert calls[0][1:5] == ["timeout", "-k", "10", "120"]


def test_trigger_is_a_noop_when_rev_already_applied(trigger_env):
    fula_sh, rev_file, calls = trigger_env
    fula_sh.write_text("STORAGE_ACCESS_REV=2\n")
    rev_file.write_text("2\n")
    assert readiness.apply_storage_access_rev() is False
    assert calls == []


def test_trigger_ignores_fula_sh_without_a_rev(trigger_env):
    fula_sh, _, calls = trigger_env
    fula_sh.write_text("#!/bin/bash\necho old fula.sh\n")
    assert readiness.apply_storage_access_rev() is False
    assert calls == []


def test_trigger_waits_for_a_running_fula_start(trigger_env, monkeypatch):
    fula_sh, _, calls = trigger_env
    fula_sh.write_text("STORAGE_ACCESS_REV=2\n")
    monkeypatch.setattr(readiness, "fula_start_in_progress", lambda: True)
    assert readiness.apply_storage_access_rev() is False
    assert calls == []


def test_trigger_retries_at_most_hourly(trigger_env):
    fula_sh, _, calls = trigger_env
    fula_sh.write_text("STORAGE_ACCESS_REV=2\n")
    assert readiness.apply_storage_access_rev() is True
    assert readiness.apply_storage_access_rev() is False   # marker still missing, but rate-limited
    assert len(calls) == 1


def test_trigger_never_raises(trigger_env, monkeypatch):
    fula_sh, _, _ = trigger_env
    fula_sh.write_text("STORAGE_ACCESS_REV=2\n")
    def boom(*a, **k):
        raise subprocess.TimeoutExpired("fula.sh", 150)
    monkeypatch.setattr(readiness.subprocess, "run", boom)
    assert readiness.apply_storage_access_rev() is False
