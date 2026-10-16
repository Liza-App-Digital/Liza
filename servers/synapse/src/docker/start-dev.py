#!/usr/bin/env python3
"""
Скрипт запуска для dev версии Synapse с hot reload.
Основан на официальном start.py, но с поддержкой editable install.
"""

import fcntl
import os
import shutil
import subprocess
import sys
from contextlib import contextmanager
from pathlib import Path

def copy_rust_module(
    rust_backup=Path("/synapse_rust.abi3.so.bak"),
    rust_target=Path("/editable-src/synapse/synapse_rust.abi3.so"),
):
    """Копирует скомпилированный Rust модуль в editable источники.

    Только через временный файл + os.replace (новый inode). Целевой .so в
    общем /editable-src загружен (mmap) в работающие Synapse соседних
    контейнеров; copy2 поверх него усекал тот же inode, ядро сбрасывало
    у соседей страницы с уже исправленными загрузчиком адресами, и они
    падали SIGSEGV на первом вызове в Rust (14–15.10: ~150 падений, у тихих
    инстансов — ровно через 30 мин, на истечении TTL кэша; GlitchTip #2111).
    """
    if rust_backup.exists():
        print(f"Copying Rust module from {rust_backup} to {rust_target}")
        tmp = rust_target.with_name(f".{rust_target.name}.{os.getpid()}.tmp")
        try:
            shutil.copy2(rust_backup, tmp)
            os.replace(tmp, rust_target)
        finally:
            tmp.unlink(missing_ok=True)
    else:
        print("Warning: Rust module backup not found, may need recompilation")

@contextmanager
def editable_src_lock():
    """Сериализует правку /editable-src между контейнерами, шарящими
    один volume (prod + prod-sync). Без этого параллельный рестарт обоих
    вызывает гонку двух `pip install -e` за один и тот же .egg-info и
    Rust .so → ABI mismatch → SIGSEGV (см. SIGSEGV_INVESTIGATION.md,
    инцидент 2026-07-04: docker compose restart synapse-prod synapse-prod-sync
    одной командой уронил оба процесса на несколько минут)."""
    lock_path = Path("/editable-src/.start-dev.lock")
    with open(lock_path, "w") as lock_file:
        print("Waiting for /editable-src lock...")
        fcntl.flock(lock_file, fcntl.LOCK_EX)
        try:
            print("Acquired /editable-src lock")
            yield
        finally:
            fcntl.flock(lock_file, fcntl.LOCK_UN)

def check_poetry_lock():
    """Проверяет, изменился ли poetry.lock."""
    current_lock = Path("/editable-src/poetry.lock")
    backup_lock = Path("/poetry.lock.bak")
    
    if backup_lock.exists() and current_lock.exists():
        if backup_lock.read_text() != current_lock.read_text():
            print("Warning: poetry.lock has changed, dependencies may be out of sync")
            print("Consider rebuilding the container")

def main():
    """Основная функция запуска."""
    print("🚀 Starting Synapse in development mode...")

    # Меняем рабочую директорию на editable источники
    os.chdir("/editable-src")

    # Копирование Rust-модуля и pip install -e пишут в общий volume
    # /editable-src — под локом, т.к. prod и prod-sync монтируют один
    # и тот же хостовый каталог и могут стартовать одновременно.
    with editable_src_lock():
        # Копируем Rust модуль
        copy_rust_module()

        # Проверяем poetry.lock
        check_poetry_lock()

        # Пересоздаём editable install metadata (egg-info) чтобы
        # синхронизировать с volume mount — без этого SIGSEGV при
        # рассинхронизации .egg-info между образом и хостом.
        # maturin нужен как build backend (pyproject.toml использует maturin);
        # с --no-build-isolation он должен быть в окружении заранее.
        print("Ensuring maturin is available...")
        subprocess.run(
            [sys.executable, "-m", "pip", "install", "maturin>=1.0,<2.0", "-q"],
            timeout=120,
        )
        print("Syncing editable install metadata...")
        subprocess.run(
            [sys.executable, "-m", "pip", "install", "-e", ".[all]",
             "--no-deps", "--no-build-isolation", "-q"],
            cwd="/editable-src",
            timeout=120,
        )

    # Включаем faulthandler для диагностики SIGSEGV
    os.environ["PYTHONFAULTHANDLER"] = "1"

    # Если переданы аргументы (через CMD в docker-compose), используем их.
    # CMD формат: ["python", "-m", "synapse.app.generic_worker", "--config-path=..."]
    # Пропускаем "python" из CMD, т.к. мы сами вызываем sys.executable.
    if len(sys.argv) > 1:
        cmd_args = sys.argv[1:]
        if cmd_args and cmd_args[0] in ("python", "python3"):
            cmd_args = cmd_args[1:]
        args = [sys.executable, "-X", "faulthandler"] + cmd_args
    else:
        args = [
            sys.executable, "-X", "faulthandler",
            "-m", "synapse.app.homeserver",
            "--config-path", "/config/homeserver.yaml",
        ]

    print(f"Starting synapse with args {' '.join(args[1:])}")

    # Выполняем команду
    os.execv(sys.executable, args)

if __name__ == "__main__":
    main()