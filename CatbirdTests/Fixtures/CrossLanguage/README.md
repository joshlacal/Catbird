# Cross-language Circle fixtures (copied from catbird-mls)

These four files are byte-for-byte copies of
`catbird-mls/tests/fixtures/rust_*.json`, regenerated on the Rust side at
catbird-mls `01571b9867ca` ("Regenerate cross-language Circle fixtures with
TID rkeys and real Space URIs") and copied from the workspace tip
`ceaf9b72e45b` (unchanged since). `CrossLanguageFixtureTests.swift` reads them
to prove that Swift's response slicing, typed decode, opener guards and
author-epoch parser accept what Rust emits, that the opener hands the FFI the
served bytes unchanged, and that the real FFI (the local CatbirdMLS
xcframework) derives the same post key and accepts the fixture's owner/Space
pair. A full FFI open needs an enrolled Labyrinth session, which a unit test
cannot create (see the tests' comments).

`rust_cross_language_manifest_TEST_ONLY.json` holds random, test-only key
material. It must never be copied anywhere outside a test-fixtures directory.

## Refresh procedure

1. Regenerate on the Rust side (only when the record shapes change):
   `cd catbird-mls && cargo test --test circles_cross_language regenerate_cross_language_fixtures -- --ignored`
2. Copy the four files here unchanged (no reformatting; the tests compare bytes):
   `cp ../catbird-mls/tests/fixtures/rust_{circle_key_record,circle_post_record,author_mailbox_keys,cross_language_manifest_TEST_ONLY}.json CatbirdTests/Fixtures/CrossLanguage/`
3. Update the catbird-mls revision above and run
   `xcodebuild test ... -only-testing:CatbirdTests/CrossLanguageFixtureTests`.

SHA-256 at copy time:

    b52a0f805426106bd8ac98bf7c91ab136c0747b3b5487a966598b62f5b1feae9  rust_author_mailbox_keys.json
    eddd2063977dc753fed028f86aa48d4059c2dc85da40070a70993b95bfc92638  rust_circle_key_record.json
    20a259c84c04f6a17ac5d6bb6e659ea59cd1d8cff92470b127b67bee7c2ef4c2  rust_circle_post_record.json
    217d5fd8c62adb90817cfea5a7608035f7e17d8945e79249391085bced041718  rust_cross_language_manifest_TEST_ONLY.json
