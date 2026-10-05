# Releasing DAF Scanner

1. In Xcode, bump the version:
   - `MARKETING_VERSION` (e.g. 0.9 → 1.0)
   - the build number (`CURRENT_PROJECT_VERSION`)
2. Product > Archive.
3. In the Organizer: Distribute App, then export the `.ipa`.
4. From this folder (`altstore-source/`), run:
   ```
   ./release.sh "<path to exported .ipa>" "<release notes text>"
   ```
   (use `--dry-run` first if you want to check the version/size/hash before publishing)
5. Wait ~2 minutes for GitHub Pages to republish `apps.json`.
6. Colleagues: open AltStore, go to the DAF Scanner Source, and refresh it to see the update.
