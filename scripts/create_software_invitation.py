#!/usr/bin/env python3
"""Create an operator-authorized invitation without printing its token.

The deployed provisioner must already have the null-body provision grant.
Existing invitation files are deliberately not overwritten.
"""
import json
import os
from datetime import datetime
from pathlib import Path
import subprocess


def main() -> None:
    os.umask(0o077)
    directory = Path(__file__).resolve().parents[1] / ".local" / "provisioning"
    directory.mkdir(parents=True, mode=0o700, exist_ok=True)
    directory.chmod(0o700)
    output = directory / "apple-invitation.json"
    if output.exists():
        raise SystemExit("Invitation file already exists. Remove consumed/expired copies before creating another.")
    server = "jkuang@home-cortex-0"
    remote = "/home/jkuang/.local/share/home-cortex/client-interface/provisioning/apple-invitation.json"
    command = (
        "cd /home/jkuang/Workspace/home-cortex && "
        "PYTHONPATH=src .venv/bin/python -m scripts.maintenance.client_interface "
        "invite-software --root /home/jkuang/.local/share/home-cortex/client-interface "
        "--output " + remote
    )
    subprocess.run(["ssh", "-o", "BatchMode=yes", server, command], check=True)
    subprocess.run(["scp", "-o", "BatchMode=yes", server + ":" + remote, str(output)], check=True)
    output.chmod(0o600)
    invitation = json.loads(output.read_text())
    if (invitation.get("purpose") != "CALLER" or invitation.get("embodiment_id") is not None
            or invitation.get("grants") != [{"embodiment_id": None, "verb": "session", "capability": None}]):
        raise SystemExit("Unexpected invitation authority. Do not import this file.")
    expiry = datetime.fromisoformat(invitation["expires_at"].replace("Z", "+00:00")).astimezone()
    print("Invitation ready: " + str(output))
    print("Expires: " + expiry.strftime("%Y-%m-%d %H:%M:%S %Z"))
    print("AirDrop to iPhone Files, open Home Cortex, and select Provision Client.")
    print("Delete invitation copies on phone, Mac, and server after enrollment.")


if __name__ == "__main__":
    main()
