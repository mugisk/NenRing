# ASP probe signature checks

[日本語](PROBE_SIGNATURE.md) · [Documentation](README.en.md)

## Purpose

`asp-ftl-stats-probe` and `asp-snapshot-probe` read statistics from the internal Apple SSD controller. `asp-ftl-stats-probe` can run as root after macOS administrator authentication during a manual retry (the former `asp-tunnel-probe` has been removed). Beyond the correctness of the values read, the app therefore verifies immediately before execution that **the binary handed to administrator execution is the expected probe**.

## Before execution

For normal and administrator execution, `ASPDirectProbeGenerator` checks:

1. The probe name belongs to a fixed enumeration.
2. The executable is directly inside the app bundle's `Contents/Resources/ASPProbes` directory.
3. It is a regular file with execute permission.
4. Its static code signature passes `SecStaticCodeCheckValidity` in strict mode.
5. The signing identifier matches the probe name (for example, `asp-ftl-stats-probe`).
6. The app and probe have matching Team Identifiers; a team identifier on only one side is also rejected.
7. For administrator execution, the probe and its path to `/` are root-owned and not writable by group or others.

A failed check prevents execution and the administrator prompt. When FTL all fails with normal privileges and is retried with administrator privileges, the same checks run again immediately before the retry. The ordinary `/Applications` directory does not meet the strict administrator path requirements; installing there does not enable the root fallback.

## Scope of the signing method

Local Release builds use ad-hoc signing unless a signing identity is specified in `CODE_SIGN_IDENTITY`. This detects changes after signing and checks the expected identifier/path; it does not establish the publisher's identity or authenticate the origin of a downloaded app. An attacker who can replace and re-sign a user-writable app is not defeated by ad-hoc signing alone.

Experimental distributions use ad-hoc signing for now and may require individual Gatekeeper approval. Distribution verification and first launch must be checked separately from local execution. Administrator execution is not allowed from a non-root-owned path.

The runtime check still compares the app and probe Team Identifiers, but does not pin them to a particular publisher's Team Identifier. A move to Developer ID would set `CODE_SIGN_IDENTITY` to a Developer ID Application signing identity and separately add the notarization procedure and a check that pins the publisher's Team Identifier. Specifying the identity in the current script does not by itself complete notarization.

## Build-time checks

`scripts/build-app.sh` signs the two probes individually, using each probe name as the identifier, and then signs the app. Every signature enables the Hardened Runtime and, when a signing identity is supplied, carries a secure timestamp. Afterwards it runs `codesign --verify --strict` on the app and both probes and checks that the Hardened Runtime is on. A missing signature, a missing Hardened Runtime, or the builder's home folder or repository path inside the bundle fails the packaged build. The app executable has its debug information, which records absolute paths, removed with `strip -S`.

## Test exception

Only unit tests that use shell-script fixtures may explicitly inject `ASPProbeSignatureVerifier(allowUnsignedForTesting: true)`. This exception is not used in the app's initialization path or in Release bundles.

## Out of scope

- These checks do not establish the meaning of probe output, the correctness of the forecasts or hardware compatibility.
- Ad-hoc signing is not described as Developer ID signing.
- No process is added to repair a tampered app.
- The app does not run sysdiagnose, scan unknown opcodes or re-run a probe automatically.
