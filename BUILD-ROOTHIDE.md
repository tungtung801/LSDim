# 26LockDim — RootHide build

This project is intended for a RootHide jailbreak. The included GitHub Actions workflow builds an A12-compatible `arm64e` package using RootHide Theos on macOS 15/Xcode 16.4.

## Build with GitHub Actions

1. Create a new GitHub repository.
2. Upload the **contents of this folder** to the repository root, including `.github/workflows/build-roothide.yml`.
3. Open **Actions → Build 26LockDim (RootHide)**.
4. Run the workflow with the default `arm64e` input for the A12/iOS 16.5.1 device.
5. Download the `26LockDim-roothide` artifact and install the `.deb` with Sileo/Filza.

The workflow can also build `arm64 arm64e` or `arm64` through the manual `archs` input. The current package is intentionally separate from `26Unlock` and does not modify its source.

## Recovery / safe mode

The tweak has a fail-closed marker at `/var/mobile/Media/26LockDim.safe`. If SpringBoard crashes during the initial safety window, the next launch skips all 26LockDim hooks. Remove that marker with Filza only after the device is stable if you want to try the tweak again.

Runtime settings may be placed at `/var/mobile/26LockDim.plist`; see `tunables.sample.plist`.
