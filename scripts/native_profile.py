"""Keep development applications separate from the installed product."""

from dataclasses import dataclass
from pathlib import Path
import hashlib
import re


@dataclass(frozen=True)
class NativeProfile:
    name: str
    bundle_id: str
    defaults_domain: str
    app_name: str
    app: Path

    @property
    def production(self):
        return self.name == "production"


def native_profile(root, name="development", output=None, test_id=None):
    root = Path(root).resolve()
    if name not in ("production", "development", "smoke"):
        raise ValueError("Unknown native build profile.")
    if name == "production":
        if test_id:
            raise ValueError("A production build cannot have a test ID.")
        app_name, bundle_id, domain = "Mooji Cut", "dev.moojicut.native", "dev.mooncap.native.preferences"
    else:
        test_id = test_id or hashlib.sha256(str(root).encode()).hexdigest()[:10]
        if not re.fullmatch(r"[a-z0-9]+(?:-[a-z0-9]+)*", test_id):
            raise ValueError("Test ID must contain lowercase letters, numbers and optional hyphens.")
        bundle_id = "dev.moojicut.test." + name + "." + test_id
        domain = bundle_id + ".preferences"
        app_name = "Mooji Cut Test " + test_id
    app = Path(output).expanduser().absolute() if output else root / "dist" / (name + ".noindex") / (app_name + ".app")
    if app.suffix != ".app" or app.name != app_name + ".app":
        raise ValueError("App output must end with " + app_name + ".app")
    # Builders never install, even if a caller accidentally points at an existing symlink.
    resolved = app.resolve()
    if resolved.is_relative_to(Path("/Applications")) or resolved.is_relative_to(Path.home() / "Applications"):
        raise ValueError("Build output must not be an installed application. Build a ZIP, then update explicitly.")
    if app.is_symlink():
        raise ValueError("App output must not be a symlink.")
    return NativeProfile(name, bundle_id, domain, app_name, resolved)
