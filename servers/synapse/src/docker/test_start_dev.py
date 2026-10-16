"""Страж start-dev.py: копирование Rust-модуля не пишет в загруженный inode.

ledger:RL-synapse-rust-so-atomic-replace

Запуск: python3 -m pytest servers/synapse/src/docker/test_start_dev.py
"""

import importlib.util
import mmap
import os
from pathlib import Path

_spec = importlib.util.spec_from_file_location(
    "start_dev", Path(__file__).with_name("start-dev.py")
)
start_dev = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(start_dev)


def test_running_neighbour_mapping_is_not_overwritten(tmp_path):
    """AC:RL-synapse-rust-so-atomic-replace/1 — сосед, загрузивший .so,
    видит прежние байты; целевой путь указывает на новый inode с копией."""
    backup = tmp_path / "synapse_rust.abi3.so.bak"
    target = tmp_path / "synapse_rust.abi3.so"
    backup.write_bytes(b"NEW" * 4096)
    target.write_bytes(b"OLD" * 4096)
    old_inode = target.stat().st_ino

    with open(target, "rb") as f, mmap.mmap(f.fileno(), 0, prot=mmap.PROT_READ) as m:
        start_dev.copy_rust_module(backup, target)
        assert m[:3] == b"OLD"
        assert len(m) == 3 * 4096

    assert target.stat().st_ino != old_inode
    assert target.read_bytes() == backup.read_bytes()
    assert sorted(p.name for p in tmp_path.iterdir()) == [
        "synapse_rust.abi3.so",
        "synapse_rust.abi3.so.bak",
    ]


def test_missing_backup_leaves_target(tmp_path):
    target = tmp_path / "synapse_rust.abi3.so"
    target.write_bytes(b"OLD")
    start_dev.copy_rust_module(tmp_path / "absent.bak", target)
    assert target.read_bytes() == b"OLD"
