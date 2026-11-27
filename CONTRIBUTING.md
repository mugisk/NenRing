# Contributing to NenRing

[日本語](CONTRIBUTING.ja.md)

Bug reports, diagnostic reports from other Macs, and pull requests are welcome. Issues and pull requests can be written in English or Japanese.

## Reporting

- **Bugs:** use the **Bug report** issue template.
- **Data from your Mac:** use the **Diagnostic report** template (see [README](README.md#contributing-hardware-data)). Reports from Macs other than the reference M1 MacBook Air help establish acquisition coverage; they do not by themselves validate lifespan predictions.
- **Security problems:** do not open a public issue. Follow [SECURITY.md](SECURITY.md).

Issues and attachments are public. Never post serial numbers, full `ioreg` or `smartctl` output, sysdiagnose archives or raw probe files.

## Building

You need macOS 15.6 or later, Xcode 26 or later or its Command Line Tools (Swift 6.2 and the macOS 26 SDK; Xcode 26.4.1 and later need macOS 26.2 or later), and `smartctl` (see [Installing smartmontools](README.md#installing-smartmontools)).

```sh
./scripts/swiftpm.sh test     # run the tests
./scripts/build-app.sh        # build build/NenRing.app
```

Use these scripts rather than calling `swift` directly. They keep build output in `build/swiftpm`, `build/swiftpm-cache` and `build/NenRing.app`, and remove only the temporary folders they create themselves.

## Checks before a pull request

GitHub Actions runs the same check on macOS 26 for each pull request. Run it on your Mac as well before opening one:

```sh
./scripts/ci-local.sh
```

It runs the tests, builds the release app and verifies the signatures of the app and both bundled probes, and ends with `LOCAL CI PASSED`. Paste the last lines of its output into the pull request. If you change the branch after the check, run it again on the new commit. Attach screenshots for UI changes.

## Guidelines

- **Keep changes focused.** One topic per pull request. Match the naming and patterns of the surrounding code, and add or update tests when you change behavior.
- **Documentation:** Update both language versions when changing the README, this guide, the security policy, third-party notices or a guide in the [documentation index](docs/README.en.md).
- **Private Apple interfaces:** NenRing only reads, and only through the fixed calls described in [data acquisition](docs/DATA_ACQUISITION.en.md). Do not add new private calls, opcodes or anything that writes to the SSD controller without discussing it in an issue first. Never scan opcodes or functions.
- **Your data stays local:** do not commit real history files, probe captures or anything with a serial number. Tests use synthetic fixtures.
- **Icons and logo:** the images in `Resources/NenRingIcons/` are not covered by the MIT License (see [their notice](Resources/NenRingIcons/LICENSE.md)). If you distribute a modified version, replace them with your own.

## License

By contributing, you agree that your contributions are licensed under the [MIT License](LICENSE), the same as the rest of the source code and documentation.

If you distribute a modified version or a project based on NenRing, please mention that it is based on NenRing.
