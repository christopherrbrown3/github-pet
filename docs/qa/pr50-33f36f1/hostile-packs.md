# PR50 hostile pack launches, 33f36f12a3f51b87d58df2c907a5cb8690d4ca63
binary sha256 b679ae386950cca40b14ff08ded98ca045f79ff13ef3ce341712dcb9f173f011
mode: GITHUB_PET_PACK_DIR=<pack> GitHubPet --render-snapshots <dir> (fixtures, throwaway suite, self-quit)

## normal
stored id (escaped): qa-normal-pack
exit 0; renders 208; empty own domain plist left: True
launch line (escaped): GitHubPet: mascot pack qa-normal-pack loaded from /private/tmp/claude-501/-Users-chris-github-pet-…
launch line code points: 99, utf8 bytes 101
result: ok

## how-to
stored id (escaped): x\u{202E}evil\u{000A}\u{001B}[31mGitHubPet: mascot pack trusted
exit 0; renders 208; empty own domain plist left: True
launch line (escaped): GitHubPet: mascot pack xevil [31mGitHubPet: mascot pack trusted loaded from /private/tmp/claude-501/-Users-chris-github-pet-…
launch line code points: 125, utf8 bytes 127
result: ok

## newline
stored id (escaped): line1\u{000A}GitHubPet: mascot pack trusted\u{000D}\u{000A}line3\u{2028}line4\u{2029}end
exit 0; renders 208; empty own domain plist left: True
launch line (escaped): GitHubPet: mascot pack line1 GitHubPet: mascot pack trusted line3 line4… loaded from /private/tmp/claude-501/-Users-chris-github-pet-…
launch line code points: 134, utf8 bytes 138
result: ok

## ansi
stored id (escaped): \u{001B}[31mred\u{001B}[0m \u{001B}]0;title\u{0007} \u{009B}2J c1csi
exit 0; renders 208; empty own domain plist left: True
launch line (escaped): GitHubPet: mascot pack [31mred [0m ]0;title 2J c1csi loaded from /private/tmp/claude-501/-Users-chris-github-pet-…
launch line code points: 114, utf8 bytes 116
result: ok

## rtl
stored id (escaped): abc\u{202E}def\u{202A}ghi\u{2066}jkl\u{2069}\u{200E}mno\u{200F}\u{061C}end
exit 0; renders 208; empty own domain plist left: True
launch line (escaped): GitHubPet: mascot pack abcdefghijklmnoend loaded from /private/tmp/claude-501/-Users-chris-github-pet-…
launch line code points: 103, utf8 bytes 105
result: ok

## zero-width
stored id (escaped): a\u{200B}b\u{200C}c\u{200D}d\u{FEFF}e\u{2060}f\u{00AD}g
exit 0; renders 208; empty own domain plist left: True
launch line (escaped): GitHubPet: mascot pack abcdefg loaded from /private/tmp/claude-501/-Users-chris-github-pet-…
launch line code points: 92, utf8 bytes 94
result: ok

## long-ascii
stored id (escaped): AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
exit 0; renders 208; empty own domain plist left: True
launch line (escaped): GitHubPet: mascot pack AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA… loaded from /private/tmp/claude-501/-Users-chris-github-pet-…
launch line code points: 134, utf8 bytes 138
result: ok

## long-emoji
stored id (escaped): 👨\u{200D}👩\u{200D}👧👨\u{200D}👩\u{200D}👧👨\u{200D}👩\u{200D}👧👨\u{200D}👩\u{200D}👧👨\u{200D}👩\u{200D}👧👨\u{200D}👩\u{200D}👧👨\u{200D}👩\u{200D}👧👨\u{200D}👩\u{200D}👧👨\u{200D}👩\u{200D}👧👨\u{200D}👩\u{200D}👧👨\u{200D}👩
exit 0; renders 208; empty own domain plist left: True
launch line (escaped): GitHubPet: mascot pack 👨👩👧👨👩👧👨👩👧👨👩👧👨👩👧👨👩👧👨👩👧👨👩👧👨👩👧👨👩👧👨👩👧👨👩👧👨👩👧👨👩👧👨👩👧👨👩👧… loaded from /private/tmp/claude-501/-Users-chris-github-pet-…
launch line code points: 134, utf8 bytes 282
result: ok

## combining
stored id (escaped): é́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́
exit 0; renders 208; empty own domain plist left: True
launch line (escaped): GitHubPet: mascot pack é́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́… loaded from /private/tmp/claude-501/-Users-chris-github-pet-…
launch line code points: 342, utf8 bytes 601
result: ok

## scalar-cap-300
stored id (escaped): á́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́
exit 0; renders 208; empty own domain plist left: True
launch line (escaped): GitHubPet: mascot pack á́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́… loaded from /private/tmp/claude-501/-Users-chris-github-pet-…
launch line code points: 342, utf8 bytes 601
result: ok

## scalar-cap-256
stored id (escaped): á́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́
exit 0; renders 208; empty own domain plist left: True
launch line (escaped): GitHubPet: mascot pack á́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́ loaded from /private/tmp/claude-501/-Users-chris-github-pet-…
launch line code points: 341, utf8 bytes 598
result: ok

## scalar-cap-257
stored id (escaped): á́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́
exit 0; renders 208; empty own domain plist left: True
launch line (escaped): GitHubPet: mascot pack á́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́… loaded from /private/tmp/claude-501/-Users-chris-github-pet-…
launch line code points: 342, utf8 bytes 601
result: ok

## combining-many
stored id (escaped): é́́́́́́́́́é́́́́́́́́́é́́́́́́́́́é́́́́́́́́́é́́́́́́́́́é́́́́́́́́́é́́́́́́́́́é́́́́́́́́́é́́́́́́́́́é́́́́́́́́́é́́́́́́́́́é́́́́́́́́́é́́́́́́́́́é́́́́́́́́́é́́́́́́́́́é́́́́́́́́́é́́́́́́́́́é́́́́́́́́́é
exit 0; renders 208; empty own domain plist left: True
launch line (escaped): GitHubPet: mascot pack é́́́́́́́́́é́́́́́́́́́é́́́́́́́́́é́́́́́́́́́é́́́́́́́́́é́́́́́́́́́é́́́́́́́́́é́́́́́́́́́é́́́́́́́́́é́́́́́́́́́é́́́́́́́́́é́́́́́́́́́é́́́́́́́́́é́́́́́́́́́é́́́́́́́́́é́́́́́́́́́é́́́́́́́́́é́́́́́́́́́é́́́́́́́́́é́́́́́́́́́é́́́́́́́́́é́́́́́́́́́é́́́́́́́́́é́… loaded from /private/tmp/claude-501/-Users-chris-github-pet-…
launch line code points: 342, utf8 bytes 578
result: ok

## empty-after
stored id (escaped): \u{202E}\u{200B}\u{000A}\u{0009}  \u{001B}\u{0000}\u{2028}
exit 0; renders 208; empty own domain plist left: True
launch line (escaped): GitHubPet: mascot pack (unnamed pack) loaded from /private/tmp/claude-501/-Users-chris-github-pet-…
launch line code points: 99, utf8 bytes 101
result: ok

## empty
stored id (escaped): 
exit 0; renders 208; empty own domain plist left: True
launch line (escaped): GitHubPet: mascot pack (unnamed pack) loaded from /private/tmp/claude-501/-Users-chris-github-pet-…
launch line code points: 99, utf8 bytes 101
result: ok

## hostile-dir
stored id (escaped): qa-dir-pack
exit 0; renders 208; empty own domain plist left: True
launch line (escaped): GitHubPet: mascot pack qa-dir-pack loaded from /private/tmp/claude-501/-Users-chris-github-pet-…
launch line code points: 96, utf8 bytes 98
result: ok

## error-path
stored id (escaped): qa-error-path
exit 0; renders 199; empty own domain plist left: True
launch line (escaped): GitHubPet: mascot placeholder (pack rejected: unsafe path '../ [2Jevil.png')
launch line code points: 76, utf8 bytes 76
result: ok

## error-missing
stored id (escaped): qa-error-missing
exit 0; renders 199; empty own domain plist left: True
launch line (escaped): GitHubPet: mascot placeholder (pack rejected: unsafe path 'frames/ [31mmissing GitHubPet: trustedfile.png')
launch line code points: 107, utf8 bytes 107
result: ok

saved build pids before ['1493', '21468', '31897'] after ['1493', '21468', '31897']
mechanical failures: 0 (grapheme cap and visual output also judged by hand)
