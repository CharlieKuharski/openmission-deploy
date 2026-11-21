# OpenMission for macOS

Build on an Apple Silicon Mac with macOS 14 or later and Xcode Command Line Tools. The app bundles this repository’s release Compose file, image-version settings and SearXNG configuration. Docker images and Ollama models are downloaded during setup.

From the repository root, run

```sh
./macos/test.sh
./macos/build-dmg.sh
```

Open `macos/build/OpenMission.dmg` and drag the app to Applications. The copy at `macos/OpenMission.dmg` is the installer offered by this branch. The build script signs the app ad hoc and verifies both the app and the disk image. Public distribution with an identified publisher requires Developer ID signing and notarization.

## Verify against a local installation

With Docker and Ollama running, check that the launcher can recognize the existing OpenMission UI

```sh
./macos/test.sh --discover
```

For a fresh-install check, mount the DMG and run the following from the repo root. Supply an installed Ollama tag to avoid a model download. The harness requires a new test directory and free ports 25173, 28080, 28642 and 29119.

```sh
./macos/test.sh --smoke "$PWD/macos/build/smoke-one" \
  "/Volumes/OpenMission/OpenMission.app/Contents/Resources" hermes3:8b
```

This starts a disposable Compose project, saves the selection for both roles, stops and restarts the services, and checks the saved defaults. To exercise separate roles, append an installed coding tag such as `qwen3-coder:30b` and use a new test directory. That also generates a sample story, starts a build, verifies the coding model reported by Hermes, and cancels the sample build. The harness removes its Compose containers and named volumes. Test data remains in the test directory for inspection.
