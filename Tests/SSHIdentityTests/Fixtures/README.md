# Test-only keys

Generated with `ssh-keygen` solely for `OpenSSHKeyImporterTests`. They protect
nothing and must never be authorized on a real server.

| File | Command options |
|---|---|
| `plain` | `-t ed25519 -N '' -C plain@fixture` |
| `aes256` | `-t ed25519 -N 'correct horse' -Z aes256-ctr` (ssh-keygen's default 16 rounds) |
| `aes128-ctr`, `aes256-cbc`, `aes128-gcm`, `aes256-gcm`, `chacha20` | `plain` re-encrypted: `ssh-keygen -p -P '' -N 'correct horse' -a 2 -Z <cipher>` (`aes128-gcm@openssh.com`, `aes256-gcm@openssh.com`, `chacha20-poly1305@openssh.com`; ChaCha20 must be refused) |
| `rsa`, `ecdsa-pem` | unsupported algorithm and PEM format |
| `plain-cert.pub` | a user certificate for `plain.pub` |
