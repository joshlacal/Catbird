# Production typography component fixture

This standalone simulator app renders Catbird's actual typography helpers and font manager. It keeps the fixture outside production targets and replaces only application state/contrast dependencies. Its 40 runtime checks verify all eight named helpers react to app font size, serif family, Bold Text, tracking and line spacing. A second run at a different simulator content-size category supplies a direct Dynamic Type comparison.

Coordinate a build slot before executing. Use a dedicated simulator and an artifact directory outside iCloud:

```bash
./tools/settings-visual-harness/build.sh /absolute/artifact/directory
xcrun simctl install SIMULATOR_UUID /absolute/artifact/directory/SettingsTypographyHarness.app
xcrun simctl ui SIMULATOR_UUID content_size large
xcrun simctl launch SIMULATOR_UUID blue.catbird.fixture.typography
xcrun simctl io SIMULATOR_UUID screenshot /absolute/artifact/directory/default-light.png
```

After the on-screen result reports 40 passed checks, read `Documents/typography-measurements.json` from the path returned by `xcrun simctl get_app_container SIMULATOR_UUID blue.catbird.fixture.typography data`. Preserve that receipt before relaunching. Then terminate the fixture, select `accessibility-extra-extra-extra-large`, relaunch and compare each role's `dynamicHeight`/`dynamicWidth` with the default receipt; app-size measurements deliberately disable Dynamic Type so those checks remain independent.

For the other gallery mode, launch with `--sample=large-serif`. This selects extra-large app text, serif family, Bold Text, relaxed lines and loose letters using a fixture-owned manager/state. Set the simulator appearance to dark using `simctl ui … appearance dark` for the dark sample. The fixture contains a scrollable longer support sentence, message-style text and an error/retry state. It does not claim to be the actual Settings, About or Messages screen.

Production files compile in full from their paths; the script does not rewrite them or select an alternative implementation. Swift 5 language mode matches the existing production source compatibility; the iOS deployment target is 18.0. The generated bundle is simulator-only with a separate identifier and cannot overwrite Catbird or its account preferences.
