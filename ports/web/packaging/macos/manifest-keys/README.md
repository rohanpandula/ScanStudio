# Web runtime manifest verification keys

Production web-runtime publishing is disabled until a reviewed Ed25519 public
key is added to this directory as `<key-id>.pem` and the matching private key
is stored only in the GitHub Actions secret named in
[`docs/WEB-RUNTIME-DISTRIBUTION.md`](../../../../../docs/WEB-RUNTIME-DISTRIBUTION.md).

The release workflow resolves the public key from the configured key ID and
fails if that committed file is absent. A public key added here is a trust
anchor, not an ordinary generated build artifact; follow the documented
rotation procedure and never overwrite an old key in place.
