"""Samba LAN access (fula.sh setup_storage_access + firewall.sh).

Static checks run everywhere. The subprocess checks need bash + awk and run on
Linux (devices, Linux dev machines): they execute firewall.sh against stub
iptables binaries and the real render_smb_conf / setup_storage_access code.
"""

import os
import re
import shutil
import subprocess
import sys

import pytest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LINUX_DIR = os.path.join(ROOT, "docker", "fxsupport", "linux")
FULA_SH = os.path.join(LINUX_DIR, "fula.sh")
FIREWALL_SH = os.path.join(LINUX_DIR, "firewall.sh")
FIXTURES = os.path.join(os.path.dirname(os.path.abspath(__file__)), "fixtures")

needs_bash = pytest.mark.skipif(
    sys.platform == "win32" or shutil.which("bash") is None or shutil.which("awk") is None,
    reason="needs a Linux bash + awk",
)


def _read(path):
    with open(path, encoding="utf-8") as f:
        return f.read()


def _function_body(src, name):
    """Return the text of a bash function from `name() {` to its closing `}`."""
    m = re.search(r"^%s\(\) \{\n(.*?)^\}\n" % re.escape(name), src, re.S | re.M)
    assert m, "function %s not found" % name
    return m.group(1)


# --------------------------------------------------------------------------
# Static checks (all platforms)
# --------------------------------------------------------------------------

def test_storage_access_rev_is_a_literal_line():
    # readiness-check.py parses this exact form to re-apply after an OTA.
    assert re.search(r"^STORAGE_ACCESS_REV=[0-9]+$", _read(FULA_SH), re.M)


def test_share_is_login_only():
    body = _function_body(_read(FULA_SH), "render_smb_conf")
    assert "map to guest = never" in body
    assert "guest ok = no" in body
    assert "valid users = ${nas_user}" in body
    assert "guest ok = yes" not in _read(FULA_SH)


def test_setup_storage_access_never_blocks_or_restarts():
    src = _read(FULA_SH)
    body = _function_body(src, "_setup_storage_access_locked")
    assert "uniondrive_is_mergerfs" in body           # mount guard first
    assert "testparm -s" in body                       # validate before swapping
    assert "reload --no-block smbd" in body            # reload, never restart
    for forbidden in ("systemctl restart smbd", "apt install", "apt-get", "apt update",
                      "chmod 777 -R", "chmod -R", "chown -R", "while [ ! -d"):
        assert forbidden not in body, forbidden
    assert "flock -n" in _function_body(src, "setup_storage_access")


def test_smbd_dropin_is_samba_scoped_and_bounded():
    body = _function_body(_read(FULA_SH), "install_smbd_dropin")
    for needle in ("After=uniondrive.service", "PartOf=uniondrive.service",
                   "ExecCondition=", "fuse.mergerfs", "TimeoutStopSec=15", "KillMode=mixed"):
        assert needle in body, needle
    assert "RequiresMountsFor" not in body


def test_packages_are_dispatched_not_installed_inline():
    body = _function_body(_read(FULA_SH), "dispatch_samba_pkgs")
    assert "systemd-run --no-block" in body
    assert "-mmin -1440" in body                      # at most one attempt per 24 h


def test_storage_access_branch_and_restart_call_are_non_fatal():
    src = _read(FULA_SH)
    assert re.search(r'^"storage-access"\)\n(?:.*\n){0,4}\s*setup_storage_access \|\|', src, re.M)
    assert re.search(r"^\s*setup_storage_access \|\| \{", src, re.M)  # restart() call site


def test_firewall_samba_discovery_rules_present():
    fw = _read(FIREWALL_SH)
    assert re.search(r'iptables -A "\$CHAIN" -p igmp -j ACCEPT', fw)
    assert "for port in 137 138 3702; do" in fw
    assert '--dport 5357' in fw
    assert "--dport 5353" not in fw                    # mDNS deliberately not opened (kubo)
    # The discovery block must sit after the support-tunnel DROP.
    assert fw.index('-i support -j DROP') < fw.index("for port in 137 138 3702; do")


# --------------------------------------------------------------------------
# Subprocess checks (Linux)
# --------------------------------------------------------------------------

def _run_firewall_with_stubs(tmp_path, script_text):
    """Run a firewall.sh variant with logging iptables/ip6tables stubs; return
    the (v4, v6) argument lists in call order."""
    bindir = tmp_path / "bin"
    bindir.mkdir()
    for tool in ("iptables", "ip6tables"):
        stub = bindir / tool
        stub.write_text('#!/bin/sh\necho "$*" >> "%s/%s.log"\nexit 0\n' % (tmp_path, tool))
        stub.chmod(0o755)
    script = tmp_path / "firewall.sh"
    script.write_text(script_text.replace("/home/pi/fula.sh.log", str(tmp_path / "fw.log")))
    env = dict(os.environ, PATH="%s:%s" % (bindir, os.environ.get("PATH", "")))
    subprocess.run(["bash", str(script)], env=env, check=True, capture_output=True, timeout=60)

    def lines(tool):
        p = tmp_path / ("%s.log" % tool)
        return p.read_text().splitlines() if p.exists() else []
    return lines("iptables"), lines("ip6tables")


def _appended(calls, chain):
    return [c for c in calls if c.startswith("-A %s " % chain)]


# firewall.sh exactly as it was before the Samba-discovery rules were added
# (frozen, so this test stays meaningful after the change is merged).
FIREWALL_PRE_SAMBA = os.path.join(FIXTURES, "firewall.sh.pre-samba")
RFC1918 = ("192.168.0.0/16", "10.0.0.0/8", "172.16.0.0/12")
EXPECTED_V4_ADDED = (
    ["-A FULA_FIREWALL -p igmp -j ACCEPT"]
    + ["-A FULA_FIREWALL -p udp --dport %d -s %s -j ACCEPT" % (port, src)
       for port in (137, 138, 3702) for src in RFC1918]
    + ["-A FULA_FIREWALL -p tcp --dport 5357 -s %s -j ACCEPT" % src for src in RFC1918]
)
EXPECTED_V6_ADDED = [
    "-A FULA_FIREWALL_V6 -p %s --dport %d -s %s -j ACCEPT" % (proto, port, src)
    for src in ("fe80::/10", "fc00::/7")
    for proto, port in (("tcp", 445), ("tcp", 5357), ("udp", 3702))
]


@needs_bash
def test_firewall_changes_are_strictly_additive(tmp_path):
    """Every pre-existing rule is still emitted, in the same order; exactly the
    expected ACCEPT rules are added, after the support-tunnel DROP (so they
    never widen tunnel access) and before the final DROP."""
    (tmp_path / "new").mkdir()
    (tmp_path / "old").mkdir()
    new_v4, new_v6 = _run_firewall_with_stubs(tmp_path / "new", _read(FIREWALL_SH))
    old_v4, old_v6 = _run_firewall_with_stubs(tmp_path / "old", _read(FIREWALL_PRE_SAMBA))

    for old, new, chain, expected in ((old_v4, new_v4, "FULA_FIREWALL", EXPECTED_V4_ADDED),
                                      (old_v6, new_v6, "FULA_FIREWALL_V6", EXPECTED_V6_ADDED)):
        old_rules, new_rules = _appended(old, chain), _appended(new, chain)
        it = iter(new_rules)
        assert all(rule in it for rule in old_rules), "a pre-existing %s rule changed or moved" % chain
        added = [r for r in new_rules if r not in old_rules]
        assert sorted(added) == sorted(expected), added
        final_drop = new_rules.index("-A %s -j DROP" % chain)
        support_drop = new_rules.index("-A %s -i support -j DROP" % chain)
        for rule in added:
            pos = new_rules.index(rule)
            assert pos < final_drop, rule
            if "--dport" in rule:
                assert pos > support_drop, rule


def _render(input_text, share="/uniondrive/fxblox", user="fxnas"):
    cmd = 'source "$1" >/dev/null 2>&1; set +e; render_smb_conf "$2" "$3"'
    p = subprocess.run(["bash", "-c", cmd, "bash", FULA_SH, share, user],
                       input=input_text, capture_output=True, text=True, timeout=30)
    assert p.returncode == 0, p.stderr
    return p.stdout


@needs_bash
@pytest.mark.parametrize("fixture", ["smb.conf.noble-default", "smb.conf.legacy-fula"])
def test_render_smb_conf_replaces_legacy_share_and_is_idempotent(fixture):
    src = _read(os.path.join(FIXTURES, fixture))
    once = _render(src)
    assert _render(once) == once                               # idempotent
    assert once.count("[SharedFolder]") == 1
    assert "guest ok = yes" not in once
    assert "map to guest = never" in once
    # Ubuntu's own content survives byte-for-byte (minus trailing blank lines).
    default = _read(os.path.join(FIXTURES, "smb.conf.noble-default")).rstrip("\n")
    assert once.startswith(default + "\n")


@needs_bash
def test_render_smb_conf_keeps_sections_after_a_legacy_share():
    src = "[global]\n   workgroup = WG\n\n[SharedFolder]\npath = /x\nguest ok = yes\n\n[other]\n   path = /y\n"
    out = _render(src)
    assert "[other]\n   path = /y\n" in out
    assert out.count("[SharedFolder]") == 1 and "guest ok = yes" not in out


@needs_bash
@pytest.mark.skipif(shutil.which("testparm") is None, reason="samba testparm not installed")
def test_rendered_config_passes_testparm(tmp_path):
    out = tmp_path / "smb.conf"
    out.write_text(_render(_read(os.path.join(FIXTURES, "smb.conf.legacy-fula"))))
    p = subprocess.run(["testparm", "-s", str(out)], capture_output=True, text=True, timeout=30)
    assert p.returncode == 0, p.stderr
    assert re.search(r"map to guest = Never", p.stdout)


@needs_bash
def test_setup_storage_access_skips_when_uniondrive_is_not_mergerfs(tmp_path):
    mounts = tmp_path / "mounts"
    mounts.write_text("/dev/mmcblk0p1 / ext4 rw 0 0\n/dev/sda1 /uniondrive ext4 rw 0 0\n")
    conf = tmp_path / "smb.conf"
    conf.write_text("[global]\n")
    env = dict(os.environ,
               FULA_PROC_MOUNTS=str(mounts), FULA_SMB_CONF=str(conf),
               FULA_STORAGE_LOCK=str(tmp_path / "lock"),
               FULA_STORAGE_REV_FILE=str(tmp_path / "rev"))
    cmd = ('source "$1" >/dev/null 2>&1; set +e; FULA_LOG_PATH=/dev/null; '
           'sudo() { "$@"; }; setup_storage_access; echo "rc=$?"')
    p = subprocess.run(["bash", "-c", cmd, "bash", FULA_SH], env=env,
                       capture_output=True, text=True, timeout=60)
    assert "rc=0" in p.stdout, p.stdout + p.stderr
    assert conf.read_text() == "[global]\n"            # untouched
    assert not (tmp_path / "rev").exists()             # no success marker


@needs_bash
def test_uniondrive_is_mergerfs_reads_top_of_stack(tmp_path):
    def check(text):
        mounts = tmp_path / "m"
        mounts.write_text(text)
        cmd = 'source "$1" >/dev/null 2>&1; set +e; uniondrive_is_mergerfs; echo "rc=$?"'
        p = subprocess.run(["bash", "-c", cmd, "bash", FULA_SH],
                           env=dict(os.environ, FULA_PROC_MOUNTS=str(mounts)),
                           capture_output=True, text=True, timeout=30)
        return "rc=0" in p.stdout
    assert check("/media/pi/sda1 /uniondrive fuse.mergerfs rw 0 0\n")
    assert not check("/dev/mmcblk0p1 / ext4 rw 0 0\n")
    # A non-mergerfs layer stacked on top must be rejected.
    assert not check("/media/pi/sda1 /uniondrive fuse.mergerfs rw 0 0\n/dev/sdb1 /uniondrive ext4 rw 0 0\n")
