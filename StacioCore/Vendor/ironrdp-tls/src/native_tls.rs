use std::io;

use tokio::io::{AsyncRead, AsyncWrite, AsyncWriteExt as _};

pub type TlsStream<S> = tokio_native_tls::TlsStream<S>;

pub async fn upgrade<S>(
    stream: S,
    server_name: &str,
    ignore_certificate: bool,
) -> io::Result<(TlsStream<S>, x509_cert::Certificate)>
where
    S: Unpin + AsyncRead + AsyncWrite,
{
    let mut tls_stream = {
        let mut builder = tokio_native_tls::native_tls::TlsConnector::builder();
        builder
            .danger_accept_invalid_certs(ignore_certificate)
            .danger_accept_invalid_hostnames(ignore_certificate);
        let connector = builder
            .build()
            .map(tokio_native_tls::TlsConnector::from)
            .map_err(io::Error::other)?;

        connector
            .connect(server_name, stream)
            .await
            .map_err(io::Error::other)?
    };

    tls_stream.flush().await?;

    let tls_cert = {
        use x509_cert::der::Decode as _;

        let cert = tls_stream
            .get_ref()
            .peer_certificate()
            .map_err(io::Error::other)?
            .ok_or_else(|| io::Error::other("peer certificate is missing"))?;
        let cert = cert.to_der().map_err(io::Error::other)?;

        x509_cert::Certificate::from_der(&cert).map_err(io::Error::other)?
    };

    Ok((tls_stream, tls_cert))
}

/// The `native-tls` backend does not expose the negotiated version or cipher.
pub fn negotiated<S>(_stream: &TlsStream<S>) -> crate::NegotiatedTls {
    crate::NegotiatedTls::default()
}
