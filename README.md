# fido2 authenticator library

![GitHub](https://img.shields.io/github/license/r4gus/ztap?style=flat-square)
![GitHub Workflow Status](https://img.shields.io/github/workflow/status/r4gus/ztap/CI?style=flat-square)

> _Warning_: NOT PRODUCTION READY!

## Getting started

Just add the library to your project and then call `pull-deps.sh` to pull
all dependencies.

> _Note_: For a working example see [Candy Stick](https://github.com/r4gus/candy-stick).

## Crypto

### Algorithms

This implementation will support exactly one signature algorithm,
namely [ECDSA](https://en.wikipedia.org/wiki/Elliptic_Curve_Digital_Signature_Algorithm) 
(Elyptic Curve Digital Signature algorithm) with SHA-256 as defined
by [COSE](https://www.iana.org/assignments/cose/cose.xhtml#algorithms) (-7).

### Key-Pairs

This project uses a very similar approch to [Solo1](https://github.com/solokeys/solo1/blob/master/docs/fido2-impl.md) to store
key-pairs. Instead of storing every key-pair on the device, the
authenticator stores a master secret `M` and uses it in combination
with a TRNG to generate new keys and derive previous keys. A 
random number `CTX` is generated, and placed in the `CREDENTIAL ID`
parameter. The Relying Party stores the `CREDENTIAL ID` after
the registration process and will issue it back to the
authenticator for subsequent authentications.

#### Registration

1. Generate `CTX` and derive a sub-key from `M` using `HKDF(CTX, M)`
2. Create a new key-pair `(pub, priv)` from the generated sub-key
3. Return the `CTX` and the public key `pub` to the Relying Party
4. The Relying Party stores `CTX` and `pub`

#### Authentication

1. The Relying Party issues a authentication request using `CTX`
2. The authenticator derives the key pair from `CTX` as stated above
3. Proceede normally as if `priv` was loaded from memory

> __TODO:__ Also MAC the CTX to ensure its integrity.

### Storing sensitive data

One problem to solve is how to store sensitive data in a secure way. Sensitive data includes the master secret,
the pin hash, and credentials (credentials are derived at the moment but maybe that should change to make them
discoverable).

#### Idea: Make PIN mandatory

Use the pin hash as key with AES-GCM to encrypt all sensitive data.

> Note: This is a general idea and might not be secure

##### On first boot

1. Create a random master secret (MS)
2. Create a default PIN (e.g. 1234) which should be changed by the user
3. Hash the PIN as defined by CTAP2 (PIN\_HASH) and use it to encrypt MS and PIN\_HASH
4. One can derive a subkey from the MS using HKDF to en-/decrypt all other sensitve data

##### Validating the PIN

After the client has sent the user entered PIN to the authenticator, the PIN is hashed and
used to decrypt the encrypted PIN\_HASH. If the calculated hash matches the encrypted hash,
everything is fine, otherwise the received PIN was incorrect.

If the hashes matched, decrypt the MS and use it as normal.
