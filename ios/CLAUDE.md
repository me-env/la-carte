# ios/

- All code lives in `LaCarteKit/` (Swift package). `LaCarte/` is a thin shell (`@main` → `RootView()`).
- Follow `../docs/tca-conventions.md`. Add new features as new modules in `LaCarteKit/Package.swift`.
- The Xcode project uses synchronized folders: files added under `LaCarte/` or `LaCarteUITests/`
  are picked up automatically. Don't hand-edit `project.pbxproj` unless adding a target.
- Build/test only through `../scripts/ios-*.sh` (they pin the simulator and export screenshots).
