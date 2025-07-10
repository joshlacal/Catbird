# Task: Add Missing Content Warnings on Embeds

## Priority: MEDIUM

## Issue Description
Content warnings are missing on embedded content, potentially exposing users to unwanted content.

## Investigation Steps
1. Review embed view implementations
2. Check content labeling system
3. Examine moderation settings integration
4. Test with various embed types

## Key Files to Examine
- `Catbird/Features/Feed/Views/Components/PostEmbed.swift`
- `Catbird/Features/Feed/Views/Components/ExternalEmbedView.swift`
- `Catbird/Features/Feed/Views/Components/RecordEmbedView.swift`
- `Catbird/Features/Feed/Views/Components/ContentLabelView.swift`

## Expected Outcome
All embedded content should respect user content warning preferences.