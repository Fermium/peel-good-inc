# Tone calibration

Thermal dots print bigger than their cell, so grays come out darker than asked. Photo and
Halftone correct for this with one number per printer, `toneGamma`: a requested coverage `c`
(0 white, 1 black) is assumed to print `c^toneGamma` dark. The default is 0.65, a guess from
the dither bench. Measure your printer to replace it.

## 1. Print the wedge

```sh
swift run -c release peelgood --step-wedge --size 4x6 --out /tmp/wedge            # writes, doesn't print
swift run -c release peelgood --step-wedge --size 4x6 --print --printer NAME      # prints it
```

The wedge has 11 patches labelled 0% to 100% requested coverage. It is dithered in Photo with
compensation off (`toneGamma` 1), so it shows the printer's raw response. Add `--ink halftone` to
measure Halftone, which usually has less gain. Let the label cool for a minute before measuring.

## 2. Measure the patches

Scan at 300 dpi or more, or take a phone photo in even daylight, square on, no flash. Open it in
any editor that reports L* (Lab) or gray values, and average a square in the middle of each
patch, away from the border.

Turn each reading into printed darkness `d` with the 0% patch as paper and the 100% patch as
solid black:

```
d = (Y_paper - Y_patch) / (Y_paper - Y_black)
```

`Y` is linear reflectance: from L*, `Y = ((L* + 16) / 116)^3`; from an sRGB gray `v` (0 to 1),
`Y = ((v + 0.055) / 1.055)^2.4`. Don't use raw gray values directly; they aren't linear.

## 3. Fit gamma

For the patches from 10% to 90%, fit `ln d = gamma × ln c` through the origin:

```
gamma = Σ ln(c) ln(d) / Σ ln(c)^2
```

A quick check: `gamma ≈ ln(d at 50%) / ln(0.5)`. If the 50% patch prints 70% dark, gamma is 0.51.
Values below 1 mean dot gain; 1 means none.

## 4. Use it

```sh
swift run -c release peelgood --ink photo --tone-gamma 0.55 file.pdf
```

In code, set `LabelOptions.toneGamma`. Reprint the wedge with `--tone-gamma` set to the fitted
value: each patch should now measure close to its label. `--cutoff` still shifts the midtones on
top of this (above 50 prints darker).
