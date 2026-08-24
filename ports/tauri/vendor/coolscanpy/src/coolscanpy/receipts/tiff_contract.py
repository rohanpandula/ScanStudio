"""Versioned TIFF contracts shared by scanner writers and image loaders."""

from typing import Any, Mapping

# TIFF reserves 65000-65535 for reusable application-private tags.  A private
# tag keeps this machine-readable source contract separate from tag 270
# (ImageDescription), which NegPy legitimately uses for human captions and film
# metadata.  The exact ASCII payload is deliberately versioned: loaders must
# only bypass a transfer-function decode for a contract they fully understand.
LINEAR_SCANNER_RGB_TAG = 65000
LINEAR_SCANNER_RGB_MARKER = "negpy.scanner-rgb.linear.uint16.v1"
LINEAR_SCANNER_RGB_EXTRATAG = (
    LINEAR_SCANNER_RGB_TAG,
    "s",
    0,
    LINEAR_SCANNER_RGB_MARKER,
    False,
)


def has_linear_scanner_rgb_marker(tags: Mapping[Any, Any]) -> bool:
    """Return whether ``tags`` contains NegPy's exact linear scanner contract."""

    tag = tags.get(LINEAR_SCANNER_RGB_TAG)
    return tag is not None and tag.value == LINEAR_SCANNER_RGB_MARKER


# The infrared plane marker needs a second private code in the same reserved
# 65000-65535 range.  Issue #105: the original choice, 65001, sits in the
# Photoshop Camera RAW block that ExifTool names for every file whose Make
# claims Nikon, so the marker surfaced as a spurious ``SerialNumber`` field.
# 65010 (0xFDF2) is clear of every code ExifTool names (0xFDE8-0xFDEA,
# 0xFE4C-0xFE58), clear of Kodak's 0xFE00 KDC_IFD, and clear of tifffile's
# EER metadata block 65001-65009, while staying inside the private range.
SCANNER_INFRARED_TAG = 65010
SCANNER_INFRARED_MARKER = "scanstudio.infrared.linear.uint16.v1"
SCANNER_INFRARED_EXTRATAG = (
    SCANNER_INFRARED_TAG,
    "s",
    0,
    SCANNER_INFRARED_MARKER,
    False,
)
# Files exported before #105 carry the identical ASCII payload under 65001.
# Readers must keep discovering those legacy planes; only writers moved.
LEGACY_SCANNER_INFRARED_TAGS = (65001,)


def has_scanner_infrared_marker(tags: Mapping[Any, Any]) -> bool:
    """Return whether ``tags`` marks an untouched scanner infrared plane.

    Accepts both the current #105 layout (tag 65010) and files exported by
    earlier releases (tag 65001), so previously written artifacts stay
    discoverable without migration.
    """

    for code in (SCANNER_INFRARED_TAG, *LEGACY_SCANNER_INFRARED_TAGS):
        tag = tags.get(code)
        if tag is not None and tag.value == SCANNER_INFRARED_MARKER:
            return True
    return False
