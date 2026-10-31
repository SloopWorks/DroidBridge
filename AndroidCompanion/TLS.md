# Local TLS server identity

The companion accepts only TLS1.2/1.3 at127.0.0.1:37841, forwarded through the
explicit owned ADB transport. ADB authorization does not authenticate an ordinary
Android application occupying that port. No HTTP fallback or trust-on-first-use
path exists. The product manifest disallows outgoing cleartext traffic too.

The phone's private key is installation-stable EC P-256 in AndroidKeyStore and
non-exportable. Conscrypt's TLS implementation signs an already-hashed transcript
through NONEwithECDSA, so its key authorization includes DIGEST_NONE and SHA256;
this is not an unencrypted or unsigned TLS mode. The reviewed fixed-profile
TlsLeafCertificate builder uses JCA SHA256withECDSA, not an application crypto
primitive, and has no arbitrary ASN.1/extension input. The leaf has a positive
random128-bit serial, named-curve P256 SPKI, critical digitalSignature key usage,
critical CA=false basic constraints, serverAuth EKU, IP SAN127.0.0.1 and730-day
validity. CertificateFactory parses it and verifies signature, key identity and
profile before it can be presented or pinned.

The public DER and identity state are persisted atomically in app-private files.
Each rename fsyncs its file and parent directory before pin publication. A first
initialization interrupted before publication can finish with the same private
key; a ready identity cannot silently regenerate or rotate. Missing/changed
ready DER/key/pin or expiry fails closed. Changing the identity requires explicit
reset/re-pair; clearing app storage or uninstalling removes installation trust.
Do not automate such a reset as a connection retry. Updating with the same Android
signing key preserves app data and the TLS identity.

Phone UI pairing links contain exactly four fields:

```
droidbridge://pair?secret=<43-base64url>&expires=<unix-seconds>&device_id=<UUID>&server_pin=<64-lowercase-hex-SHA256-DER-leaf>
```

The fingerprint hashes the entire exact DER leaf certificate. It is conveyed by
the phone's trusted native UI, never learned from a listener/hello. The Mac must
validate this pin and its strict server TLS certificate policy before any HTTP
request, secret, bearer or content is sent. Bare secrets and old pinless links
are rejected. Pairing still requires the named Mac's explicit phone approval and
its120-second monotonic capability; an eight-character comparison code is only
a visual check and cannot authenticate TLS or pair by itself. Legacy Mac trust
without a saved pin requires explicit pairing again. Private keys, temporary
pairing links, credentials and shared content never belong in logs or evidence.

Two concurrent handshakes are admitted, with absolute three-second closure.
Existing bounded HTTP worker/read/response-write limits apply only after TLS
success. Stop closes owned sockets and cancels scheduled deadlines. The ordinary
INTERNET-only `attacker` module is an isolated QA application, excluded from the
product: it occupies the same loopback port with either plaintext or a different
valid serverAuth TLS identity, then captures bounded request bytes for independent
negative tests. It cannot access the real app's private key or files.
