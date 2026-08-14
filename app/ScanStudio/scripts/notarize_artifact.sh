#!/bin/zsh
set -euo pipefail

# Notarizes and staples ONE release artifact -- the .app first, then the
# .dmg built from the stapled app. Both need their own ticket: the in-app
# updater's publisher-trust gate requires a stapled ticket on the INSTALLED
# app (UpdateService reads kSecCodeInfoStapledNotarizationTicket), and an
# app copied out of a DMG does not inherit the DMG's ticket; the DMG's own
# ticket covers the first-open Gatekeeper check of the download itself,
# including offline.
#
# Runs only in release automation, and for the DMG strictly BEFORE
# SHA256SUMS/latest.json are emitted -- stapling mutates the file, so every
# published checksum must be computed after this script succeeds.
#
# Usage: notarize_artifact.sh app <path/to/ScanStudio.app>
#        notarize_artifact.sh dmg <path/to/ScanStudio-*.dmg>
#
# Required environment:
#   SCANSTUDIO_SIGNING_IDENTITY  Developer ID Application identity string
#   NOTARY_KEY_FILE              path to the App Store Connect API .p8 key
#   NOTARY_KEY_ID                the key id for that key
#   NOTARY_ISSUER_ID             the issuer id for the team

kind="${1:?usage: notarize_artifact.sh <app|dmg> <path>}"
artifact="${2:?usage: notarize_artifact.sh <app|dmg> <path>}"
[[ -e "$artifact" ]] || { print -u2 "no such artifact: $artifact"; exit 1; }
: "${SCANSTUDIO_SIGNING_IDENTITY:?}" "${NOTARY_KEY_FILE:?}" "${NOTARY_KEY_ID:?}" "${NOTARY_ISSUER_ID:?}"

submit_and_require_accepted() {
    local upload="$1"
    local submission submission_id
    # `|| true`: notarytool's exit code differs across Xcode versions and a
    # transport/auth failure must still leave its output in the log -- the
    # status line in the captured output is the single authority either way.
    submission="$(xcrun notarytool submit "$upload" \
        --key "$NOTARY_KEY_FILE" \
        --key-id "$NOTARY_KEY_ID" \
        --issuer "$NOTARY_ISSUER_ID" \
        --wait --timeout 45m 2>&1)" || true
    print -r -- "$submission"
    if [[ "$submission" != *"status: Accepted"* ]]; then
        submission_id="$(print -r -- "$submission" | awk '/^[[:space:]]*id: /{print $2; exit}')"
        if [[ -n "$submission_id" ]]; then
            # The per-file rejection reasons live only in this log.
            xcrun notarytool log "$submission_id" \
                --key "$NOTARY_KEY_FILE" \
                --key-id "$NOTARY_KEY_ID" \
                --issuer "$NOTARY_ISSUER_ID" || true
        fi
        print -u2 "notarization was not accepted for $upload"
        exit 1
    fi
}

case "$kind" in
    app)
        # Apps are submitted as a zip; the ticket staples onto the bundle.
        upload_dir="$(mktemp -d)"
        trap 'rm -rf "$upload_dir"' EXIT
        upload_zip="$upload_dir/${artifact:t}.zip"
        ditto -c -k --keepParent "$artifact" "$upload_zip"
        submit_and_require_accepted "$upload_zip"
        xcrun stapler staple "$artifact"
        xcrun stapler validate "$artifact"
        ;;
    dmg)
        codesign --force --sign "$SCANSTUDIO_SIGNING_IDENTITY" --timestamp "$artifact"
        submit_and_require_accepted "$artifact"
        xcrun stapler staple "$artifact"
        xcrun stapler validate "$artifact"
        # Gatekeeper's own verdict on the stapled DMG -- the check a user's
        # machine effectively runs on first open.
        spctl -a -t open --context context:primary-signature -v "$artifact"
        ;;
    *)
        print -u2 "unknown artifact kind: $kind (expected app or dmg)"
        exit 1
        ;;
esac

print "Notarized and stapled $artifact"
