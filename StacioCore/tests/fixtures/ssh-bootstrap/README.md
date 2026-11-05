# Local SSH bootstrap echo captures

`readline-zle.hex` contains tab-separated name, raw PTY bytes (hex), and expected
visible bytes (hex). Captured from real macOS `/bin/bash` readline and `/bin/zsh`
ZLE with a 24-row PTY at 24, 80 and 160 columns. `before_init` queues the first
128 bytes before shell exec; `after_prompt` waits for the interactive prompt.
All cases completely wrote and executed `bootstrap.txt`, including OSC7 output.
Bash captures used `+H` to isolate echo rendering from Bash 3.2 history expansion;
the new production bootstrap separately avoids that issue with a space after `$!`.

Only OSC7 hostname/path metadata was replaced with `fixture-host/srv/fixture`.
No credentials or remote data are present. Expected output preserves login text,
native prompt bytes, terminal mode toggles and OSC7; only injected command echo
and redraw are absent. Hex keeps control sequences visible in source control.

The 24/80-column ZLE captures contain multi-screen redraws and cursor movement,
so deleting ANSI sequences and CR/LF alone cannot recreate the original command.
The captured bootstrap predates the two whitespace-only `$! ;` fixes; each test
uses its actual captured input as the filter pattern, while the production
bootstrap and current real PTY smoke cover the new input.
