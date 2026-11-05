#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Socks5Address {
    Ipv4([u8; 4]),
    Ipv6([u8; 16]),
    Domain(String),
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Socks5ClientHello {
    pub consumed: usize,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Socks5ConnectRequest {
    pub target_address: Socks5Address,
    pub target_port: u16,
    pub consumed: usize,
}

impl Socks5ConnectRequest {
    pub fn target_host(&self) -> String {
        match &self.target_address {
            Socks5Address::Ipv4(octets) => octets
                .iter()
                .map(u8::to_string)
                .collect::<Vec<_>>()
                .join("."),
            Socks5Address::Ipv6(octets) => std::net::Ipv6Addr::from(*octets).to_string(),
            Socks5Address::Domain(domain) => domain.clone(),
        }
    }
}

pub const SOCKS5_NO_AUTH_RESPONSE: [u8; 2] = [0x05, 0x00];
pub const SOCKS5_NO_ACCEPTABLE_METHODS_RESPONSE: [u8; 2] = [0x05, 0xff];
pub const SOCKS5_CONNECT_SUCCESS_RESPONSE: [u8; 10] = [0x05, 0x00, 0x00, 0x01, 0, 0, 0, 0, 0, 0];
pub const SOCKS5_GENERAL_FAILURE_RESPONSE: [u8; 10] = [0x05, 0x01, 0x00, 0x01, 0, 0, 0, 0, 0, 0];
pub const SOCKS5_COMMAND_NOT_SUPPORTED_RESPONSE: [u8; 10] =
    [0x05, 0x07, 0x00, 0x01, 0, 0, 0, 0, 0, 0];
pub const SOCKS5_ADDRESS_TYPE_NOT_SUPPORTED_RESPONSE: [u8; 10] =
    [0x05, 0x08, 0x00, 0x01, 0, 0, 0, 0, 0, 0];

pub fn parse_socks5_client_hello(frame: &[u8]) -> Result<Socks5ClientHello, String> {
    if frame.len() < 2 {
        return Err("incomplete_frame".to_string());
    }
    if frame[0] != 0x05 {
        return Err("invalid_version".to_string());
    }

    let method_count = frame[1] as usize;
    let consumed = 2 + method_count;
    if frame.len() < consumed {
        return Err("incomplete_frame".to_string());
    }
    if !frame[2..consumed].contains(&0x00) {
        return Err("unsupported_auth_method".to_string());
    }

    Ok(Socks5ClientHello { consumed })
}

pub fn parse_socks5_connect_request(frame: &[u8]) -> Result<Socks5ConnectRequest, String> {
    if frame.len() < 4 {
        return Err("incomplete_frame".to_string());
    }
    if frame[0] != 0x05 {
        return Err("invalid_version".to_string());
    }
    if frame[1] != 0x01 {
        return Err("unsupported_command".to_string());
    }
    if frame[2] != 0x00 {
        return Err("invalid_reserved_byte".to_string());
    }

    match frame[3] {
        0x01 => parse_ipv4_connect_request(frame),
        0x03 => parse_domain_connect_request(frame),
        0x04 => parse_ipv6_connect_request(frame),
        _ => Err("unsupported_address_type".to_string()),
    }
}

pub fn socks5_failure_response(error: &str) -> &'static [u8; 10] {
    match error {
        "unsupported_command" => &SOCKS5_COMMAND_NOT_SUPPORTED_RESPONSE,
        "unsupported_address_type" => &SOCKS5_ADDRESS_TYPE_NOT_SUPPORTED_RESPONSE,
        _ => &SOCKS5_GENERAL_FAILURE_RESPONSE,
    }
}

fn parse_ipv4_connect_request(frame: &[u8]) -> Result<Socks5ConnectRequest, String> {
    if frame.len() < 10 {
        return Err("incomplete_frame".to_string());
    }

    Ok(Socks5ConnectRequest {
        target_address: Socks5Address::Ipv4([frame[4], frame[5], frame[6], frame[7]]),
        target_port: u16::from_be_bytes([frame[8], frame[9]]),
        consumed: 10,
    })
}

fn parse_domain_connect_request(frame: &[u8]) -> Result<Socks5ConnectRequest, String> {
    if frame.len() < 5 {
        return Err("incomplete_frame".to_string());
    }

    let domain_len = frame[4] as usize;
    if domain_len == 0 {
        return Err("invalid_domain".to_string());
    }
    let consumed = 5 + domain_len + 2;
    if frame.len() < consumed {
        return Err("incomplete_frame".to_string());
    }

    let domain = String::from_utf8(frame[5..5 + domain_len].to_vec())
        .map_err(|_| "invalid_domain".to_string())?;

    Ok(Socks5ConnectRequest {
        target_address: Socks5Address::Domain(domain),
        target_port: u16::from_be_bytes([frame[5 + domain_len], frame[6 + domain_len]]),
        consumed,
    })
}

fn parse_ipv6_connect_request(frame: &[u8]) -> Result<Socks5ConnectRequest, String> {
    if frame.len() < 22 {
        return Err("incomplete_frame".to_string());
    }

    let mut octets = [0_u8; 16];
    octets.copy_from_slice(&frame[4..20]);
    Ok(Socks5ConnectRequest {
        target_address: Socks5Address::Ipv6(octets),
        target_port: u16::from_be_bytes([frame[20], frame[21]]),
        consumed: 22,
    })
}

#[cfg(test)]
mod socks5_tests {
    use super::{parse_socks5_client_hello, parse_socks5_connect_request, Socks5Address};

    #[test]
    fn accepts_no_auth_client_hello() {
        let result = parse_socks5_client_hello(&[0x05, 0x02, 0x02, 0x00]).expect("hello");

        assert_eq!(result.consumed, 4);
    }

    #[test]
    fn rejects_client_hello_without_no_auth_method() {
        let error = parse_socks5_client_hello(&[0x05, 0x01, 0x02]).expect_err("no supported auth");

        assert!(error.contains("unsupported_auth_method"));
    }

    #[test]
    fn parses_domain_connect_request() {
        let result = parse_socks5_connect_request(&[
            0x05, 0x01, 0x00, 0x03, 0x0b, b'd', b'b', b'.', b'i', b'n', b't', b'e', b'r', b'n',
            b'a', b'l', 0x15, 0x38,
        ])
        .expect("domain connect");

        assert_eq!(result.target_host(), "db.internal");
        assert_eq!(result.target_port, 5432);
        assert_eq!(result.consumed, 18);
    }

    #[test]
    fn parses_ipv4_connect_request() {
        let result =
            parse_socks5_connect_request(&[0x05, 0x01, 0x00, 0x01, 192, 168, 1, 10, 0x00, 0x50])
                .expect("ipv4 connect");

        assert_eq!(
            result.target_address,
            Socks5Address::Ipv4([192, 168, 1, 10])
        );
        assert_eq!(result.target_host(), "192.168.1.10");
        assert_eq!(result.target_port, 80);
        assert_eq!(result.consumed, 10);
    }

    #[test]
    fn parses_ipv6_connect_request() {
        let result = parse_socks5_connect_request(&[
            0x05, 0x01, 0x00, 0x04, 0x20, 0x01, 0x0d, 0xb8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1,
            0x01, 0xbb,
        ])
        .expect("ipv6 connect");

        assert_eq!(
            result.target_address,
            Socks5Address::Ipv6([0x20, 0x01, 0x0d, 0xb8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1])
        );
        assert_eq!(result.target_host(), "2001:db8::1");
        assert_eq!(result.target_port, 443);
        assert_eq!(result.consumed, 22);
    }

    #[test]
    fn rejects_udp_and_bind_as_unsupported_commands() {
        for command in [0x02, 0x03] {
            let error = parse_socks5_connect_request(&[
                0x05, command, 0x00, 0x01, 127, 0, 0, 1, 0x00, 0x50,
            ])
            .expect_err("unsupported command");

            assert!(error.contains("unsupported_command"));
        }
    }

    #[test]
    fn rejects_unknown_address_type() {
        let error =
            parse_socks5_connect_request(&[0x05, 0x01, 0x00, 0x05, 127, 0, 0, 1, 0x00, 0x50])
                .expect_err("unsupported address type");

        assert!(error.contains("unsupported_address_type"));
    }

    #[test]
    fn rejects_malformed_domain_request() {
        let error = parse_socks5_connect_request(&[0x05, 0x01, 0x00, 0x03, 0x0b, b'd', b'b', b'.'])
            .expect_err("truncated domain");

        assert!(error.contains("incomplete_frame"));
    }
}
