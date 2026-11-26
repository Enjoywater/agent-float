# Native Media Tools

Prepare and capture the native app using fictional sessions and a synthetic background. Never use real sessions or the person's wallpaper. Existing Korean assets stay at `docs/media/`; English assets live under `docs/media/en/`.

## Preparation Without Display Interaction

```sh
python3 scripts/media/media.py check
python3 scripts/media/media.py list
python3 scripts/media/media.py show en/hero-light
python3 scripts/media/media.py prepare
```

`prepare` builds the release executable, assembles and signs `build/media-refresh/Agent Float Media.app`, and compiles the synthetic backdrop. It does not launch a GUI or capture anything. The bundle ID is `dev.enjoywater.agent-float.media`; its preferences are separate from the installed app. Do not quit, replace, or reset the installed app. Preparation metadata stays under ignored `build/`.

`shots.json` includes a language dimension: 25 Korean and 25 English entries, each with 11 required scenes and 14 review scenes. Fake scene, agent, language, theme, and reply placement are fixed through environment variables. Fake mode disables real providers, navigators, and focus probes, and uses simulated reply results. Do not describe these captures as proof of actual terminal delivery.

## Static Agent Identity Images

```sh
python3 scripts/media/render-identity.py
```

This renders `docs/media/en/agent-identity-light.png` and `agent-identity-dark.png` at 1370×786 using the production `SessionListContent`, `ReplyHeader`, and `AgentBadge` SwiftUI components. It opens no windows, does not capture the display, and uses fictional sessions with no terminal locators. It compiles the renderer under ignored `build/media-refresh/identity/`. The Korean guide defines the composition; preserve its list, reply header, and side-card arrangement when refreshing the English images. Keep the Korean PNGs unchanged.

## Display-Using Operations

Tell the person immediately before starting. App windows and the synthetic backdrop can cover their display; reply operations may affect keyboard focus. If mouse or keyboard input must pause, say so and provide an estimated duration. When done, terminate only the media processes you started and tell the person they can continue.

### Automated English Frame Sequences

```sh
python3 scripts/media/render.py
# Or capture selected scenes:
python3 scripts/media/render.py en/reply-body.gif en/state-new-light.gif
```

This command uses the built-in display and the isolated media bundle. It configures only that bundle's pill position, waits for its first fake snapshot, and then sends debug expansion signals. `SIGUSR1/2` are valid only with `AGENT_FLOAT_DEBUG=1`; they can terminate a normal app.

The renderer verifies the media bundle, process PID, screen-unlocked state, and capture bounds. A floating synthetic backdrop covers normal app windows. Captures outside its bounds or while the screen is locked are rejected. Backdrops include solid colors, gradients, a fictional document, and fictional code. No personal content is used.

The output is a three-frame native image sequence encoded as a looping GIF, rather than a continuous screen recording. Scenes show the selected state, progress where applicable, and the simulated result. The NEW scenes wait through the polling interval so the completion signal is captured. Raw PNGs, logs, and detailed manifests remain under `build/media-refresh/english/`; public manifests must exclude absolute paths, PIDs, and personal data. Review every final asset before committing.

### Manual Launch and Continuous Recording

```sh
python3 scripts/media/media.py launch en/reply-choice-light --open-reply
```

After startup is ready, `USR1` expands the list and opens the designated `fake-media-target` question after a delay. `USR2` collapses it. Do not send signals before the debug handlers have been installed.

`control.py` can exercise a running media reply through Orca's computer-use APIs:

```sh
python3 scripts/media/control.py reply-choice-light
```

It checks the media PID, executable, bundle, and scenario before reading a fresh accessibility tree. Verify selected values and the fake backend result, not merely command success. Never redirect this controller to real sessions.

Continuous recording is available with a screen rectangle matching the shot's output aspect ratio:

```sh
python3 scripts/media/media.py record en/hero-light --rect 100,100,460,574
python3 scripts/media/media.py convert build/media-refresh/takes/hero-light/<timestamp>
python3 scripts/media/media.py stop
```

The example coordinates must be replaced with a verified synthetic region. `record` captures for the configured duration; it does not perform the interactions. Raw video and capture metadata stay under the ignored take directory. Check actual source resolution/fps with `ffprobe`; do not assume macOS guarantees the requested frame rate. `convert` scales, applies a palette, loops, and normalizes continuous video to 15fps, without overwriting an existing converted take. It does not automatically publish to `docs/media`.

`stop` verifies the recorded media PID and executable before terminating it. It never targets the installed app.

## Review Before Publication

- Confirm agent badges and text remain readable at the displayed size.
- Check card edges, shadows, long text, all reply placements, light/dark themes, and result states.
- Ensure NEW actually appears and a success frame includes the verified fictional answer.
- Verify only synthetic content appears in every frame; remove local paths from public metadata.
- Keep originals, temporary files, and logs under ignored `build/`.
- Preserve existing Korean media byte-for-byte when adding English assets.

The historical [media refresh plan](../../docs/plans/2026-10-30-media-refresh.md) remains in Korean.
