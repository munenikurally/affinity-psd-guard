Affinity PSD Guard for Windows 11

Overview

When a Photoshop PSD file is opened directly in Affinity v3, some layers may appear shifted.
This application is a Windows 11 tool designed to avoid that problem.

This is not a plug-in that replaces Affinity's built-in PSD importer.
Affinity does not provide a public plug-in API for replacing the PSD importer.

Instead, this application provides two features:

1. Analyze possible PSD layer problems.
2. Generate a new PSD with Affinity-v3-sensitive smart object metadata removed.


How to Start

Double-click this file:

Start-AffinityPsdGuard.cmd


Moving the App to Another Folder

The application only needs these two files to run:

Start-AffinityPsdGuard.cmd
AffinityPsdGuard.ps1

If you move the app to another directory, keep these two files in the same folder.
README_ja.txt and README_en.txt are documentation files and are not required for the app to run.


Basic Usage

1. Start the app.
2. Click Open PSD and select a PSD or PSB file.
3. Click Analyze to inspect the PSD layer metadata.
4. Click Sanitize PSD to generate an Affinity-v3-safe PSD.

You can also drag and drop a PSD file onto the application window.


Sanitize PSD

Sanitize PSD converts the PSD without launching Affinity Photo 2.

PSD layers can contain Photoshop smart object or placed-layer metadata in addition to visible pixel data.
Affinity v3 may interpret that metadata differently and shift layer positions.

This app preserves the visible layer pixel/channel data and removes only the smart object metadata blocks that are known to cause problems in this case.

The generated file is opened in Affinity v3 automatically if Affinity v3 is found.

Default output name:

original-file-name.affinity-v3-safe.psd

If a file with the same name already exists, the app creates a timestamped copy instead of overwriting it.


Important Notes

The original PSD is not overwritten.
The app always creates a separate PSD file.

The generated PSD may no longer preserve affected layers as editable Photoshop smart objects.
This is intentional: the goal is to preserve the visible layer result and avoid layer shifting in Affinity v3.

If you need to edit the internal contents of Photoshop smart objects, keep the original PSD as your source file.


Window Controls

Open PSD
Select a PSD or PSB file.

Analyze
Analyze PSD layer information and show risky metadata.

Sanitize PSD
Create an Affinity-v3-safe PSD by removing smart object metadata, then open it in Affinity v3 when possible.

Output
Destination path for the generated PSD.

Save JSON
Save the analysis report as a JSON file.


Commonly Detected Risks

Smart objects
Vector masks
Layer masks
Layer effects
Text layers
Group/section layers
Layers outside the canvas
Invalid layer bounds


Files

Start-AffinityPsdGuard.cmd
Launcher file. Normally, double-click this file.

AffinityPsdGuard.ps1
Main application file.

README_ja.txt
Japanese documentation.

README_en.txt
English documentation.
