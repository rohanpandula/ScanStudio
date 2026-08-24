# Off-raster Frame Reconstruction

ScanStudio does not synthesize or expose a complete frame when part of that frame lies outside the scanner's captured preview raster.

## Why this is out of scope

When the detected first frame begins before the captured preview area, the missing rows were never measured by the scanner. No image-processing correction can recover those pixels faithfully. Presenting a reconstructed or silently cropped frame as complete would conflict with ScanStudio's fail-closed capture contract and could produce an archival scan whose missing content is easy to overlook.

The supported recovery is to refeed the film far enough into the transport and acquire a fresh preview so the full frame is physically captured. Manual placement may help position work that is already present in the raster, but it cannot restore pixels that were never sampled.

Small alignment tolerances remain an implementation detail of the capture contract; this decision concerns requests to recover materially off-raster content by inventing or silently accepting missing image data.

## Prior requests

- #19 — "ScanStudio: The first frame is not fully inside the scanner (REFEED_REQUIRED)"
