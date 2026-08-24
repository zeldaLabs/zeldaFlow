# Brand assets

Source logo files for zeldaFlow. **Use them as supplied — black marks on a
white ground; do not recolor or tint them.**

| File | What it is | Used for |
|---|---|---|
| `zeldaflow_wave_mark_only.{png,svg}` | The three-wave mark alone | `AppIcon.icns` and the menu-bar template mark (`Resources/MenuBarWave.png`) |
| `zeldaflow_three_wave_logo_tight.{png,svg}` | Mark + `zeldaFlow` wordmark | Docs, marketing surfaces |
| `zeldaflow_logo_on_white.png` | The same lockup, flattened onto an opaque white ground | The README header |
| `zeldalabs_org_avatar.png` | 640×640 square, wave mark centred on white with a 16% margin | The zeldaLabs GitHub org avatar |
| `zeldaflow_social_preview.png` | 1280×640 card, lockup centred on white | The repo's GitHub social preview (link unfurls) |

The app icon and menu-bar mark are generated from the wave mark; regenerate
them if the source logo changes.

`zeldaflow_logo_on_white.png` exists because the source PNGs are black on a
*transparent* ground, which disappears against GitHub's dark theme. It is the
supplied lockup composited over white — the prescribed treatment, not a
recolor. Regenerate it the same way if the source changes:

```python
from PIL import Image
src = Image.open("zeldaflow_three_wave_logo_tight.png").convert("RGBA")
bg = Image.new("RGBA", src.size, (255, 255, 255, 255))
Image.alpha_composite(bg, src).convert("RGB").save(
    "zeldaflow_logo_on_white.png", "PNG", optimize=True)
```

`zeldalabs_org_avatar.png` and `zeldaflow_social_preview.png` are uploaded
through the GitHub web UI — org settings → Profile, and repo settings → Social
preview. Neither has a REST API, so they are versioned here to keep the source
of truth in the repo rather than in whatever folder they were made in.

These marks are **not** covered by the Apache-2.0 grant — see
[TRADEMARK.md](../../TRADEMARK.md).
