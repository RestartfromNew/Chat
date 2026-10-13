# XEdDSA primitive dependency
Vendored unchanged from https://github.com/signalapp/libsignal-protocol-c at 3a83a4f4ed2302ff6e68ab569c88793b50c22d28.
Only its curve25519 primitive sources are compiled; no Signal session implementation is integrated.
The upstream repository is archived. License: GPLv3, see LICENSE and upstream licensing notices.
Wrapper exposes only xed25519_sign / xed25519_verify, signing raw 32-byte SPK with a clamped X25519 identity scalar.
This dependency requires a maintenance/license review before distribution.
