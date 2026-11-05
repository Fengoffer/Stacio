use std::io;

use tokio::io::{AsyncRead, AsyncWrite, AsyncWriteExt as _};
use tokio_rustls::rustls;
use tokio_rustls::rustls::client::danger::ServerCertVerifier;
use tokio_rustls::rustls::pki_types::ServerName;

pub type TlsStream<S> = tokio_rustls::client::TlsStream<S>;

pub async fn upgrade<S>(
    stream: S,
    server_name: &str,
    ignore_certificate: bool,
) -> io::Result<(TlsStream<S>, x509_cert::Certificate)>
where
    S: Unpin + AsyncRead + AsyncWrite,
{
    let mut tls_stream = {
        let verifier = certificate_verifier(ignore_certificate)?;
        let mut config = rustls::client::ClientConfig::builder()
            .dangerous()
            .with_custom_certificate_verifier(verifier)
            .with_no_client_auth();

        // This adds support for the SSLKEYLOGFILE env variable (https://wiki.wireshark.org/TLS#using-the-pre-master-secret)
        config.key_log = std::sync::Arc::new(rustls::KeyLogFile::new());

        // Disable TLS resumption because it’s not supported by some services such as CredSSP.
        //
        // > The CredSSP Protocol does not extend the TLS wire protocol. TLS session resumption is not supported.
        //
        // source: https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-cssp/385a7489-d46b-464c-b224-f7340e308a5c
        config.resumption = rustls::client::Resumption::disabled();

        let config = std::sync::Arc::new(config);

        let domain = ServerName::try_from(server_name.to_owned()).map_err(io::Error::other)?;

        tokio_rustls::TlsConnector::from(config)
            .connect(domain, stream)
            .await?
    };

    tls_stream.flush().await?;

    let tls_cert = {
        use x509_cert::der::Decode as _;

        let cert = tls_stream
            .get_ref()
            .1
            .peer_certificates()
            .and_then(|certificates| certificates.first())
            .ok_or_else(|| io::Error::other("peer certificate is missing"))?;

        x509_cert::Certificate::from_der(cert).map_err(io::Error::other)?
    };

    Ok((tls_stream, tls_cert))
}

fn certificate_verifier(
    ignore_certificate: bool,
) -> io::Result<std::sync::Arc<dyn ServerCertVerifier>> {
    if ignore_certificate {
        return Ok(std::sync::Arc::new(danger::NoCertificateVerification));
    }

    let native = rustls_native_certs::load_native_certs();
    let mut roots = rustls::RootCertStore::empty();
    let (accepted, _) = roots.add_parsable_certificates(native.certs);
    if accepted == 0 {
        return Err(io::Error::other(format!(
            "native certificate store contains no usable roots ({} load errors)",
            native.errors.len()
        )));
    }

    let verifier = rustls::client::WebPkiServerVerifier::builder(std::sync::Arc::new(roots))
        .build()
        .map_err(io::Error::other)?;
    Ok(verifier)
}

/// Report the TLS version and cipher suite negotiated for `stream`.
pub fn negotiated<S>(stream: &TlsStream<S>) -> crate::NegotiatedTls {
    let (_, connection) = stream.get_ref();
    crate::NegotiatedTls {
        version: connection
            .protocol_version()
            .map(|version| format!("{version:?}")),
        cipher_suite: connection
            .negotiated_cipher_suite()
            .map(|suite| format!("{:?}", suite.suite())),
    }
}

mod danger {
    use tokio_rustls::rustls::client::danger::{
        HandshakeSignatureValid, ServerCertVerified, ServerCertVerifier,
    };
    use tokio_rustls::rustls::{DigitallySignedStruct, Error, SignatureScheme, pki_types};

    #[derive(Debug)]
    pub(super) struct NoCertificateVerification;

    impl ServerCertVerifier for NoCertificateVerification {
        fn verify_server_cert(
            &self,
            _: &pki_types::CertificateDer<'_>,
            _: &[pki_types::CertificateDer<'_>],
            _: &pki_types::ServerName<'_>,
            _: &[u8],
            _: pki_types::UnixTime,
        ) -> Result<ServerCertVerified, Error> {
            Ok(ServerCertVerified::assertion())
        }

        fn verify_tls12_signature(
            &self,
            _: &[u8],
            _: &pki_types::CertificateDer<'_>,
            _: &DigitallySignedStruct,
        ) -> Result<HandshakeSignatureValid, Error> {
            Ok(HandshakeSignatureValid::assertion())
        }

        fn verify_tls13_signature(
            &self,
            _: &[u8],
            _: &pki_types::CertificateDer<'_>,
            _: &DigitallySignedStruct,
        ) -> Result<HandshakeSignatureValid, Error> {
            Ok(HandshakeSignatureValid::assertion())
        }

        fn supported_verify_schemes(&self) -> Vec<SignatureScheme> {
            vec![
                SignatureScheme::RSA_PKCS1_SHA1,
                SignatureScheme::ECDSA_SHA1_Legacy,
                SignatureScheme::RSA_PKCS1_SHA256,
                SignatureScheme::ECDSA_NISTP256_SHA256,
                SignatureScheme::RSA_PKCS1_SHA384,
                SignatureScheme::ECDSA_NISTP384_SHA384,
                SignatureScheme::RSA_PKCS1_SHA512,
                SignatureScheme::ECDSA_NISTP521_SHA512,
                SignatureScheme::RSA_PSS_SHA256,
                SignatureScheme::RSA_PSS_SHA384,
                SignatureScheme::RSA_PSS_SHA512,
                SignatureScheme::ED25519,
                SignatureScheme::ED448,
            ]
        }
    }
}

#[cfg(test)]
mod tests {
    use super::certificate_verifier;
    use tokio_rustls::rustls::pki_types::{CertificateDer, ServerName, UnixTime};

    #[test]
    fn ignored_certificate_policy_accepts_an_untrusted_certificate() {
        let verifier = certificate_verifier(true).expect("ignore verifier");

        let result = verifier.verify_server_cert(
            &CertificateDer::from(vec![0_u8]),
            &[],
            &ServerName::try_from("rdp.example.test").expect("server name"),
            &[],
            UnixTime::now(),
        );

        assert!(result.is_ok());
    }

    #[test]
    fn strict_certificate_policy_rejects_a_malformed_certificate() {
        let verifier = certificate_verifier(false).expect("strict verifier");

        let result = verifier.verify_server_cert(
            &CertificateDer::from(vec![0_u8]),
            &[],
            &ServerName::try_from("rdp.example.test").expect("server name"),
            &[],
            UnixTime::now(),
        );

        assert!(result.is_err());
    }
}
