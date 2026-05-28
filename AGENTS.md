# Project Agent Rules

## Recording Integration Test

After changing app code, project configuration, recording logic, device-change handling, permissions, hotkeys, or `scripts/recording_integration_test.py`, run the recording integration test from the repository root after the app has been rebuilt/installed:

```bash
scripts/recording_integration_test.py --yes --quick --prompt-countdown 2 --start-attempts 3
```

The test really records audio. During microphone phases, prompt the user to speak into the current input device. System-audio phases play a generated test tone automatically.

Expected outcome:

- `failed = 0`
- microphone, system-audio, and mixed modes create files with valid duration and non-silent audio
- input-device switching interrupts and saves the current recording
- recording can be started again after an input-device switch and still captures audio

Output-switch cases may be skipped when fewer than two output devices are connected. Always report `passed / failed / skipped` and explain failures or skips using `test-results/recording-integration/<timestamp>/report.json` and the app log.
