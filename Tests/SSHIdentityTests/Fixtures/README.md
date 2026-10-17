# Test-only keys

Generated with `ssh-keygen` solely for `OpenSSHKeyImporterTests`. They protect
nothing and must never be authorized on a real server.

| File | Command options |
|---|---|
| `plain` | `-t ed25519 -N '' -C plain@fixture` |
| `aes256` | `-t ed25519 -N 'correct horse' -Z aes256-ctr` (encrypted: must be refused) |
| `rsa`, `ecdsa-pem` | unsupported algorithm and PEM format |
| `plain-cert.pub` | a user certificate for `plain.pub` |
