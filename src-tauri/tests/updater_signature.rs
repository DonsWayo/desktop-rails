//! The signatures `desktop-rails-tool updater sign` produces must be the ones the
//! updater will accept.
//!
//! Everything about the signing side lives in Node (packaging/lib/minisign.mjs),
//! because no minisign binary is installed anywhere this project builds. That
//! leaves a seam: a signer and a verifier written from the same reading of the
//! format will agree with each other whether or not the reading was right. This
//! test closes it by verifying with `minisign-verify` — the crate
//! tauri-plugin-updater itself calls — through exactly the steps the plugin
//! takes in `verify_signature`:
//!
//!     base64-decode the configured pubkey  -> PublicKey::decode
//!     base64-decode the manifest signature -> Signature::decode
//!     public_key.verify(bytes, &signature, true)
//!
//! The fixtures were produced by packaging/sign-update.sh, since ported to
//! `desktop-rails-tool updater sign` over the same signer, with a throwaway key.
//! Only the public half is committed; nothing is ever signed with that key
//! outside this directory.

use std::path::{Path, PathBuf};
use std::process::Command;

use minisign_verify::{PublicKey, Signature};

fn fixtures() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("tests")
        .join("fixtures")
        .join("updater")
}

/// The plugin stores both the pubkey and the signature base64-encoded, and
/// decodes them to minisign's own text before parsing. Anything that skips this
/// step verifies a different byte string than the shipped app will.
fn decode_base64(encoded: &str) -> String {
    use base64::Engine;
    String::from_utf8(
        base64::engine::general_purpose::STANDARD
            .decode(encoded.trim())
            .expect("the fixture should be base64"),
    )
    .expect("a minisign file is UTF-8 text")
}

fn verify(pubkey_base64: &str, signature_base64: &str, bytes: &[u8]) -> Result<(), String> {
    let public_key = PublicKey::decode(&decode_base64(pubkey_base64)).map_err(|e| e.to_string())?;
    let signature =
        Signature::decode(&decode_base64(signature_base64)).map_err(|e| e.to_string())?;

    // `allow_legacy = true` is what the plugin passes, so a legacy ("Ed")
    // signature would be accepted there too — this must not be stricter than
    // the thing it stands in for.
    public_key
        .verify(bytes, &signature, true)
        .map_err(|e| e.to_string())
}

#[test]
fn a_signature_from_the_packaging_scripts_verifies() {
    let dir = fixtures();
    let pubkey = std::fs::read_to_string(dir.join("pubkey.b64")).unwrap();
    let signature = std::fs::read_to_string(dir.join("artifact.bin.sig")).unwrap();
    let artifact = std::fs::read(dir.join("artifact.bin")).unwrap();

    verify(&pubkey, &signature, &artifact)
        .expect("minisign-verify should accept what updater sign produced");
}

#[test]
fn a_tampered_artifact_is_rejected() {
    let dir = fixtures();
    let pubkey = std::fs::read_to_string(dir.join("pubkey.b64")).unwrap();
    let signature = std::fs::read_to_string(dir.join("artifact.bin.sig")).unwrap();
    let mut artifact = std::fs::read(dir.join("artifact.bin")).unwrap();

    artifact[10] ^= 0x01;

    assert!(
        verify(&pubkey, &signature, &artifact).is_err(),
        "a single flipped bit must not verify"
    );
}

#[test]
fn a_truncated_artifact_is_rejected() {
    let dir = fixtures();
    let pubkey = std::fs::read_to_string(dir.join("pubkey.b64")).unwrap();
    let signature = std::fs::read_to_string(dir.join("artifact.bin.sig")).unwrap();
    let artifact = std::fs::read(dir.join("artifact.bin")).unwrap();

    assert!(
        verify(&pubkey, &signature, &artifact[..artifact.len() - 1]).is_err(),
        "a short download must not verify"
    );
}

#[test]
fn a_signature_from_another_key_is_rejected() {
    // Same artifact, same signature, a public key that did not sign it. This is
    // the case that matters most: it is what an attacker serving their own
    // build from a hijacked endpoint would produce.
    let dir = fixtures();
    let signature = std::fs::read_to_string(dir.join("artifact.bin.sig")).unwrap();
    let artifact = std::fs::read(dir.join("artifact.bin")).unwrap();

    // A real, well-formed minisign key: the one in minisign-verify's own docs.
    let other = "untrusted comment: minisign public key E7620F1842B4E81F\n\
                 RWQf6LRCGA9i53mlYecO4IzT51TGPpvWucNSCh1CBM0QTaLn73Y7GFO3\n";
    use base64::Engine;
    let other = base64::engine::general_purpose::STANDARD.encode(other);

    assert!(
        verify(&other, &signature, &artifact).is_err(),
        "a bundle signed by a different key must not verify"
    );
}

/// The manifest `updater sign` writes has to be the one the plugin reads.
///
/// `RemoteRelease` has a hand-written `Deserialize` rather than a derived one —
/// it accepts two different shapes, parses the version itself and insists on
/// RFC 3339 for `pub_date` — so "looks like the documented JSON" is not the same
/// as "parses". This runs the plugin's own deserializer over a manifest the
/// packaging scripts produced, and then verifies the artifact with the
/// signature the plugin's own accessor hands back for a platform.
#[test]
fn the_manifest_the_packaging_scripts_write_is_the_one_the_plugin_reads() {
    use tauri_plugin_updater::RemoteRelease;

    let dir = fixtures();
    let manifest = std::fs::read_to_string(dir.join("latest.json")).unwrap();
    let release: RemoteRelease =
        serde_json::from_str(&manifest).expect("the plugin must be able to parse our manifest");

    assert_eq!(release.version.to_string(), "1.2.0");
    assert_eq!(
        release.notes.as_deref(),
        Some("A release, for the purposes of this test.")
    );
    assert!(release.pub_date.is_some(), "pub_date must be RFC 3339");

    // "darwin", not "macos" — the plugin's own naming, and the mistake that
    // makes an update silently read as "nothing available".
    assert_eq!(
        release
            .download_url("darwin-aarch64")
            .expect("the manifest must carry this platform")
            .as_str(),
        "https://downloads.example.com/1.2.0/Ledger.app.tar.gz"
    );
    assert!(
        release.download_url("macos-aarch64").is_err(),
        "a platform key the plugin does not use should not be present"
    );

    let signature = release.signature("darwin-aarch64").unwrap();
    let artifact = std::fs::read(dir.join("artifact.bin")).unwrap();
    let pubkey = std::fs::read_to_string(dir.join("pubkey.b64")).unwrap();

    verify(&pubkey, signature, &artifact)
        .expect("the signature the plugin would pull from the manifest must verify");
}

/// The fixtures above pin the format, but they were signed once. This signs
/// something now, with whatever `packaging/lib` currently does, and checks that
/// too — so a change to the signer that breaks the format fails here rather
/// than in a shipped app.
///
/// Skipped rather than failed where Node is not on PATH: this crate builds
/// without it, and the packaging scripts are not part of the shell.
#[test]
fn what_the_signer_produces_today_still_verifies() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR")).parent().unwrap();
    let cli = root.join("packaging").join("lib").join("updater-cli.mjs");

    if Command::new("node").arg("--version").output().is_err() {
        eprintln!("skipping: node is not available");
        return;
    }

    let dir = std::env::temp_dir().join("desktop-rails-updater-signature-test");
    std::fs::remove_dir_all(&dir).ok();
    std::fs::create_dir_all(&dir).unwrap();

    let secret = dir.join("test.key");
    let public = dir.join("test.pub");
    let artifact = dir.join("bundle.tar.gz");
    let signature = dir.join("bundle.tar.gz.sig");
    std::fs::write(&artifact, b"a bundle, for the purposes of this test").unwrap();

    let node = |args: Vec<String>| {
        let output = Command::new("node")
            .arg(&cli)
            .args(&args)
            .output()
            .expect("node should run");
        assert!(
            output.status.success(),
            "node {:?} failed: {}",
            args,
            String::from_utf8_lossy(&output.stderr)
        );
        String::from_utf8(output.stdout).unwrap()
    };

    let s = |p: &Path| p.display().to_string();

    node(vec![
        "generate".into(),
        "--secret".into(),
        s(&secret),
        "--public".into(),
        s(&public),
        "--password".into(),
        String::new(),
    ]);
    node(vec![
        "sign".into(),
        "--key".into(),
        s(&secret),
        "--artifact".into(),
        s(&artifact),
        "--sig".into(),
        s(&signature),
        "--password".into(),
        String::new(),
    ]);
    let pubkey = node(vec!["pubkey".into(), "--public".into(), s(&public)]);

    let bytes = std::fs::read(&artifact).unwrap();
    verify(
        &pubkey,
        &std::fs::read_to_string(&signature).unwrap(),
        &bytes,
    )
    .expect("a freshly signed artifact should verify");

    let mut tampered = bytes.clone();
    tampered[0] ^= 0x01;
    assert!(
        verify(
            &pubkey,
            &std::fs::read_to_string(&signature).unwrap(),
            &tampered
        )
        .is_err(),
        "a freshly signed artifact must not verify once changed"
    );

    std::fs::remove_dir_all(&dir).ok();
}
