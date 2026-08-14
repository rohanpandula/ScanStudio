#!/bin/zsh
set -euo pipefail

# Signs, notarizes, and staples one release DMG, then proves Gatekeeper
# accepts it. Runs only in the release workflow, after package_dmg.sh built
# the DMG from the Developer-ID-signed app and BEFORE SHA256SUMS/latest.json
# are emitted -- stapling mutates the DMG, so every checksum must be
# computed after this script succeeds.
#
# Required environment:
#   SCANSTUDIO_SIGNING_IDENTITY  Developer ID Application identity string
#   NOTARY_KEY_FILE              path to the App Store Connect API .p8 key
#   NOTARY_KEY_ID                the key id for that key
#   NOTARY_ISSUER_ID             the issuer id for the team

dmg="${1:?usage: notarize_dmg.sh <dmg>}"
[[ -f "$dmg" ]] || { print -u2 "no such DMG: $dmg"; exit 1 }
: "${SCANSTUDIO_SIGNING_IDENTITY:?}" "${NOTARY_KEY_FILE:?}" "${NOTARY_KEY_ID:?}" "${NOTARY_ISSUER_ID:?}"

codesign --force --sign "$SCANSTUDIO_SIGNING_IDENTITY" --timestamp "$dmg"

# notarytool can exit 0 while reporting a rejected submission, so the status
# line in its output is the authority; on anything but Accepted, fetch the
# per-file log (the only place the actual rejection reasons live) and fail.
submission="$(xcrun notarytool submit "$dmg" \
    --key "$NOTARY_KEY_FILE" \
    --key-id "$NOTARY_KEY_ID" \
    --issuer "$NOTARY_ISSUER_ID" \
    --wait --timeout 45m 2>&1)"
print -r -- "$submission"
if [[ "$submission" != *"status: Accepted"* ]]; then
    submission_id="$(print -r -- "$submission" | awk '/^[[:space:]]*id: /{print $2; exit}')"
    if [[ -n "$submission_id" ]]; then
        xcrun notarytool log "$submission_id" \
            --key "$NOTARY_KEY_FILE" \
            --key-id "$NOTARY_KEY_ID" \
            --issuer "$NOTARY_ISSUER_ID" || true
    fi
    print -u2 "notarization was not accepted"
    exit 1
fi

xcrun stapler staple "$dmg"
# Gatekeeper's own verdict on the stapled DMG -- the check a user's machine
# will effectively run on first open.
spctl -a -t open --context context:primary-signature -v "$dmg"
print "Notarized and stapled $dmg"
