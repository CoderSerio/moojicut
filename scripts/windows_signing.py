"""Sign and verify portable Windows binaries with an explicit Authenticode identity."""
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import struct
import subprocess

_CERT_ENV = "MOOJICUT_WINDOWS_SIGN_CERT_SHA1"
_DLIB_ENV = "MOOJICUT_WINDOWS_SIGN_DLIB"
_METADATA_ENV = "MOOJICUT_WINDOWS_SIGN_METADATA"
_SIGNTOOL_ENV = "MOOJICUT_SIGNTOOL"
_TIMESTAMP_URL = "https://timestamp.acs.microsoft.com"
_PE_SUFFIXES = {".exe", ".dll", ".ocx", ".pyd", ".sys", ".drv"}
_THUMBPRINT = re.compile(r"[0-9A-Fa-f]{40}")

# SignTool verifies the embedded signature before this script reads its
# publisher. Get-AuthenticodeSignature may report a locally installed catalog
# instead of the shipped embedded signature for the same file.
_EMBEDDED_PUBLISHERS = """
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.UTF8Encoding]::new()
$paths = [Console]::In.ReadToEnd() | ConvertFrom-Json
$publishers = @(
    foreach ($path in $paths) {
        $certificate = [Security.Cryptography.X509Certificates.X509Certificate]::CreateFromSignedFile($path)
        try {
            @{signer = $certificate.Subject; thumbprint = $certificate.GetCertHashString()}
        } finally {
            $certificate.Dispose()
        }
    }
)
ConvertTo-Json -InputObject $publishers -Compress
"""


def _link(path):
    return path.is_symlink() or (hasattr(path, "is_junction") and path.is_junction())


def _embedded_certificate(path):
    """Return None for data files, False for unsigned PEs, and True for embedded signatures."""
    def invalid():
        return RuntimeError("Invalid PE header or certificate table: " + str(path))

    with path.open("rb") as file:
        dos = file.read(64)
        if dos[:2] != b"MZ":
            if path.suffix.lower() in _PE_SUFFIXES:
                raise invalid()
            return None
        if len(dos) != 64:
            raise invalid()
        pe = struct.unpack_from("<I", dos, 60)[0]
        file.seek(pe)
        header = file.read(24)
        if len(header) != 24 or header[:4] != b"PE\0\0":
            raise invalid()
        optional_size = struct.unpack_from("<H", header, 20)[0]
        optional = file.read(optional_size)
        if len(optional) != optional_size or len(optional) < 2:
            raise invalid()
        magic = struct.unpack_from("<H", optional)[0]
        directories = {0x10B: 92, 0x20B: 108}.get(magic)
        if directories is None or len(optional) < directories + 4:
            raise invalid()
        count = struct.unpack_from("<I", optional, directories)[0]
        if count < 5:
            return False
        security = directories + 4 + 4 * 8
        if len(optional) < security + 8:
            raise invalid()
        offset, size = struct.unpack_from("<II", optional, security)
        if not offset and not size:
            return False
        if offset < pe + 24 + optional_size or size < 8 or offset + size > os.fstat(file.fileno()).st_size:
            raise invalid()
        return True


def _files(directory):
    if _link(directory) or not directory.is_dir():
        raise RuntimeError("Invalid Windows signing directory: " + str(directory))
    entries = {}
    for path in sorted(directory.rglob("*")):
        if _link(path):
            raise RuntimeError("A Windows signing directory contains a link: " + str(path))
        if path.is_dir():
            continue
        if not path.is_file():
            raise RuntimeError("A Windows signing directory contains a non-file: " + str(path))
        embedded = _embedded_certificate(path)
        if embedded is not None:
            entries[path.relative_to(directory).as_posix()] = (path, embedded)
    if not entries:
        raise RuntimeError("The Windows signing directory contains no PE binaries.")
    return entries


def _digest(path):
    with path.open("rb") as file:
        return hashlib.file_digest(file, "sha256").hexdigest()


class WindowsSigner:
    def __init__(self, signtool, powershell, provider, thumbprint, env, execute):
        self.signtool = signtool
        self.powershell = powershell
        self.provider = provider
        self.thumbprint = thumbprint
        self.env = dict(env)
        self.execute = execute

    @classmethod
    def from_env(cls, env, *, execute=subprocess.run):
        """Select the certificate in CurrentUser\\My, or an Azure Artifact Signing dlib."""
        settings = {key.upper(): value for key, value in env.items()}
        thumbprint = settings.get(_CERT_ENV, "").strip()
        dlib = settings.get(_DLIB_ENV, "").strip()
        metadata = settings.get(_METADATA_ENV, "").strip()
        if thumbprint and (dlib or metadata):
            raise RuntimeError("Select one Windows signing provider.")
        if thumbprint:
            if not _THUMBPRINT.fullmatch(thumbprint):
                raise RuntimeError(_CERT_ENV + " must contain a 40-digit SHA-1 certificate thumbprint.")
            thumbprint = thumbprint.upper()
            provider = ["/s", "My", "/sha1", thumbprint]
        elif dlib or metadata:
            if not dlib or not metadata:
                raise RuntimeError(f"Configure both {_DLIB_ENV} and {_METADATA_ENV}.")
            if not Path(dlib).is_file() or not Path(metadata).is_file():
                raise RuntimeError("Windows signing dlib or metadata file is missing.")
            provider = ["/dlib", str(Path(dlib).resolve()), "/dmdf", str(Path(metadata).resolve())]
        else:
            raise RuntimeError(f"Configure {_CERT_ENV}, or {_DLIB_ENV} and {_METADATA_ENV}, to sign for Windows.")
        tool = settings.get(_SIGNTOOL_ENV, "")
        signtool = str(Path(tool).resolve()) if tool and Path(tool).is_file() else None
        if not tool:
            signtool = shutil.which("signtool.exe", path=settings.get("PATH", ""))
        if not signtool:
            # Visual Studio's developer environment exposes the chosen SDK,
            # even on versions that do not add SDK tools to PATH.
            sdk_bin = settings.get("WINDOWSSDKVERBINPATH", "")
            if not tool and sdk_bin and (Path(sdk_bin) / "x64/signtool.exe").is_file():
                signtool = str(Path(sdk_bin).resolve() / "x64/signtool.exe")
            else:
                raise RuntimeError(f"Install the Windows SDK SignTool or set {_SIGNTOOL_ENV} to signtool.exe.")
        system = Path(settings.get("SYSTEMROOT", r"C:\Windows"))
        powershell = system / "System32/WindowsPowerShell/v1.0/powershell.exe"
        return cls(signtool, str(powershell), provider, thumbprint or None, env, execute)

    def _run(self, command, action, *, input_data=None, timeout=240):
        # Use only Windows PowerShell's own modules, even from a pwsh 7 parent.
        environment = {key: value for key, value in self.env.items() if key.casefold() != "psmodulepath"}
        try:
            result = self.execute(command, input=input_data, env=environment, capture_output=True, timeout=timeout)
        except (OSError, subprocess.TimeoutExpired) as error:
            raise RuntimeError(f"{action} could not run ({type(error).__name__}).") from None
        if result.returncode:
            # Signing-provider diagnostics can contain account/identity data.
            raise RuntimeError(f"{action} failed (exit {result.returncode}).")
        return result.stdout

    def _apply(self, arguments, paths, action):
        # Batch to stay below Windows' command-line limit and keep a timeout
        # bounded even if a signer does not respond.
        for start in range(0, len(paths), 12):
            batch = paths[start:start + 12]
            self._run([self.signtool, *arguments, *map(str, batch)],
                      f"{action} ({', '.join(path.name for path in batch)})")

    def _publishers(self, paths):
        payload = json.dumps([str(path) for path in paths]).encode("ascii")
        response = self._run(
            [self.powershell, "-NoLogo", "-NoProfile", "-NonInteractive", "-Command", _EMBEDDED_PUBLISHERS],
            "Read verified Authenticode publishers", input_data=payload,
        )
        try:
            data = json.loads(response)
        except (TypeError, ValueError):
            raise RuntimeError("Windows returned invalid Authenticode publisher metadata.") from None
        if (not isinstance(data, list) or len(data) != len(paths) or
                any(not isinstance(row, dict) or not isinstance(row.get("signer"), str) or
                    not row["signer"] or not isinstance(row.get("thumbprint"), str) or
                    not _THUMBPRINT.fullmatch(row["thumbprint"]) for row in data)):
            raise RuntimeError("Windows returned incomplete Authenticode publisher metadata.")
        return [{**row, "thumbprint": row["thumbprint"].upper()} for row in data]

    def sign_bundle(self, directory):
        """Sign unsigned binaries in place, leaving verified vendor signatures byte-identical."""
        directory = Path(directory).absolute()
        entries = _files(directory)
        unsigned = [path for path, embedded in entries.values() if not embedded]
        vendor = [path for path, embedded in entries.values() if embedded]
        preserved = {path: _digest(path) for path in vendor}
        self._apply(["verify", "/pa"], vendor, "Verify existing embedded Authenticode signatures")
        self._apply(["sign", "/fd", "SHA256", "/tr", _TIMESTAMP_URL, "/td", "SHA256", *self.provider],
                    unsigned, "Sign portable Windows binaries")
        if any(not _embedded_certificate(path) for path in unsigned):
            raise RuntimeError("SignTool did not embed a signature in every requested Windows binary.")
        self._apply(["verify", "/pa", "/tw"], unsigned, "Verify timestamped Authenticode signatures")
        if any(_digest(path) != expected for path, expected in preserved.items()):
            raise RuntimeError("A pre-signed Windows dependency changed during signing.")
        publishers = self._publishers([path for path, _ in entries.values()])
        receipt = {}
        publisher_subjects = set()
        for (relative, (path, embedded)), identity in zip(entries.items(), publishers):
            if not embedded:
                if self.thumbprint and identity["thumbprint"] != self.thumbprint:
                    raise RuntimeError("A new signature does not match the selected certificate: " + relative)
                publisher_subjects.add(identity["signer"])
            receipt[relative] = {**identity, "sha256": _digest(path), "timestamped": None if embedded else True,
                                 "source": "vendor" if embedded else "publisher"}
        if len(publisher_subjects) > 1:
            raise RuntimeError("New Windows signatures do not identify one publisher.")
        return receipt

    def verify_bundle(self, directory, receipt):
        """Reject changed, unauthenticated, or uncovered binaries before or after archiving."""
        entries = _files(Path(directory).absolute())
        if not isinstance(receipt, dict) or entries.keys() != receipt.keys():
            raise RuntimeError("Windows signing receipt does not cover the complete binary inventory.")
        vendor, publisher = [], []
        for relative, (path, embedded) in entries.items():
            record = receipt[relative]
            if not isinstance(record, dict):
                raise RuntimeError("Invalid Windows signing receipt: " + relative)
            source = record.get("source")
            if not embedded or _digest(path) != record.get("sha256") or source not in ("vendor", "publisher"):
                raise RuntimeError("Windows binary differs from the verified signing receipt: " + relative)
            if source == "publisher":
                if record.get("timestamped") is not True or (
                    self.thumbprint and record.get("thumbprint") != self.thumbprint
                ):
                    raise RuntimeError("Invalid publisher signing receipt: " + relative)
                publisher.append(path)
            else:
                vendor.append(path)
        self._apply(["verify", "/pa"], vendor, "Verify vendor Authenticode signatures")
        self._apply(["verify", "/pa", "/tw"], publisher, "Verify publisher Authenticode signatures")
        identities = self._publishers([path for path, _ in entries.values()])
        for relative, identity in zip(entries, identities):
            if any(receipt[relative].get(key) != identity[key] for key in ("signer", "thumbprint")):
                raise RuntimeError("Windows signature differs from the verified signing receipt: " + relative)
