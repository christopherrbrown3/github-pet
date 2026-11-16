# PR50 hostile pack launches, 51bd398ee921397568c28abd98a0c4f0bdb3bb9b
binary sha256 a4c976ba03a28c6ba5207d92d6ceccb582d41295fcf2ba13ef26a509ceb702a0
mode: GITHUB_PET_PACK_DIR=<pack> GitHubPet --render-snapshots <dir> (fixtures, throwaway suite, self-quit)

## normal
stored id (escaped): qa-normal-pack
exit 0; renders 208
launch line (escaped): GitHubPet: mascot pack qa-normal-pack loaded from /private/tmp/claude-501/-Users-chris-github-pet-…
launch line code points: 99, utf8 bytes 101
result: FAIL defaults domains changed {'dev.github-pet.scope-simulation.42111.913E1B41-4BD5-4E93-8713-6243572C02CE.plist', 'dev.github-pet.scope-simulation.42111.D12C5510-965E-484B-A313-4E260C0189CD.plist', 'dev.github-pet.scope-simulation.42111.ECFB87D5-334E-4757-8C31-309CE1408505.plist', 'dev.github-pet.scope-simulation.42111.FA65E4D0-B42F-46E8-84F1-4C89C15EE0FB.plist', 'dev.github-pet.scope-simulation.42111.1F84F994-A2EC-4B7F-B6CD-7ACA77EB29F7.plist', 'dev.github-pet.scope-simulation.42111.28FC556F-EDD5-4C02-AB9B-26403A154C22.plist', 'dev.github-pet.scope-simulation.42111.B9467B79-AE37-4D7C-A6BA-41E7252DF3DF.plist', 'dev.github-pet.scope-simulation.42111.5D89460E-14DA-4721-B33C-403C23B063F2.plist', 'dev.github-pet.scope-simulation.42111.892E14E4-C75A-4D2E-B31B-9A7D0E00F1DD.plist', 'dev.github-pet.scope-simulation.42111.167A38E8-43B7-46F3-A125-0EC4F672743E.plist', 'dev.github-pet.scope-simulation.42111.ADF6569F-1ED7-4F80-B908-4C87D5EBCA00.plist', 'dev.github-pet.scope-simulation.42111.6FFA67E8-2FFB-4517-AD30-B9851C6F41E9.plist', 'dev.github-pet.scope-simulation.42111.CD1C5040-E3A2-4A21-9F5C-321BD56A2042.plist', 'dev.github-pet.scope-simulation.42111.DB0B0F11-F38C-4928-9E08-3A366ABD1DCB.plist', 'dev.github-pet.scope-simulation.42111.01F178A2-BF91-4227-90D8-2D200CA38C22.plist', 'dev.github-pet.render-snapshots.42131.plist', 'dev.github-pet.scope-simulation.42111.CFD501B6-2A66-41E9-ACAD-57CF4D9EDB6B.plist', 'dev.github-pet.scope-simulation.42111.8BAECF5D-3ECB-425D-B12C-17EE624A378A.plist', 'dev.github-pet.scope-simulation.42111.DB4CB182-703C-46A5-89F4-D93CA1C84B4D.plist', 'dev.github-pet.scope-simulation.42111.6AF61F2E-C544-43A2-8566-F523C086A7E7.plist', 'dev.github-pet.scope-simulation.42111.8350CD83-7AF2-48EB-BB7B-9190CDE3C8BB.plist', 'dev.github-pet.scope-simulation.42111.19612066-E6E4-4940-AC94-7A6733CC98FB.plist', 'dev.github-pet.scope-simulation.42111.68A38C89-05D2-417A-A5ED-BAA1D483C631.plist'}

## how-to
stored id (escaped): x\u{202E}evil\u{000A}\u{001B}[31mGitHubPet: mascot pack trusted
exit 0; renders 208
launch line (escaped): GitHubPet: mascot pack xevil [31mGitHubPet: mascot pack trusted loaded from /private/tmp/claude-501/-Users-chris-github-pet-…
launch line code points: 125, utf8 bytes 127
result: FAIL defaults domains changed {'dev.github-pet.render-snapshots.44870.plist'}

## newline
stored id (escaped): line1\u{000A}GitHubPet: mascot pack trusted\u{000D}\u{000A}line3\u{2028}line4\u{2029}end
exit 0; renders 208
launch line (escaped): GitHubPet: mascot pack line1 GitHubPet: mascot pack trusted line3 line4… loaded from /private/tmp/claude-501/-Users-chris-github-pet-…
launch line code points: 134, utf8 bytes 138
result: FAIL defaults domains changed {'dev.github-pet.render-snapshots.46618.plist'}

## ansi
stored id (escaped): \u{001B}[31mred\u{001B}[0m \u{001B}]0;title\u{0007} \u{009B}2J c1csi
exit 0; renders 208
launch line (escaped): GitHubPet: mascot pack [31mred [0m ]0;title 2J c1csi loaded from /private/tmp/claude-501/-Users-chris-github-pet-…
launch line code points: 114, utf8 bytes 116
result: FAIL defaults domains changed {'dev.github-pet.render-snapshots.47149.plist'}

## rtl
stored id (escaped): abc\u{202E}def\u{202A}ghi\u{2066}jkl\u{2069}\u{200E}mno\u{200F}\u{061C}end
exit 0; renders 208
launch line (escaped): GitHubPet: mascot pack abcdefghijklmnoend loaded from /private/tmp/claude-501/-Users-chris-github-pet-…
launch line code points: 103, utf8 bytes 105
result: FAIL defaults domains changed {'dev.github-pet.render-snapshots.48110.plist'}

## zero-width
stored id (escaped): a\u{200B}b\u{200C}c\u{200D}d\u{FEFF}e\u{2060}f\u{00AD}g
exit 0; renders 208
launch line (escaped): GitHubPet: mascot pack abcdefg loaded from /private/tmp/claude-501/-Users-chris-github-pet-…
launch line code points: 92, utf8 bytes 94
result: FAIL defaults domains changed {'dev.github-pet.render-snapshots.51210.plist'}

## long-ascii
stored id (escaped): AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
exit 0; renders 208
launch line (escaped): GitHubPet: mascot pack AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA… loaded from /private/tmp/claude-501/-Users-chris-github-pet-…
launch line code points: 134, utf8 bytes 138
result: FAIL defaults domains changed {'dev.github-pet.render-snapshots.51860.plist'}

## long-emoji
stored id (escaped): 👨\u{200D}👩\u{200D}👧👨\u{200D}👩\u{200D}👧👨\u{200D}👩\u{200D}👧👨\u{200D}👩\u{200D}👧👨\u{200D}👩\u{200D}👧👨\u{200D}👩\u{200D}👧👨\u{200D}👩\u{200D}👧👨\u{200D}👩\u{200D}👧👨\u{200D}👩\u{200D}👧👨\u{200D}👩\u{200D}👧👨\u{200D}👩
exit 0; renders 208
launch line (escaped): GitHubPet: mascot pack 👨👩👧👨👩👧👨👩👧👨👩👧👨👩👧👨👩👧👨👩👧👨👩👧👨👩👧👨👩👧👨👩👧👨👩👧👨👩👧👨👩👧👨👩👧👨👩👧… loaded from /private/tmp/claude-501/-Users-chris-github-pet-…
launch line code points: 134, utf8 bytes 282
result: FAIL defaults domains changed {'dev.github-pet.render-check.52533.plist', 'dev.github-pet.render-snapshots.52484.plist'}

## combining
stored id (escaped): é́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́
exit 0; renders 208
launch line (escaped): GitHubPet: mascot pack é́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́ loaded from /private/tmp/claude-501/-Users-chris-github-pet-…
launch line code points: 341, utf8 bytes 598
result: FAIL defaults domains changed {'dev.github-pet.render-snapshots.53068.plist'}

## combining-many
stored id (escaped): é́́́́́́́́́é́́́́́́́́́é́́́́́́́́́é́́́́́́́́́é́́́́́́́́́é́́́́́́́́́é́́́́́́́́́é́́́́́́́́́é́́́́́́́́́é́́́́́́́́́é́́́́́́́́́é́́́́́́́́́é́́́́́́́́́é́́́́́́́́́é́́́́́́́́́é́́́́́́́́́é́́́́́́́́́é́́́́́́́́́é
exit 0; renders 208
launch line (escaped): GitHubPet: mascot pack é́́́́́́́́́é́́́́́́́́́é́́́́́́́́́é́́́́́́́́́é́́́́́́́́́é́́́́́́́́́é́́́́́́́́́é́́́́́́́́́é́́́́́́́́́é́́́́́́́́́é́́́́́́́́́é́́́́́́́́́é́́́́́́́́́é́́́́́́́́́é́́́́́́́́́é́́́́́́́́́é́́́́́́́́́é́́́́́́́́́é́́́́́́́́́é́́́́́́́́́é́́́́́́́́́é́́́́́́́́́é́́́́́́́́́é́ loaded from /private/tmp/claude-501/-Users-chris-github-pet-…
launch line code points: 341, utf8 bytes 575
result: FAIL label has 256 code points beyond the cap (graphemes judged by hand); defaults domains changed {'dev.github-pet.render-snapshots.53935.plist'}

## empty-after
stored id (escaped): \u{202E}\u{200B}\u{000A}\u{0009}  \u{001B}\u{0000}\u{2028}
exit 0; renders 208
launch line (escaped): GitHubPet: mascot pack (unnamed pack) loaded from /private/tmp/claude-501/-Users-chris-github-pet-…
launch line code points: 99, utf8 bytes 101
result: FAIL defaults domains changed {'dev.github-pet.render-snapshots.55826.plist', 'dev.github-pet.render-snapshots.55625.plist'}

## empty
stored id (escaped): 
exit 0; renders 208
launch line (escaped): GitHubPet: mascot pack (unnamed pack) loaded from /private/tmp/claude-501/-Users-chris-github-pet-…
launch line code points: 99, utf8 bytes 101
result: FAIL defaults domains changed {'dev.github-pet.render-snapshots.56852.plist', 'dev.github-pet.render-snapshots.57507.plist'}

## hostile-dir
stored id (escaped): qa-dir-pack
exit 0; renders 208
launch line (escaped): GitHubPet: mascot pack qa-dir-pack loaded from /private/tmp/claude-501/-Users-chris-github-pet-…
launch line code points: 96, utf8 bytes 98
result: FAIL defaults domains changed {'dev.github-pet.render-snapshots.57777.plist'}

## error-path
stored id (escaped): qa-error-path
exit 0; renders 199
launch line (escaped): GitHubPet: mascot placeholder (pack rejected: unsafe path '../ [2Jevil.png')
launch line code points: 76, utf8 bytes 76
result: FAIL defaults domains changed {'dev.github-pet.render-snapshots.59270.plist', 'dev.github-pet.render-snapshots.59493.plist'}

## error-state
stored id (escaped): qa-error-state
exit 0; renders 208
launch line (escaped): GitHubPet: mascot pack qa-error-state loaded from /private/tmp/claude-501/-Users-chris-github-pet-…
launch line code points: 99, utf8 bytes 101
result: FAIL hostile pack was not rejected; defaults domains changed {'dev.github-pet.render-snapshots.59711.plist'}

saved build pids before ['1493', '31897'] after ['1493', '31897']
mechanical failures: 15 (grapheme cap and visual output also judged by hand)
