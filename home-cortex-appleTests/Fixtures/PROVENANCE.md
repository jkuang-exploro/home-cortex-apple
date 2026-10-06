These four JSON files are byte-for-byte copies of `home-cortex/schemas/client_interface/v1/vectors/` at backend commit `734ca94ebaa073f7435738631c9c2e0ac1fa9496` (frozen protocol 1.0 / schema 1). Tests derive software-only and error scenarios explicitly from these vectors; the originals remain unmodified. No production credentials are present.

The public TLS certificate fixtures are test-only certificates generated locally with OpenSSL. Their signing keys are not included. They exercise trust, hostname, key mismatch, certificate validity, and malformed DER rejection.
