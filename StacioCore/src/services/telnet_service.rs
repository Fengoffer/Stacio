const IAC: u8 = 255;
const DONT: u8 = 254;
const DO: u8 = 253;
const WONT: u8 = 252;
const WILL: u8 = 251;
const SB: u8 = 250;
const SE: u8 = 240;

#[derive(Debug, Clone, PartialEq, Eq)]
enum TelnetFilterState {
    Data,
    Iac,
    Negotiation(u8),
    Subnegotiation,
    SubnegotiationIac,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TelnetNegotiationFilter {
    state: TelnetFilterState,
}

impl TelnetNegotiationFilter {
    pub fn new() -> Self {
        Self {
            state: TelnetFilterState::Data,
        }
    }

    pub fn filter_read(&mut self, input: &[u8]) -> TelnetFilteredRead {
        let mut output = Vec::with_capacity(input.len());
        let mut responses = Vec::new();

        for &byte in input {
            match self.state {
                TelnetFilterState::Data => {
                    if byte == IAC {
                        self.state = TelnetFilterState::Iac;
                    } else {
                        output.push(byte);
                    }
                }
                TelnetFilterState::Iac => {
                    if byte == IAC {
                        output.push(IAC);
                        self.state = TelnetFilterState::Data;
                    } else if matches!(byte, DO | DONT | WILL | WONT) {
                        self.state = TelnetFilterState::Negotiation(byte);
                    } else if byte == SB {
                        self.state = TelnetFilterState::Subnegotiation;
                    } else {
                        self.state = TelnetFilterState::Data;
                    }
                }
                TelnetFilterState::Negotiation(command) => {
                    responses.extend(telnet_refusal_for(command, byte));
                    self.state = TelnetFilterState::Data;
                }
                TelnetFilterState::Subnegotiation => {
                    if byte == IAC {
                        self.state = TelnetFilterState::SubnegotiationIac;
                    }
                }
                TelnetFilterState::SubnegotiationIac => {
                    if byte == SE {
                        self.state = TelnetFilterState::Data;
                    } else {
                        self.state = TelnetFilterState::Subnegotiation;
                    }
                }
            }
        }

        TelnetFilteredRead { output, responses }
    }
}

impl Default for TelnetNegotiationFilter {
    fn default() -> Self {
        Self::new()
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TelnetFilteredRead {
    pub output: Vec<u8>,
    pub responses: Vec<u8>,
}

pub fn telnet_refusal_for(command: u8, option: u8) -> Vec<u8> {
    match command {
        DO => vec![IAC, WONT, option],
        WILL => vec![IAC, DONT, option],
        _ => Vec::new(),
    }
}

pub fn filter_telnet_read(input: &[u8]) -> TelnetFilteredRead {
    TelnetNegotiationFilter::new().filter_read(input)
}

#[cfg(test)]
mod tests {
    use super::{filter_telnet_read, telnet_refusal_for, TelnetNegotiationFilter};

    #[test]
    fn telnet_filter_strips_negotiation_and_refuses_remote_options() {
        let input = vec![b'H', b'i', 255, 251, 1, 255, 253, 3, b'\r', b'\n'];

        let filtered = filter_telnet_read(&input);

        assert_eq!(filtered.output, b"Hi\r\n".to_vec());
        assert_eq!(filtered.responses, vec![255, 254, 1, 255, 252, 3]);
    }

    #[test]
    fn telnet_filter_preserves_escaped_iac_byte() {
        let filtered = filter_telnet_read(&[b'A', 255, 255, b'B']);

        assert_eq!(filtered.output, vec![b'A', 255, b'B']);
        assert!(filtered.responses.is_empty());
    }

    #[test]
    fn telnet_stateful_filter_keeps_split_subnegotiation_out_of_output() {
        let mut filter = TelnetNegotiationFilter::new();

        let first = filter.filter_read(&[b'H', 255, 250, 24, b'X']);
        let second = filter.filter_read(&[b'Y', 255, 240, b'i']);

        assert_eq!(first.output, b"H".to_vec());
        assert!(first.responses.is_empty());
        assert_eq!(second.output, b"i".to_vec());
        assert!(second.responses.is_empty());
    }

    #[test]
    fn telnet_refusal_has_no_plaintext_command_or_secret() {
        let refusal = telnet_refusal_for(253, 24);
        let debug = format!("{refusal:?}");

        assert_eq!(refusal, vec![255, 252, 24]);
        assert!(!debug.contains("telnet "));
        assert!(!debug.contains("password"));
        assert!(!debug.contains("secret"));
    }
}
