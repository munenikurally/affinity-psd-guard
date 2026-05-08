# Affinity PSD Guard

Affinity PSD Guard is an unofficial Windows 11 tool for PSD files whose Photoshop smart object layers are imported incorrectly in Affinity v3.

In the tested case, Affinity v3 still imported PSD smart object layers at the wrong scale even when **Import PSD smart objects where possible** was enabled. The affected smart object layer pixels appeared scaled down / shifted after opening the PSD directly.

This tool analyzes PSD layer metadata and can generate a new `*.affinity-v3-safe.psd` file by removing Photoshop placed/smart object metadata blocks while preserving visible layer pixel/channel data.

This project is unofficial and is not affiliated with, endorsed by, or sponsored by Serif, Canva, Adobe, or any related trademark holders.

## What It Does

- Reads PSD layer records directly.
- Reports smart object / placed layer metadata that may be misinterpreted by Affinity v3.
- Removes smart object / placed layer metadata blocks known to trigger wrong-scale imports in tested files.
- Keeps the original PSD untouched.
- Opens the generated safe PSD in Affinity v3 when Affinity is found.

## Requirements

- Windows 11
- Windows PowerShell
- Affinity v3, optional but useful for opening the generated PSD automatically

No installation or third-party dependency is required.

## Usage

Double-click:

```text
Start-AffinityPsdGuard.cmd
```

Then:

1. Click `Open PSD`.
2. Select a PSD or PSB file.
3. Click `Analyze` to inspect risks.
4. Click `Sanitize PSD` to create a safer PSD for Affinity v3.

Default output name:

```text
original-file-name.affinity-v3-safe.psd
```

If the output already exists, the app creates a timestamped copy instead of overwriting it.

## Important Notes

The app does not overwrite the original PSD.

Affected layers may no longer be preserved as editable Photoshop smart objects in the generated PSD. This is intentional: the goal is to preserve the visible layer result and avoid layer shifting in Affinity v3.

Keep the original PSD if you need to edit smart object contents later.

## Documentation

- `README_en.txt`: English plain-text documentation
- `README_ja.txt`: Japanese plain-text documentation

## License

MIT License. See `LICENSE`.
