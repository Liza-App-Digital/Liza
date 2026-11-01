"""Независимая проверка публичного контракта Python и Node.js.

ledger:RL-miniapp-initdata-signature
"""
import importlib.util
import json
import pathlib
import shutil
import subprocess

import pytest

EXAMPLES = pathlib.Path(__file__).resolve().parents[3] / "liza-docs/static/examples/miniapp-initdata"
VECTOR = json.loads((EXAMPLES / "vector.json").read_text())
SPEC = importlib.util.spec_from_file_location("partner_initdata_verify", EXAMPLES / "verify.py")
PARTNER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(PARTNER)


def check_python(data):
    return PARTNER.verify(data["init_data"], data["public_key"], data["app_id"],
                          expected_key_id=data["key_id"], now=data["now"])


def check_javascript(data):
    node = shutil.which("node")
    if node is None:
        pytest.skip("Node.js недоступен: JS verifier не проверен")
    code = """
import {readFileSync} from 'node:fs';
const {verify} = await import(process.argv[1]);
const v = JSON.parse(readFileSync(0, 'utf8'));
try {
  console.log(JSON.stringify(verify(v.init_data,v.public_key,v.app_id,
    {expectedKeyId:v.key_id,now:v.now})));
} catch { process.exit(2); }
"""
    result = subprocess.run([node, "--input-type=module", "-e", code,
                             (EXAMPLES / "verify.mjs").as_uri()],
                            input=json.dumps(data), capture_output=True, text=True, timeout=10)
    if result.returncode == 2:
        raise ValueError("JS verifier rejected")
    assert result.returncode == 0, result.stderr
    return json.loads(result.stdout)


# AC:RL-miniapp-initdata-signature/3
@pytest.mark.parametrize("check", [check_python, check_javascript])
def test_fixed_public_vector_accepted_independently(check):
    result = check(VECTOR)
    assert result == {"app_id": "partner-demo", "user": {
        "id": "opaque-app-user", "display_name": "Тестовый пользователь"},
        "start_param": "order_123", "room_id": "!demo:example.test"}


# AC:RL-miniapp-initdata-signature/4
@pytest.mark.parametrize("check", [check_python, check_javascript])
@pytest.mark.parametrize("case", ["tamper", "duplicate", "expired", "future", "app", "key", "public_key"])
def test_invalid_input_rejected_by_both_examples(check, case):
    data = dict(VECTOR)
    if case == "tamper":
        data["init_data"] = data["init_data"].replace("order_123", "order_456")
    elif case == "duplicate":
        data["init_data"] += "&auth_date=1700000000"
    elif case == "expired":
        data["now"] = 1700000301
    elif case == "future":
        data["now"] = 1699999969
    elif case == "app":
        data["app_id"] = "other-app"
    elif case == "key":
        data["key_id"] = "other-key"
    elif case == "public_key":
        data["public_key"] = "A" * 43
    with pytest.raises(ValueError):
        check(data)
