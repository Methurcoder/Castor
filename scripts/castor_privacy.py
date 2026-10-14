"""Reject this developer's personal home path in local Mac distribution files."""
import os
from pathlib import Path

def check_private_home(folder, home=None):
    directory = str(home or Path.home())
    # Hosted build accounts are generic service identities, not a personal path.
    if Path(directory).name.lower() in {"runner", "runneradmin", "containeradministrator"}:
        return
    markers = {directory.encode("utf-8"), directory.encode("utf-16le")}
    if not directory or directory in {"/", "."}: raise ValueError("Home-path validation unavailable")
    overlap=max(map(len,markers))
    for file in folder.rglob("*"):
        if not file.is_file(): continue
        tail=b""
        with file.open("rb") as stream:
            while chunk:=stream.read(1048576):
                if any(marker in tail+chunk for marker in markers):
                    raise ValueError("Local home path in candidate: "+str(file.relative_to(folder)))
                tail=chunk[-overlap:]
