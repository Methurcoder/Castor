# WebView2Loader.dll

`x64/WebView2Loader.dll` comes unmodified from the NuGet package
Microsoft.Web.WebView2 1.0.4191.47 (`runtimes/win-x64/native/`), BSD-3-Clause
(`LICENSE`). Castor's creation window loads it at run time from beside
`CastorPet.exe`; the WebView2 Runtime itself is part of Windows and is not
redistributed.

SHA-256 `c66e4a92fdc7a216118e43b7a5024ea2200e8c43f9310bf20d96a0084f82c5bc`
(package `f492bbf547d0da329553b6727435b677579b1e9f91cc9e4a1ad029366d5f23d0`).
`scripts/build-castor-setup.py` checks the hash before copying it.
