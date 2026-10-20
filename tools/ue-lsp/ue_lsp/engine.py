"""Locate the project (.uproject) and the engine root it is associated with."""
import json
import os

LAUNCHER_DAT = os.path.join(os.environ.get("PROGRAMDATA", r"C:\ProgramData"),
                            "Epic", "UnrealEngineLauncher", "LauncherInstalled.dat")


def find_uproject(start):
    """Return path of the first *.uproject in start or its ancestors."""
    d = os.path.abspath(start) if start else None
    while d:
        try:
            for n in os.listdir(d):
                if n.lower().endswith(".uproject"):
                    return os.path.join(d, n)
        except OSError:
            pass
        nd = os.path.dirname(d)
        if nd == d:
            break
        d = nd
    return None


def _valid_engine(root):
    return bool(root) and os.path.isdir(os.path.join(root, "Engine", "Source", "Runtime", "CoreUObject"))


def _registry_lookup(assoc):
    try:
        import winreg
    except ImportError:
        return None
    # Launcher installs: HKLM\SOFTWARE\EpicGames\Unreal Engine\<ver> InstalledDirectory
    for view in (0, getattr(winreg, "KEY_WOW64_64KEY", 0)):
        try:
            with winreg.OpenKey(winreg.HKEY_LOCAL_MACHINE,
                                r"SOFTWARE\EpicGames\Unreal Engine\%s" % assoc, 0, winreg.KEY_READ | view) as k:
                v, _ = winreg.QueryValueEx(k, "InstalledDirectory")
                if _valid_engine(v):
                    return v
        except OSError:
            pass
    # Source builds: HKCU\Software\Epic Games\Unreal Engine\Builds  {GUID} = path
    try:
        with winreg.OpenKey(winreg.HKEY_CURRENT_USER, r"Software\Epic Games\Unreal Engine\Builds") as k:
            v, _ = winreg.QueryValueEx(k, assoc)
            if _valid_engine(v):
                return v
    except OSError:
        pass
    return None


def _launcher_lookup(assoc):
    try:
        with open(LAUNCHER_DAT, encoding="utf-8") as f:
            data = json.load(f)
    except (OSError, ValueError):
        return None
    for e in data.get("InstallationList", []):
        if e.get("AppName") == "UE_" + assoc and _valid_engine(e.get("InstallLocation")):
            return e["InstallLocation"]
    return None


def resolve_engine(uproject, override=None):
    """Return (engine_root, how). Order: override -> env UE_ENGINE_PATH -> registry -> launcher dat -> parent dirs."""
    if override and _valid_engine(override):
        return os.path.normpath(override), "initializationOptions.enginePath"
    env = os.environ.get("UE_ENGINE_PATH")
    if env and _valid_engine(env):
        return os.path.normpath(env), "UE_ENGINE_PATH"
    assoc = None
    if uproject:
        try:
            with open(uproject, encoding="utf-8-sig") as f:
                assoc = json.load(f).get("EngineAssociation")
        except (OSError, ValueError):
            assoc = None
    if assoc:
        r = _registry_lookup(assoc)
        if r:
            return os.path.normpath(r), "registry"
        r = _launcher_lookup(assoc)
        if r:
            return os.path.normpath(r), "LauncherInstalled.dat"
    # project inside an engine tree (source builds with empty association)
    if uproject:
        d = os.path.dirname(os.path.dirname(uproject))
        while d and os.path.dirname(d) != d:
            if _valid_engine(d):
                return os.path.normpath(d), "ancestor"
            d = os.path.dirname(d)
    return None, "not found (association %r)" % assoc
