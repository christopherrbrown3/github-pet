# Beta 8 README images

No new images. The Beta 8 README reuses the Beta 5, Beta 6 and Beta 7 images, which still match the app.

Checked against the `render-check` artifact of CI run 45727202093 (`main` at `55b7d2c`, which holds the
frame-by-frame animations, #138): its `readme-mascot-mona-pet-v1*.png` and
`readme-mascot-little-chris-v1*.png` renders are the same 256×300 and 256×284 stills as
`../beta-5/mascot-*.png`, with the same idle art, and differ only in anti-aliasing of the tag and badge. The new animations are registered to the old idle frame, so the pet at rest looks the same. Nothing
was regenerated, so the Beta 5 images stay in use.

No image of the incident helmet is included: the README render pipeline has no helmet render, and
producing one needs a separate non-production build of the app (`--dump-incident-frames`).
