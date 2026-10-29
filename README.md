# labelize

Spike for a menu bar app that prints any PDF, SVG or image as a label on a thermal printer.
`LabelKit` holds everything the app will reuse; `labelize` is a command-line front end.

```sh
swift build -c release
.build/release/make-fixtures Fixtures      # test inputs
.build/release/labelize --list-printers
.build/release/labelize --list-sizes
.build/release/labelize Fixtures/letter-usps.pdf            # writes out/*.label.pdf + previews
.build/release/labelize --print ~/Downloads/order-1459-label.pdf
.build/release/labelize --size 4x2 --dry-run Fixtures/amazon-return.png
swift test
```

## Pipeline

1. **Load**: PDF via CGPDFDocument; SVG and images via NSImage (SVG stays vector).
2. **Find codes**: Vision reads QR, Code128, DataMatrix and others from a 1600 px render.
3. **Crop** (`auto`): if the page is already label-sized, use it as is. On larger pages, find
   ink regions; keep the region holding the codes (a bordered label), or for a code standing
   alone (a QR on a phone screenshot) pull in the text above and below it, ignoring app chrome.
   Without codes, pick the region closest in shape to the label.
4. **Rotate and scale** to whichever orientation fills the label more; fit or fill.
5. **Ink**: render at the printer's 200 dpi, then hard cutoff (crisp) or Atkinson dither (photo).
   Pages with codes always go crisp.
6. **Verify**: decode the codes again from the 1-bit result and warn about any that broke.
7. **Output**: a PDF exactly the label size holding the 1-bit image, printed with
   `lp -o media=<printer preset or custom_WxHin> -o print-scaling=none`.

Sizes come from the printer (CUPS presets plus its custom range) merged with the MUNBYN roll
catalog; sizes outside the printer's range are listed with the reason.
