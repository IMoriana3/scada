"""Read-only consumer of 06_PLANT IdentityRegistry snapshots.

Only published packages may be used in production. Source-local locators are
looked up in explicit, time-valid bindings; they never generate identities.
"""
import hashlib
import json
import os
from pathlib import Path
import subprocess
from datetime import datetime, timezone
from zoneinfo import ZoneInfo

import yaml


class IdentityUnavailable(ValueError):
    pass


def _active(record, at):
    start = datetime.fromisoformat(record["valid_from"])
    end = datetime.fromisoformat(record["valid_to"]) if record.get("valid_to") else None
    return start <= at and (end is None or at < end)


class PlantIdentity:
    def __init__(self, package_dir, config, *, development=False, repository=None,
                 published_commit=None):
        directory = Path(package_dir).resolve()
        manifest = yaml.safe_load((directory / "manifest.yaml").read_text(encoding="utf-8"))
        registry_file = directory / manifest["files"]["registry"]["path"]
        if not registry_file.resolve().is_relative_to(directory):
            raise IdentityUnavailable("Registry fuera del Plant Package")
        raw = registry_file.read_bytes()
        if "sha256:" + hashlib.sha256(raw).hexdigest() != manifest["files"]["registry"]["sha256"]:
            raise IdentityUnavailable("Hash del IdentityRegistry no coincide con manifest")
        if not development:
            if not repository or not published_commit:
                raise IdentityUnavailable("Falta revisión publicada y mergeada del Package")
            repo = Path(repository).resolve()
            rel = directory.relative_to(repo)
            git = ["git", "-c", f"safe.directory={repo}", "-C", str(repo)]
            checks = [(git + ["merge-base", "--is-ancestor", published_commit, "main"]),
                      (git + ["diff", "--quiet", published_commit, "--", str(rel)]),
                      (git + ["cat-file", "-e", f"{published_commit}:{rel}/manifest.yaml"])]
            if any(subprocess.run(c, capture_output=True, check=False).returncode for c in checks):
                raise IdentityUnavailable("Package no verificable en revisión mergeada")
            committed_manifest = subprocess.run(git + ["show",
                                                 f"{published_commit}:{rel}/manifest.yaml"],
                                                capture_output=True, check=False)
            if committed_manifest.returncode or committed_manifest.stdout != (directory / "manifest.yaml").read_bytes():
                raise IdentityUnavailable("Manifest difiere de la revisión mergeada")
            committed = subprocess.run(git + ["show",
                                        f"{published_commit}:{rel}/identity/{registry_file.name}"],
                                       capture_output=True, check=False)
            if committed.returncode or committed.stdout != raw:
                raise IdentityUnavailable("Registry local difiere de la revisión mergeada")
        self.registry = json.loads(raw)
        self.manifest = manifest
        self.config = config
        self.development = development
        if not (self.registry["plant_id"] == manifest["plant_id"] == str(config["plant"]["id"])):
            raise IdentityUnavailable("Plant ID discrepante")
        if self.registry["revision"] != manifest["revision"]:
            raise IdentityUnavailable("Revisión discrepante")
        self.timezone = config["plant"]["timezone"]
        ZoneInfo(self.timezone)
        self.assets = {a["asset_id"]: a for a in self.registry["assets"]}
        self.bindings = self.registry["bindings"]

    @property
    def operationally_usable(self):
        live_capability = self.manifest.get("capabilities", {}).get("scada.live", {})
        return (not self.development and self.manifest["record_status"] == "accepted"
                and live_capability.get("available") is True)

    def _binding(self, kind, value, scope_type, scope_id, at, *, asset_type=None):
        found = {b["asset_id"] for b in self.bindings
                 if b["binding_type"] == kind and b["value"] == str(value)
                 and b["scope_type"] == scope_type and b["scope_id"] == str(scope_id)
                 and b["status"] in ("provisional", "accepted") and _active(b, at)
                 and (asset_type is None or self.assets[b["asset_id"]]["asset_type"] == asset_type)}
        if len(found) != 1:
            raise IdentityUnavailable(f"Binding {kind}={value}: {len(found)} coincidencias")
        return next(iter(found))

    def inventory(self, at=None):
        """Each configured NCU is bound explicitly to a scope; slaves come from registry."""
        at = at or datetime.now(timezone.utc)
        rows = []
        seen_assets = set()
        for ncu in self.config["ncus"]:
            scope = ncu.get("asset_id")
            if not scope or self.assets.get(scope, {}).get("asset_type") != "ncu":
                raise IdentityUnavailable(f"NCU {ncu['id']} sin asset_id explícito")
            if scope in seen_assets:
                raise IdentityUnavailable("NCU duplicada")
            seen_assets.add(scope)
            slaves = [b for b in self.bindings if b["binding_type"] == "modbus_slave"
                      and b["scope_type"] == "ncu" and b["scope_id"] == scope
                      and b["status"] in ("provisional", "accepted") and _active(b, at)
                      and self.assets[b["asset_id"]]["asset_type"] == "tcu"]
            if not slaves:
                raise IdentityUnavailable(f"NCU {ncu['id']} sin inventario explícito")
            for b in slaves:
                slave = int(b["value"])
                if str(slave) != b["value"] or not 1 <= slave <= 200:
                    raise IdentityUnavailable("Esclavo fuera del mapa NCU")
                key = (scope, slave)
                if key in {(r["ncu_asset_id"], r["tcu"]) for r in rows}:
                    raise IdentityUnavailable("Binding Modbus ambiguo")
                asset_id = b["asset_id"]
                if asset_id in seen_assets:
                    raise IdentityUnavailable("Asset ligado a más de una dirección operativa")
                seen_assets.add(asset_id)
                keys = [v for v in self.bindings if v["asset_id"] == asset_id
                        and v["binding_type"] == "operational_asset_key"
                        and v["scope_type"] == "plant" and v["scope_id"] == self.registry["plant_id"]
                        and v["status"] in ("provisional", "accepted") and _active(v, at)]
                if len(keys) != 1:
                    raise IdentityUnavailable(f"TCU {asset_id} sin locator de escena único")
                rows.append({"asset_id": asset_id, "ncu": ncu["id"],
                             "ncu_asset_id": scope, "tcu": slave, "layout_key": keys[0]["value"]})
        if len({r["layout_key"] for r in rows}) != len(rows):
            raise IdentityUnavailable("Locator de escena duplicado")
        return sorted(rows, key=lambda r: (r["ncu"], r["tcu"]))

    def resolve(self, asset_id, at=None):
        at = at or datetime.now(timezone.utc)
        matches = [r for r in self.inventory(at) if r["asset_id"] == asset_id]
        if len(matches) != 1:
            raise IdentityUnavailable("Asset sin binding operativo único en este instante")
        return matches[0]


def configured_identity(config):
    package = os.environ.get("SCADA_PLANT_PACKAGE")
    if not package:
        raise IdentityUnavailable("SCADA_PLANT_PACKAGE no configurado")
    return PlantIdentity(package, config,
                         development=os.environ.get("SCADA_IDENTITY_DEVELOPMENT") == "1",
                         repository=os.environ.get("SCADA_PACKAGE_REPO"),
                         published_commit=os.environ.get("SCADA_PACKAGE_PUBLISHED_COMMIT"))
