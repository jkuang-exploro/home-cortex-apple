#!/usr/bin/env python3
"""Issue a session-only DEVICE invitation for the operator's persistent phone profile.

Body creation/association and the provisioner's exact body grant are separate,
explicit operator setup. This helper never creates a new body on regeneration.
"""
import json
import os
import re
import shlex
import subprocess
from datetime import datetime
from pathlib import Path


def main():
    os.umask(0o077)
    directory = Path(__file__).resolve().parents[1] / ".local/provisioning"
    directory.mkdir(mode=0o700, parents=True, exist_ok=True)
    directory.chmod(0o700)
    profile = directory / "iphone-embodiment.json"
    if not profile.exists():
        raise SystemExit("First create the persistent phone profile/body and exact operator grant; see README's iPhone embodiment section.")
    body = json.loads(profile.read_text())["id"]
    if not re.fullmatch(r"embodiment:[A-Za-z0-9_-]+", body):
        raise SystemExit("Invalid persistent embodiment ID.")
    output = directory / "iphone-device-invitation.json"
    if output.exists():
        raise SystemExit("Remove consumed/expired DEVICE invitation copies first. Keep iphone-embodiment.json.")
    server = "jkuang@192.168.68.59"
    remote = "/home/jkuang/.local/share/home-cortex/client-interface/provisioning/iphone-device-invitation.json"
    arguments = [".venv/bin/python", "-m", "scripts.maintenance.client_interface", "invite-device",
        "--root", "/home/jkuang/.local/share/home-cortex/client-interface", "--embodiment-id", body,
        "--endpoint", "https://192.168.68.59:8443", "--output", remote]
    command = "cd /home/jkuang/Workspace/home-cortex && PYTHONPATH=src " + shlex.join(arguments)
    subprocess.run(["ssh", "-o", "BatchMode=yes", server, command], check=True)
    subprocess.run(["scp", "-o", "BatchMode=yes", server + ":" + remote, str(output)], check=True)
    output.chmod(0o600)
    invitation = json.loads(output.read_text())
    if (invitation.get("purpose") != "DEVICE" or invitation.get("embodiment_id") != body
            or invitation.get("server_endpoint") != "https://192.168.68.59:8443"
            or invitation.get("grants") != [{"embodiment_id":body,"verb":"session","capability":None}]):
        output.unlink()
        raise SystemExit("Unexpected DEVICE invitation authority; do not import it.")
    expires = datetime.fromisoformat(invitation["expires_at"].replace("Z", "+00:00")).astimezone()
    print("DEVICE invitation ready: " + str(output))
    print("Expires: " + expires.strftime("%Y-%m-%d %H:%M:%S %Z"))
    print("AirDrop to iPhone Files. Home Cortex → gear → This iPhone → Enable as Embodiment → Import DEVICE invitation.")
    print("Remove invitation copies after enrollment; retain the persistent profile.")


if __name__ == "__main__":
    main()
