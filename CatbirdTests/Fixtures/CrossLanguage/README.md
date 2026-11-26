# Cross-language Circle fixtures (copied from catbird-mls)

These four files are byte-for-byte copies of
`catbird-mls/tests/fixtures/rust_*.json`, regenerated on the Rust side at
catbird-mls `56ffa7012c8e` ("Regenerate cross-language Circle fixtures with
an at:space/ Space URI"). `CrossLanguageFixtureTests.swift` reads them
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
   `cd catbird-mls && CATBIRD_REGEN_FIXTURES=1 cargo test --test circles_cross_language regenerate_cross_language_fixtures`
2. Copy the four files here unchanged (no reformatting; the tests compare bytes):
   `cp ../catbird-mls/tests/fixtures/rust_{circle_key_record,circle_post_record,author_mailbox_keys,cross_language_manifest_TEST_ONLY}.json CatbirdTests/Fixtures/CrossLanguage/`
3. Update the catbird-mls revision above and run
   `xcodebuild test ... -only-testing:CatbirdTests/CrossLanguageFixtureTests`.

SHA-256 at copy time:

    24fa130ec47a98b2114f61a3297abcbf54f8d0b52d9ada3a4c8366997b3be2c0  rust_author_mailbox_keys.json
    1de9f0a7eaab750f95d3b7b2bea507d49aacfadd0fa92f031b72746d426273f8  rust_circle_key_record.json
    4ce4a575e81e8b72bb5b5a31ac0107a4b3dbf2eeb427b2ffd72a4a9a8519b43a  rust_circle_post_record.json
    e43417ca79ea690108076e42f671f56d31602233a43d581c15068024641dcf8e  rust_cross_language_manifest_TEST_ONLY.json
