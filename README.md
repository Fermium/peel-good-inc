# Peel Good Inc.

A small menu bar app for the Mac that prints shipping labels, return codes and anything else you drop on it, straight to a thermal label printer.

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/screenshots/popover-review-dark.png">
    <img src="docs/screenshots/popover-review-light.png" width="380" alt="The preview popover showing a 4 × 6 shipping label, with Size, Fit and Ink controls and a Print button">
  </picture>
</p>

Drop a PDF, screenshot, image or SVG on the parcel icon in the menu bar. Peel Good Inc. finds the label on the page, turns it the right way round, fits it to the roll in your printer and prints it. There's no print dialog, and a short countdown lets you cancel.

It's built for the labels small sellers deal with every day: Royal Mail Click & Drop PDFs, USPS and UPS labels on Letter pages, Amazon return QR codes saved as screenshots. It also prints logos, SVGs and photos.

## What it does

- Reads every barcode, QR code and DataMatrix on the page, lines them up with the printer's dots so the bars come out even, and checks they still scan before printing.
- Prints every page, in order. A packing slip next to a label prints too.
- Supports every roll your printer reports, from 2 × 1.25 in to 4 × 8 in, plus custom sizes. Hold a file over the icon to send it to another printer.
- Rules, written like Mail rules, pick the printer, size and ink for each kind of file. It can also watch a folder such as Downloads and offer to print new labels.
- After printing it can tag the file in Finder, rename it, move it or put it in the Trash. Printed labels are kept for reprinting.
- Also works from the Share menu, Services, Open With and the clipboard.

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/screenshots/settings-rules-dark.png">
    <img src="docs/screenshots/settings-rules-light.png" width="640" alt="The Rules tab in Settings, with rules for Royal Mail, Amazon returns and photos">
  </picture>
</p>

Thermal printers only print black dots, so each label is turned into pure black and white. Crisp gives sharp text and barcodes, Photo dithers gray areas into dot patterns, and Auto picks one for each page.

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/screenshots/ink-modes-dark.png">
    <img src="docs/screenshots/ink-modes-light.png" width="640" alt="The Ink Modes window comparing a sample label in Auto, Crisp and Photo">
  </picture>
</p>

## Install

```sh
brew install --cask fermium/tap/peel-good-inc
```

Or download the DMG from [Releases](https://github.com/fermium/peel-good-inc/releases).

The app isn't notarized by Apple yet. The Homebrew cask clears the quarantine flag for you. If you use the DMG, Control-click the app and choose Open the first time.

It needs macOS 15 or later. It's tested with a MUNBYN ITPP941AP and should work with any label printer that macOS can print to, over AirPrint or a CUPS driver.

## Privacy

Everything happens on your Mac and nothing is uploaded. The HTTP API and the MCP server for AI assistants are off by default. When they're on, they only accept connections from this Mac and need a token.

## Build from source

```sh
swift build
swift test
./scripts/make-app.sh
open "build/Peel Good Inc.app"
```

The same pipeline is available as a command-line tool:

```sh
swift run labelize --list-sizes
swift run labelize --size 4x6 ~/Downloads/order-1234-label.pdf    # writes out/*.label.pdf and previews
swift run labelize --dry-run --size 4x4 return-code.png              # shows the print command
```

`LabelKit` holds the label pipeline. The app is in `Sources/LabelizeApp`, the release process is in [RELEASING.md](RELEASING.md), and `./scripts/screenshots.sh` renders the screenshots above.

## License

MIT © 2026 Fermium Ltd. The name is a nod to Gorillaz.
