#!/usr/bin/env python3
"""Deterministic String Catalog (.xcstrings) export, regional derivation, validation, and merge CLI for Catbird."""

from __future__ import annotations

import argparse
import copy
import json
import pathlib
import re
import shutil
import subprocess
import sys
import tempfile
from typing import Any

DEFAULT_REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
DEFAULT_SCRATCH_DIR = pathlib.Path(
    "/Users/joshlacalamito/.gemini/antigravity/brain/fe4b1af0-b869-4662-ab98-6de9c47c2617/scratch/l10n"
)

MAIN_LOCALIZABLE_REL = "Catbird/Resources/Localizable.xcstrings"
APP_SHORTCUTS_REL = "Catbird/Resources/AppShortcuts.xcstrings"

ALL_CATALOG_RELS = [
    MAIN_LOCALIZABLE_REL,
    APP_SHORTCUTS_REL,
    "Catbird/Resources/InfoPlist.xcstrings",
    "CatbirdFeedWidget/Localizable.xcstrings",
    "CatbirdFeedWidget/InfoPlist.xcstrings",
    "CatbirdNotificationWidget/Localizable.xcstrings",
    "CatbirdNotificationWidget/InfoPlist.xcstrings",
    "NotificationServiceExtension/Localizable.xcstrings",
    "NotificationServiceExtension/InfoPlist.xcstrings",
    "SharedDraftImporter/Localizable.xcstrings",
    "SharedDraftImporter/InfoPlist.xcstrings",
]

ALL_TARGET_LOCALES = [
    "ar",
    "ca",
    "cs",
    "da",
    "de",
    "el",
    "en-AU",
    "en-CA",
    "en-GB",
    "es",
    "es-419",
    "fi",
    "fr",
    "fr-CA",
    "he",
    "hi",
    "hr",
    "hu",
    "id",
    "it",
    "ja",
    "ko",
    "ms",
    "nb",
    "nl",
    "pl",
    "pt-BR",
    "pt-PT",
    "ro",
    "ru",
    "sk",
    "sv",
    "th",
    "tr",
    "uk",
    "vi",
    "zh-Hans",
    "zh-Hant",
    "zh-HK",
]

NUM_PLAIN_SHARDS = 10


def required_plural_categories(locale: str) -> list[str]:
    if locale == "ar":
        return ["zero", "one", "two", "few", "many", "other"]
    if locale == "he":
        return ["one", "two", "many", "other"]
    if locale in {"ru", "uk", "pl", "cs", "sk", "hr"}:
        return ["one", "few", "many", "other"]
    if locale in {"ja", "ko", "zh-Hans", "zh-Hant", "zh-HK", "th", "vi", "id", "ms", "tr"}:
        return ["other"]
    return ["one", "other"]


# Regexes for format specifiers, substitutions, AppShortcuts tokens, and XML entities
TOKEN_RE = re.compile(
    r"%%"
    r"|%#@([A-Za-z0-9_]+)@"
    r"|%arg"
    r"|%(?:([1-9]\d*)\$)?[-+#0 ]*(?:\d+|\*)?(?:\.(?:\d+|\*))?(hh|h|ll|l|q|z|j|t|L)?([@dDiuUxXoOfFeEgGaAcCsSp])"
    r"|%"
)
DOLLAR_BRACE_RE = re.compile(r"\$\{[A-Za-z0-9_.]+\}")
XML_ENTITY_RE = re.compile(r"&(?:amp|lt|gt|quot|apos);")

DEFAULT_PROTECTED_PATTERNS = [
    r"https?://[^\s\"')\]>]+",
    r"at://[^\s\"')\]>]+",
    r"did:[a-z0-9]+:[^\s\"')\]>]+",
    r"\$\{[A-Za-z0-9_.]+\}",
    r"%#@[A-Za-z0-9_]+@",
    r"%arg",
    r"%%",
    r"%(?:[1-9]\d*\$)?[-+#0 ]*(?:\d+|\*)?(?:\.(?:\d+|\*))?(?:hh|h|ll|l|q|z|j|t|L)?[@dDiuUxXoOfFeEgGaAcCsSp]",
    r"@[A-Za-z0-9_.-]+",
    r"\b(?:Catbird|Bluesky|ATProto|Passkey|Passkeys|Face ID|Touch ID|iCloud|App Store|TestFlight|MacBook|iPhone|iPad|Apple Watch|Siri|Spotlight|Klipy|Giphy|Tenor|Streamplace)\b",
]


def normalize_spec_type(length_mod: str | None, conv: str) -> str:
    lm = length_mod or ""
    if conv == "@":
        return "@"
    if conv in ("d", "D", "i"):
        if conv == "D":
            return "ld"
        return f"{lm}d"
    if conv in ("u", "U"):
        if conv == "U":
            return "lu"
        return f"{lm}u"
    if conv in ("f", "F", "e", "E", "g", "G", "a", "A"):
        return f"{lm}f"
    return f"{lm}{conv}"


def parse_format_signature(
    text: str,
    *,
    is_format_string: bool,
    allow_subst_refs: bool = False,
    allow_arg_token: bool = False,
) -> tuple[dict[int, str], set[str], bool, list[str]]:
    """
    Returns (arg_types_by_1based_pos, subst_names, has_arg_token, errors).
    If is_format_string is False, '%' is literal in Swift/Foundation unless source had specifiers;
    we still check that no accidental format specifiers (%@, %lld, %1$@, etc.) were introduced.
    """
    arg_types: dict[int, str] = {}
    subst_names: set[str] = set()
    has_arg_token = False
    errors: list[str] = []
    next_seq = 1

    for m in TOKEN_RE.finditer(text):
        tok = m.group(0)
        if tok == "%%":
            continue
        if m.group(1) is not None:
            if not allow_subst_refs:
                errors.append(f"unexpected substitution token {tok!r}")
            else:
                subst_names.add(m.group(1))
            continue
        if tok == "%arg":
            if not allow_arg_token:
                errors.append("unexpected '%arg' outside substitution variant")
            else:
                has_arg_token = True
            continue
        if tok == "%":
            if is_format_string:
                ctx = text[max(0, m.start() - 6) : min(len(text), m.end() + 10)]
                errors.append(f"unescaped bare '%' in format string near {ctx!r} (use '%%' for literal percent)")
            continue

        pos_str, length_mod, conv = m.group(2), m.group(3), m.group(4)
        if not is_format_string:
            errors.append(f"unexpected format specifier {tok!r} in non-format string")
            continue

        pos = int(pos_str) if pos_str is not None else next_seq
        if pos_str is None:
            next_seq += 1
        norm = normalize_spec_type(length_mod, conv)
        if pos in arg_types and arg_types[pos] != norm:
            errors.append(f"conflicting types for argument #{pos}: {arg_types[pos]} vs {norm}")
        arg_types[pos] = norm

    return arg_types, subst_names, has_arg_token, errors


def check_string_compatibility(
    src_text: str,
    tgt_text: str,
    *,
    label: str,
    allow_subst_refs: bool = False,
    allow_arg_token: bool = False,
) -> list[str]:
    errs: list[str] = []
    if src_text.strip() and not tgt_text.strip():
        errs.append(f"{label}: empty translation for non-empty source")
        return errs

    xml_m = XML_ENTITY_RE.search(tgt_text)
    if xml_m and not XML_ENTITY_RE.search(src_text):
        errs.append(f"{label}: contains XML entity {xml_m.group(0)!r}; write literal Unicode characters instead")

    # Check ${...} placeholders (e.g. ${applicationName}, ${account})
    src_braces = set(DOLLAR_BRACE_RE.findall(src_text))
    tgt_braces = set(DOLLAR_BRACE_RE.findall(tgt_text))
    if src_braces != tgt_braces:
        errs.append(f"{label}: ${{...}} token mismatch: source={sorted(src_braces)} vs target={sorted(tgt_braces)}")

    # Determine whether source is a format string
    probe_args, probe_subs, probe_arg_tok, _ = parse_format_signature(
        src_text,
        is_format_string=True,
        allow_subst_refs=allow_subst_refs,
        allow_arg_token=allow_arg_token,
    )
    is_fmt = bool(probe_args or probe_subs or probe_arg_tok or "%%" in src_text)

    src_args, src_subs, src_has_arg, src_errs = parse_format_signature(
        src_text,
        is_format_string=is_fmt,
        allow_subst_refs=allow_subst_refs,
        allow_arg_token=allow_arg_token,
    )
    assert not src_errs, f"Internal source format parse error on {label} ({src_text!r}): {src_errs}"

    tgt_args, tgt_subs, tgt_has_arg, tgt_errs = parse_format_signature(
        tgt_text,
        is_format_string=is_fmt,
        allow_subst_refs=allow_subst_refs,
        allow_arg_token=allow_arg_token,
    )
    for e in tgt_errs:
        errs.append(f"{label}: {e}")
    if errs:
        return errs

    if src_args != tgt_args:
        errs.append(f"{label}: format specifier mismatch: expected {src_args}, got {tgt_args}")
    if src_subs != tgt_subs:
        errs.append(f"{label}: substitution reference mismatch: expected {sorted(src_subs)}, got {sorted(tgt_subs)}")
    if src_has_arg != tgt_has_arg:
        errs.append(f"{label}: '%arg' presence mismatch: expected {src_has_arg}, got {tgt_has_arg}")

    return errs


def classify_xcstrings_entry(key: str, entry: dict[str, Any]) -> tuple[str, Any]:
    """Returns (kind, en_payload) for a translatable .xcstrings entry."""
    loc_en = entry.get("localizations", {}).get("en", {})
    if "stringSet" in loc_en:
        return "string_set", list(loc_en["stringSet"]["values"])
    if "substitutions" in loc_en:
        tmpl = loc_en["stringUnit"]["value"]
        subs_out = {}
        for sname, sbody in sorted(loc_en["substitutions"].items()):
            variants = {
                pcat: pbody["stringUnit"]["value"]
                for pcat, pbody in sbody["variations"]["plural"].items()
            }
            subs_out[sname] = {
                "argNum": sbody["argNum"],
                "formatSpecifier": sbody["formatSpecifier"],
                "variants": variants,
            }
        return "substitutions", {"template": tmpl, "substitutions": subs_out}
    if "variations" in loc_en and "plural" in loc_en["variations"]:
        variants = {
            pcat: pbody["stringUnit"]["value"]
            for pcat, pbody in loc_en["variations"]["plural"].items()
        }
        return "top_plural", variants
    if "stringUnit" in loc_en:
        return "plain", loc_en["stringUnit"]["value"]
    return "plain", key


def write_json(path: pathlib.Path, obj: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(obj, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")


def write_xcstrings(path: pathlib.Path, obj: dict[str, Any]) -> None:
    path.write_text(
        json.dumps(obj, indent=2, ensure_ascii=False, sort_keys=True, separators=(",", " : ")) + "\n",
        encoding="utf-8",
    )


# ---------------------------------------------------------------------------
# EXPORT
# ---------------------------------------------------------------------------
def cmd_export(args: argparse.Namespace) -> int:
    repo_root = pathlib.Path(args.repo_root)
    scratch_dir = pathlib.Path(args.scratch_dir)
    src_dir = scratch_dir / "source"
    src_dir.mkdir(parents=True, exist_ok=True)

    main_path = repo_root / MAIN_LOCALIZABLE_REL
    main_data = json.loads(main_path.read_text(encoding="utf-8"))
    main_strings = main_data.get("strings", {})

    plain_entries: list[dict[str, Any]] = []
    plural_entries: list[dict[str, Any]] = []

    for key in sorted(main_strings.keys()):
        entry = main_strings[key]
        if entry.get("shouldTranslate") is False:
            continue
        kind, payload = classify_xcstrings_entry(key, entry)
        comment = entry.get("comment") or ""
        if kind == "plain":
            plain_entries.append({"key": key, "source": payload, "comment": comment})
        elif kind in ("top_plural", "substitutions"):
            plural_entries.append({"key": key, "kind": kind, "comment": comment, "en": payload})
        else:
            raise ValueError(f"Unexpected entry kind {kind!r} in {MAIN_LOCALIZABLE_REL} for key {key!r}")

    # Partition plain_entries into 10 shards evenly
    total_plain = len(plain_entries)
    plain_index: dict[str, dict[str, Any]] = {}
    shards_meta: list[dict[str, Any]] = []
    idx_cursor = 0

    for shard_num in range(1, NUM_PLAIN_SHARDS + 1):
        # Distribute remainder across earliest shards if not divisible by 10
        base_size = total_plain // NUM_PLAIN_SHARDS
        extra = 1 if shard_num <= (total_plain % NUM_PLAIN_SHARDS) else 0
        count = base_size + extra
        slice_items = plain_entries[idx_cursor : idx_cursor + count]
        shard_name = f"plain_shard_{shard_num:02d}.tsv"
        shard_path = src_dir / shard_name
        lines: list[str] = []
        first_id = None
        last_id = None

        for offset, item in enumerate(slice_items):
            global_num = idx_cursor + offset + 1
            str_id = f"{global_num:04d}"
            if first_id is None:
                first_id = str_id
            last_id = str_id
            lines.append(
                f"{str_id}\t{json.dumps(item['source'], ensure_ascii=False)}\t{json.dumps(item['comment'], ensure_ascii=False)}"
            )
            plain_index[str_id] = {
                "id": str_id,
                "shard": shard_name,
                "key": item["key"],
                "source": item["source"],
                "comment": item["comment"],
            }

        shard_path.write_text("\n".join(lines) + "\n", encoding="utf-8")
        shards_meta.append(
            {
                "shard": shard_name,
                "count": count,
                "firstId": first_id,
                "lastId": last_id,
            }
        )
        idx_cursor += count

    write_json(
        src_dir / "plain_index.json",
        {
            "totalCount": total_plain,
            "shards": shards_meta,
            "entries": plain_index,
        },
    )

    # Number plural_entries P001..P161
    for i, pitem in enumerate(plural_entries, start=1):
        pitem["id"] = f"P{i:03d}"

    cldr_by_loc = {loc: required_plural_categories(loc) for loc in ALL_TARGET_LOCALES}
    write_json(
        src_dir / "plurals_main.json",
        {
            "sourceLanguage": "en",
            "catalog": MAIN_LOCALIZABLE_REL,
            "count": len(plural_entries),
            "cldrPluralCategoriesByLocale": cldr_by_loc,
            "items": plural_entries,
        },
    )

    # Export system_surfaces.json across the other 10 .xcstrings files
    system_items: list[dict[str, Any]] = []
    sys_counter = 0
    for rel in ALL_CATALOG_RELS:
        if rel == MAIN_LOCALIZABLE_REL:
            continue
        cpath = repo_root / rel
        cdata = json.loads(cpath.read_text(encoding="utf-8"))
        cstrings = cdata.get("strings", {})
        for key in sorted(cstrings.keys()):
            entry = cstrings[key]
            if entry.get("shouldTranslate") is False:
                continue
            sys_counter += 1
            kind, payload = classify_xcstrings_entry(key, entry)
            system_items.append(
                {
                    "id": f"S{sys_counter:03d}",
                    "catalog": rel,
                    "key": key,
                    "kind": kind,
                    "comment": entry.get("comment") or "",
                    "en": payload,
                }
            )

    write_json(
        src_dir / "system_surfaces.json",
        {
            "sourceLanguage": "en",
            "count": len(system_items),
            "items": system_items,
        },
    )

    schema_doc = """# Catbird Wave-2 Localization Translation Pack Schema

Each locale writes its translations under `translations/<locale>/`:

1. `plain_shard_01.tsv` .. `plain_shard_10.tsv`
   - One line per ID in the corresponding `source/plain_shard_XX.tsv`.
   - Exact 2-column TSV format: `ID<TAB>JSON_ENCODED_TRANSLATION`
   - Example: `0001\t"\\"%@\\" Feed"`

2. `plurals_main.json`
   - Either canonical object `{"locale": "<locale>", "items": [...]}` (matching `translations/en-GB/plurals_main.json`)
     OR compact ID-keyed object `{"P001": {"one": "...", "other": "..."}, "P059": {"template": "...", "substitutions": {"members": {"variants": {"one": "%arg ...", "other": "%arg ..."}}}}}`.
   - Must include the exact CLDR plural categories required for `<locale>` (listed in `source/plurals_main.json` under `cldrPluralCategoriesByLocale`).

3. `system_surfaces.json`
   - Either canonical object `{"locale": "<locale>", "items": [...]}` (matching `translations/en-GB/system_surfaces.json`)
     OR compact ID-keyed object:
     * `kind == "string_set"` (`AppShortcuts.xcstrings`): `"S001": ["phrase 1 with ${applicationName}", ...]`
     * `kind == "plain"`: `"S011": "Translated string"`
     * `kind == "top_plural"`: `"S016": {"one": "...", "other": "..."}` (using `<locale>`'s CLDR plural categories).

Validate any locale with:
`python3 Catbird/tools/l10n/xcstrings_pipeline.py validate --locale <locale>`
"""
    (src_dir / "SCHEMA.md").write_text(schema_doc, encoding="utf-8")

    print(f"Exported to {src_dir}:")
    for sm in shards_meta:
        print(f"  {sm['shard']}: {sm['count']} keys ({sm['firstId']}..{sm['lastId']})")
    print(f"  plurals_main.json: {len(plural_entries)} keys (P001..P{len(plural_entries):03d})")
    print(f"  system_surfaces.json: {len(system_items)} keys (S001..S{len(system_items):03d})")
    return 0


# ---------------------------------------------------------------------------
# NORMALIZE / LOAD TRANSLATION PACKS
# ---------------------------------------------------------------------------
def load_plain_shard_translations(tsv_path: pathlib.Path) -> tuple[dict[str, str], list[str]]:
    out: dict[str, str] = {}
    errs: list[str] = []
    if not tsv_path.exists():
        return out, [f"missing shard file {tsv_path.name}"]

    raw_lines = tsv_path.read_text(encoding="utf-8").splitlines()
    for lineno, line in enumerate(raw_lines, start=1):
        if not line.strip():
            continue
        parts = line.split("\t")
        if len(parts) != 2:
            errs.append(f"{tsv_path.name}:{lineno}: expected 2 tab-separated columns (ID\\tJSON_STRING), got {len(parts)}")
            continue
        str_id, raw_val = parts[0].strip(), parts[1].strip()
        try:
            val = json.loads(raw_val)
        except json.JSONDecodeError as exc:
            errs.append(f"{tsv_path.name}:{lineno} ({str_id}): invalid JSON string in col 2: {exc}")
            continue
        if not isinstance(val, str):
            errs.append(f"{tsv_path.name}:{lineno} ({str_id}): col 2 decoded to {type(val).__name__}, expected string")
            continue
        if str_id in out:
            errs.append(f"{tsv_path.name}:{lineno}: duplicate ID {str_id}")
            continue
        out[str_id] = val
    return out, errs


def normalize_plurals_pack(
    raw_obj: Any,
    src_items_by_id: dict[str, dict[str, Any]],
) -> tuple[dict[str, dict[str, Any]], list[str]]:
    """Returns mapping id -> normalized item dict."""
    out: dict[str, dict[str, Any]] = {}
    errs: list[str] = []

    if isinstance(raw_obj, dict) and isinstance(raw_obj.get("items"), list):
        entries = raw_obj["items"]
        for entry in entries:
            if not isinstance(entry, dict) or "id" not in entry:
                errs.append("plurals_main.json: item missing 'id'")
                continue
            pid = entry["id"]
            if pid in out:
                errs.append(f"plurals_main.json: duplicate id {pid}")
                continue
            out[pid] = entry
    elif isinstance(raw_obj, dict):
        for pid, body in raw_obj.items():
            if pid in ("locale", "requiredPluralCategories"):
                continue
            src_item = src_items_by_id.get(pid)
            if not src_item:
                out[pid] = {"id": pid}
                continue
            if src_item["kind"] == "top_plural":
                variants = body.get("variants") if isinstance(body, dict) and "variants" in body else body
                out[pid] = {"id": pid, "key": src_item["key"], "kind": "top_plural", "variants": variants}
            else:
                out[pid] = {
                    "id": pid,
                    "key": src_item["key"],
                    "kind": "substitutions",
                    "template": body.get("template") if isinstance(body, dict) else None,
                    "substitutions": body.get("substitutions") if isinstance(body, dict) else None,
                }
    else:
        errs.append("plurals_main.json: root must be a JSON object")

    return out, errs


def normalize_system_pack(
    raw_obj: Any,
    src_items_by_id: dict[str, dict[str, Any]],
) -> tuple[dict[str, dict[str, Any]], list[str]]:
    out: dict[str, dict[str, Any]] = {}
    errs: list[str] = []

    if isinstance(raw_obj, dict) and isinstance(raw_obj.get("items"), list):
        for entry in raw_obj["items"]:
            if not isinstance(entry, dict) or "id" not in entry:
                errs.append("system_surfaces.json: item missing 'id'")
                continue
            sid = entry["id"]
            if sid in out:
                errs.append(f"system_surfaces.json: duplicate id {sid}")
                continue
            out[sid] = entry
    elif isinstance(raw_obj, dict):
        for sid, body in raw_obj.items():
            if sid == "locale":
                continue
            src_item = src_items_by_id.get(sid)
            if not src_item:
                out[sid] = {"id": sid}
                continue
            kind = src_item["kind"]
            if kind == "string_set":
                vals = body.get("values") if isinstance(body, dict) else body
                out[sid] = {"id": sid, "catalog": src_item["catalog"], "key": src_item["key"], "kind": kind, "values": vals}
            elif kind == "plain":
                val = body.get("value") if isinstance(body, dict) else body
                out[sid] = {"id": sid, "catalog": src_item["catalog"], "key": src_item["key"], "kind": kind, "value": val}
            elif kind == "top_plural":
                variants = body.get("variants") if isinstance(body, dict) and "variants" in body else body
                out[sid] = {"id": sid, "catalog": src_item["catalog"], "key": src_item["key"], "kind": kind, "variants": variants}
    else:
        errs.append("system_surfaces.json: root must be a JSON object")

    return out, errs


# ---------------------------------------------------------------------------
# DERIVE
# ---------------------------------------------------------------------------
def match_case(source_word: str, replacement_lower: str) -> str:
    if source_word.isupper() and len(source_word) > 1:
        return replacement_lower.upper()
    if source_word[0].isupper() and source_word[1:].islower():
        return replacement_lower.capitalize()
    if source_word[0].isupper():
        return replacement_lower[0].upper() + replacement_lower[1:]
    return replacement_lower


class TextTransformer:
    def __init__(self, overrides: dict[str, Any] | None) -> None:
        overrides = overrides or {}
        prot = list(DEFAULT_PROTECTED_PATTERNS) + list(overrides.get("protected_patterns", []))
        self.protected_re = re.compile("|".join(f"(?:{p})" for p in prot))

        word_map: dict[str, str] = {
            k.lower(): v.lower() for k, v in overrides.get("word_replacements", {}).items()
        }
        self.word_map = word_map
        if word_map:
            escaped = sorted((re.escape(k) for k in word_map.keys()), key=len, reverse=True)
            # Negative lookbehind/lookahead for ASCII letters or hyphens where inappropriate; standard word boundary
            self.word_re: re.Pattern[str] | None = re.compile(
                r"(?<![A-Za-z])(" + "|".join(escaped) + r")(?![A-Za-z])",
                re.IGNORECASE,
            )
        else:
            self.word_re = None

        self.regex_rules: list[tuple[re.Pattern[str], str, bool]] = []
        for rule in overrides.get("regex_replacements", []):
            flags = 0
            flag_str = rule.get("flags", "")
            if "i" in flag_str:
                flags |= re.IGNORECASE
            if "m" in flag_str:
                flags |= re.MULTILINE
            self.regex_rules.append(
                (
                    re.compile(rule["pattern"], flags),
                    rule["replacement"],
                    bool(rule.get("allow_protected", False)),
                )
            )

        self.id_overrides: dict[str, Any] = dict(overrides.get("id_overrides", {}))

    def _transform_unprotected_segment(self, seg: str) -> str:
        out = seg
        if self.word_re is not None:
            out = self.word_re.sub(
                lambda m: match_case(m.group(0), self.word_map[m.group(0).lower()]),
                out,
            )
        for pat, repl, allow_prot in self.regex_rules:
            if not allow_prot:
                out = pat.sub(repl, out)
        return out

    def transform_text(self, text: str) -> str:
        if not self.word_re and not self.regex_rules:
            return text
        parts: list[str] = []
        last = 0
        for m in self.protected_re.finditer(text):
            if m.start() > last:
                parts.append(self._transform_unprotected_segment(text[last : m.start()]))
            parts.append(m.group(0))
            last = m.end()
        if last < len(text):
            parts.append(self._transform_unprotected_segment(text[last:]))
        out = "".join(parts)
        for pat, repl, allow_prot in self.regex_rules:
            if allow_prot:
                out = pat.sub(repl, out)
        return out


def adapt_plural_variants(base_variants: dict[str, str], target_cats: list[str], xform: TextTransformer) -> dict[str, str]:
    fallback = base_variants.get("other") or next(iter(base_variants.values()))
    out: dict[str, str] = {}
    for cat in target_cats:
        src_val = base_variants.get(cat, fallback)
        out[cat] = xform.transform_text(src_val)
    return out


def cmd_derive(args: argparse.Namespace) -> int:
    scratch_dir = pathlib.Path(args.scratch_dir)
    src_dir = scratch_dir / "source"
    base_loc = args.base
    target_loc = args.target
    target_dir = scratch_dir / "translations" / target_loc
    target_dir.mkdir(parents=True, exist_ok=True)

    overrides = {}
    if args.overrides:
        overrides = json.loads(pathlib.Path(args.overrides).read_text(encoding="utf-8"))
    xform = TextTransformer(overrides)

    plain_meta = json.loads((src_dir / "plain_index.json").read_text(encoding="utf-8"))
    plurals_src = json.loads((src_dir / "plurals_main.json").read_text(encoding="utf-8"))
    sys_src = json.loads((src_dir / "system_surfaces.json").read_text(encoding="utf-8"))
    target_cats = required_plural_categories(target_loc)

    changed_count = 0

    # 1. Derive plain_shard_01..10.tsv
    base_trans_dir = scratch_dir / "translations" / base_loc
    for sm in plain_meta["shards"]:
        shard_name = sm["shard"]
        if base_loc == "en":
            src_lines = (src_dir / shard_name).read_text(encoding="utf-8").splitlines()
            base_map = {}
            for line in src_lines:
                if not line.strip():
                    continue
                sid, raw_src, _ = line.split("\t")
                base_map[sid] = json.loads(raw_src)
        else:
            base_map, errs = load_plain_shard_translations(base_trans_dir / shard_name)
            if errs:
                raise RuntimeError(f"Base locale {base_loc} shard errors: {errs}")

        out_lines: list[str] = []
        for sid in sorted(base_map.keys()):
            base_val = base_map[sid]
            if sid in xform.id_overrides:
                new_val = xform.id_overrides[sid]
            else:
                new_val = xform.transform_text(base_val)
            if new_val != base_val:
                changed_count += 1
            out_lines.append(f"{sid}\t{json.dumps(new_val, ensure_ascii=False)}")
        (target_dir / shard_name).write_text("\n".join(out_lines) + "\n", encoding="utf-8")

    # 2. Derive plurals_main.json
    src_plurals_by_id = {it["id"]: it for it in plurals_src["items"]}
    if base_loc == "en":
        base_plurals_norm = {}
        for it in plurals_src["items"]:
            pid = it["id"]
            if it["kind"] == "top_plural":
                base_plurals_norm[pid] = {"id": pid, "key": it["key"], "kind": "top_plural", "variants": it["en"]}
            else:
                base_plurals_norm[pid] = {
                    "id": pid,
                    "key": it["key"],
                    "kind": "substitutions",
                    "template": it["en"]["template"],
                    "substitutions": it["en"]["substitutions"],
                }
    else:
        raw_bp = json.loads((base_trans_dir / "plurals_main.json").read_text(encoding="utf-8"))
        base_plurals_norm, errs = normalize_plurals_pack(raw_bp, src_plurals_by_id)
        if errs:
            raise RuntimeError(f"Base locale {base_loc} plurals errors: {errs}")

    out_plural_items: list[dict[str, Any]] = []
    for it in plurals_src["items"]:
        pid = it["id"]
        bitem = base_plurals_norm[pid]
        if pid in xform.id_overrides:
            ov = copy.deepcopy(xform.id_overrides[pid])
            if it["kind"] == "top_plural":
                variants = ov.get("variants", ov)
                out_plural_items.append({"id": pid, "key": it["key"], "kind": "top_plural", "variants": variants})
            else:
                out_plural_items.append(
                    {
                        "id": pid,
                        "key": it["key"],
                        "kind": "substitutions",
                        "template": ov["template"],
                        "substitutions": ov["substitutions"],
                    }
                )
            changed_count += 1
            continue

        if it["kind"] == "top_plural":
            new_vars = adapt_plural_variants(bitem["variants"], target_cats, xform)
            if new_vars != bitem["variants"]:
                changed_count += 1
            out_plural_items.append({"id": pid, "key": it["key"], "kind": "top_plural", "variants": new_vars})
        else:
            new_tmpl = xform.transform_text(bitem["template"])
            new_subs = {}
            sub_changed = new_tmpl != bitem["template"]
            for sname, sbody in bitem["substitutions"].items():
                src_sub_meta = it["en"]["substitutions"][sname]
                nvars = adapt_plural_variants(sbody["variants"], target_cats, xform)
                if nvars != sbody["variants"]:
                    sub_changed = True
                new_subs[sname] = {
                    "argNum": src_sub_meta["argNum"],
                    "formatSpecifier": src_sub_meta["formatSpecifier"],
                    "variants": nvars,
                }
            if sub_changed:
                changed_count += 1
            out_plural_items.append(
                {
                    "id": pid,
                    "key": it["key"],
                    "kind": "substitutions",
                    "template": new_tmpl,
                    "substitutions": new_subs,
                }
            )

    write_json(
        target_dir / "plurals_main.json",
        {
            "locale": target_loc,
            "requiredPluralCategories": target_cats,
            "items": out_plural_items,
        },
    )

    # 3. Derive system_surfaces.json
    src_sys_by_id = {it["id"]: it for it in sys_src["items"]}
    if base_loc == "en":
        base_sys_norm = {}
        for it in sys_src["items"]:
            sid = it["id"]
            if it["kind"] == "string_set":
                base_sys_norm[sid] = {**it, "values": list(it["en"])}
            elif it["kind"] == "plain":
                base_sys_norm[sid] = {**it, "value": it["en"]}
            elif it["kind"] == "top_plural":
                base_sys_norm[sid] = {**it, "variants": dict(it["en"])}
    else:
        raw_bs = json.loads((base_trans_dir / "system_surfaces.json").read_text(encoding="utf-8"))
        base_sys_norm, errs = normalize_system_pack(raw_bs, src_sys_by_id)
        if errs:
            raise RuntimeError(f"Base locale {base_loc} system_surfaces errors: {errs}")

    out_sys_items: list[dict[str, Any]] = []
    for it in sys_src["items"]:
        sid = it["id"]
        bitem = base_sys_norm[sid]
        base_header = {"id": sid, "catalog": it["catalog"], "key": it["key"], "kind": it["kind"]}
        if sid in xform.id_overrides:
            ov = copy.deepcopy(xform.id_overrides[sid])
            if it["kind"] == "string_set":
                vals = ov.get("values", ov) if isinstance(ov, dict) else ov
                out_sys_items.append({**base_header, "values": vals})
            elif it["kind"] == "plain":
                val = ov.get("value", ov) if isinstance(ov, dict) else ov
                out_sys_items.append({**base_header, "value": val})
            elif it["kind"] == "top_plural":
                variants = ov.get("variants", ov)
                out_sys_items.append({**base_header, "variants": variants})
            changed_count += 1
            continue

        if it["kind"] == "string_set":
            # Deduplicate while preserving order in case a word rule collapses two variants
            seen: set[str] = set()
            new_vals: list[str] = []
            for v in bitem["values"]:
                tv = xform.transform_text(v)
                if tv not in seen:
                    seen.add(tv)
                    new_vals.append(tv)
            if new_vals != bitem["values"]:
                changed_count += 1
            out_sys_items.append({**base_header, "values": new_vals})
        elif it["kind"] == "plain":
            nv = xform.transform_text(bitem["value"])
            if nv != bitem["value"]:
                changed_count += 1
            out_sys_items.append({**base_header, "value": nv})
        elif it["kind"] == "top_plural":
            nvars = adapt_plural_variants(bitem["variants"], target_cats, xform)
            if nvars != bitem["variants"]:
                changed_count += 1
            out_sys_items.append({**base_header, "variants": nvars})

    write_json(
        target_dir / "system_surfaces.json",
        {
            "locale": target_loc,
            "items": out_sys_items,
        },
    )

    print(f"Derived {target_loc} from {base_loc} -> {target_dir} ({changed_count} entries modified vs {base_loc})")
    return 0


# ---------------------------------------------------------------------------
# VALIDATE
# ---------------------------------------------------------------------------
def validate_locale_pack(scratch_dir: pathlib.Path, locale: str) -> tuple[bool, list[str], dict[str, Any]]:
    src_dir = scratch_dir / "source"
    loc_dir = scratch_dir / "translations" / locale
    errors: list[str] = []

    if locale not in ALL_TARGET_LOCALES:
        errors.append(f"unknown target locale {locale!r}; expected one of {ALL_TARGET_LOCALES}")
        return False, errors, {}

    if not loc_dir.exists():
        return False, [f"missing locale directory: {loc_dir}"], {}

    plain_meta = json.loads((src_dir / "plain_index.json").read_text(encoding="utf-8"))
    plurals_src = json.loads((src_dir / "plurals_main.json").read_text(encoding="utf-8"))
    sys_src = json.loads((src_dir / "system_surfaces.json").read_text(encoding="utf-8"))
    req_cats = required_plural_categories(locale)
    req_cat_set = set(req_cats)

    plain_entries_meta: dict[str, dict[str, Any]] = plain_meta["entries"]
    expected_by_shard: dict[str, set[str]] = {sm["shard"]: set() for sm in plain_meta["shards"]}
    for sid, meta in plain_entries_meta.items():
        expected_by_shard[meta["shard"]].add(sid)

    # 1. Validate all 10 plain TSV shards
    all_plain_translations: dict[str, str] = {}
    for sm in plain_meta["shards"]:
        shard_name = sm["shard"]
        shard_map, parse_errs = load_plain_shard_translations(loc_dir / shard_name)
        errors.extend(parse_errs)
        exp_ids = expected_by_shard[shard_name]
        got_ids = set(shard_map.keys())
        missing = sorted(exp_ids - got_ids)
        extra = sorted(got_ids - exp_ids)
        if missing:
            errors.append(f"{shard_name}: missing {len(missing)} IDs (first 5: {missing[:5]})")
        if extra:
            errors.append(f"{shard_name}: unexpected {len(extra)} IDs (first 5: {extra[:5]})")

        for sid in sorted(exp_ids & got_ids):
            src_text = plain_entries_meta[sid]["source"]
            tgt_text = shard_map[sid]
            errors.extend(check_string_compatibility(src_text, tgt_text, label=f"{shard_name}:{sid}"))
            all_plain_translations[sid] = tgt_text

    # 2. Validate plurals_main.json
    plurals_path = loc_dir / "plurals_main.json"
    src_plurals_by_id = {it["id"]: it for it in plurals_src["items"]}
    norm_plurals: dict[str, dict[str, Any]] = {}
    if not plurals_path.exists():
        errors.append("missing plurals_main.json")
    else:
        try:
            raw_p = json.loads(plurals_path.read_text(encoding="utf-8"))
            norm_plurals, p_errs = normalize_plurals_pack(raw_p, src_plurals_by_id)
            errors.extend(p_errs)
        except json.JSONDecodeError as exc:
            errors.append(f"plurals_main.json: invalid JSON: {exc}")

        exp_pids = set(src_plurals_by_id.keys())
        got_pids = set(norm_plurals.keys())
        if exp_pids - got_pids:
            miss = sorted(exp_pids - got_pids)
            errors.append(f"plurals_main.json: missing {len(miss)} IDs (first 5: {miss[:5]})")
        if got_pids - exp_pids:
            ext = sorted(got_pids - exp_pids)
            errors.append(f"plurals_main.json: unexpected {len(ext)} IDs (first 5: {ext[:5]})")

        for pid in sorted(exp_pids & got_pids):
            src_it = src_plurals_by_id[pid]
            tgt_it = norm_plurals[pid]
            if src_it["kind"] == "top_plural":
                variants = tgt_it.get("variants")
                if not isinstance(variants, dict):
                    errors.append(f"plurals_main:{pid}: expected 'variants' object")
                    continue
                got_cats = set(variants.keys())
                if got_cats != req_cat_set:
                    errors.append(
                        f"plurals_main:{pid}: CLDR plural categories {sorted(got_cats)} != required {req_cats} for {locale}"
                    )
                en_other = src_it["en"]["other"]
                for cat in req_cats:
                    if cat not in variants:
                        continue
                    vval = variants[cat]
                    if not isinstance(vval, str):
                        errors.append(f"plurals_main:{pid}.{cat}: expected string")
                        continue
                    errors.extend(
                        check_string_compatibility(en_other, vval, label=f"plurals_main:{pid}.{cat}")
                    )
            else:
                tmpl = tgt_it.get("template")
                subs = tgt_it.get("substitutions")
                if not isinstance(tmpl, str) or not isinstance(subs, dict):
                    errors.append(f"plurals_main:{pid}: expected 'template' string and 'substitutions' object")
                    continue
                en_tmpl = src_it["en"]["template"]
                en_subs = src_it["en"]["substitutions"]
                errors.extend(
                    check_string_compatibility(
                        en_tmpl,
                        tmpl,
                        label=f"plurals_main:{pid}.template",
                        allow_subst_refs=True,
                    )
                )
                if set(subs.keys()) != set(en_subs.keys()):
                    errors.append(
                        f"plurals_main:{pid}: substitution keys {sorted(subs.keys())} != {sorted(en_subs.keys())}"
                    )
                    continue
                for sname, en_sbody in en_subs.items():
                    tsub = subs[sname]
                    tvars = tsub.get("variants") if isinstance(tsub, dict) and "variants" in tsub else tsub
                    if not isinstance(tvars, dict):
                        errors.append(f"plurals_main:{pid}.{sname}: expected variants object")
                        continue
                    if set(tvars.keys()) != req_cat_set:
                        errors.append(
                            f"plurals_main:{pid}.{sname}: CLDR plural categories {sorted(tvars.keys())} != required {req_cats}"
                        )
                    en_sub_other = en_sbody["variants"]["other"]
                    for cat in req_cats:
                        if cat not in tvars:
                            continue
                        sval = tvars[cat]
                        if not isinstance(sval, str):
                            errors.append(f"plurals_main:{pid}.{sname}.{cat}: expected string")
                            continue
                        errors.extend(
                            check_string_compatibility(
                                en_sub_other,
                                sval,
                                label=f"plurals_main:{pid}.{sname}.{cat}",
                                allow_arg_token=True,
                            )
                        )

    # 3. Validate system_surfaces.json
    sys_path = loc_dir / "system_surfaces.json"
    src_sys_by_id = {it["id"]: it for it in sys_src["items"]}
    norm_sys: dict[str, dict[str, Any]] = {}
    if not sys_path.exists():
        errors.append("missing system_surfaces.json")
    else:
        try:
            raw_s = json.loads(sys_path.read_text(encoding="utf-8"))
            norm_sys, s_errs = normalize_system_pack(raw_s, src_sys_by_id)
            errors.extend(s_errs)
        except json.JSONDecodeError as exc:
            errors.append(f"system_surfaces.json: invalid JSON: {exc}")

        exp_sids = set(src_sys_by_id.keys())
        got_sids = set(norm_sys.keys())
        if exp_sids - got_sids:
            miss = sorted(exp_sids - got_sids)
            errors.append(f"system_surfaces.json: missing {len(miss)} IDs (first 5: {miss[:5]})")
        if got_sids - exp_sids:
            ext = sorted(got_sids - exp_sids)
            errors.append(f"system_surfaces.json: unexpected {len(ext)} IDs (first 5: {ext[:5]})")

        for sid in sorted(exp_sids & got_sids):
            src_it = src_sys_by_id[sid]
            tgt_it = norm_sys[sid]
            kind = src_it["kind"]
            if kind == "string_set":
                vals = tgt_it.get("values")
                if not isinstance(vals, list) or len(vals) == 0:
                    errors.append(f"system_surfaces:{sid}: AppShortcuts stringSet must be a non-empty list")
                    continue
                seen_phrases: set[str] = set()
                en_ref = src_it["en"][0]
                for idx, phrase in enumerate(vals):
                    if not isinstance(phrase, str) or not phrase.strip():
                        errors.append(f"system_surfaces:{sid}[{idx}]: empty AppShortcut phrase")
                        continue
                    if "${applicationName}" not in phrase:
                        errors.append(
                            f"system_surfaces:{sid}[{idx}]: AppShortcut phrase missing '${{applicationName}}': {phrase!r}"
                        )
                    norm_p = phrase.strip()
                    if norm_p in seen_phrases:
                        errors.append(f"system_surfaces:{sid}[{idx}]: duplicate AppShortcut phrase {phrase!r}")
                    seen_phrases.add(norm_p)
                    errors.extend(
                        check_string_compatibility(en_ref, phrase, label=f"system_surfaces:{sid}[{idx}]")
                    )
            elif kind == "plain":
                val = tgt_it.get("value")
                if not isinstance(val, str):
                    errors.append(f"system_surfaces:{sid}: expected string 'value'")
                    continue
                errors.extend(check_string_compatibility(src_it["en"], val, label=f"system_surfaces:{sid}"))
            elif kind == "top_plural":
                variants = tgt_it.get("variants")
                if not isinstance(variants, dict):
                    errors.append(f"system_surfaces:{sid}: expected 'variants' object")
                    continue
                if set(variants.keys()) != req_cat_set:
                    errors.append(
                        f"system_surfaces:{sid}: CLDR plural categories {sorted(variants.keys())} != required {req_cats}"
                    )
                en_other = src_it["en"]["other"]
                for cat in req_cats:
                    if cat not in variants:
                        continue
                    vval = variants[cat]
                    if not isinstance(vval, str):
                        errors.append(f"system_surfaces:{sid}.{cat}: expected string")
                        continue
                    errors.extend(
                        check_string_compatibility(en_other, vval, label=f"system_surfaces:{sid}.{cat}")
                    )

    loaded_bundle = {
        "plain": all_plain_translations,
        "plurals": norm_plurals,
        "system": norm_sys,
    }
    return len(errors) == 0, errors, loaded_bundle


def cmd_validate(args: argparse.Namespace) -> int:
    scratch_dir = pathlib.Path(args.scratch_dir)
    locales: list[str] = []
    for raw in args.locale:
        locales.extend(x.strip() for x in raw.split(",") if x.strip())

    overall_ok = True
    for loc in locales:
        ok, errs, bundle = validate_locale_pack(scratch_dir, loc)
        if ok:
            print(
                f"[PASS] {loc}: {len(bundle['plain'])} plain + {len(bundle['plurals'])} plurals + {len(bundle['system'])} system keys verified (CLDR={required_plural_categories(loc)})"
            )
        else:
            overall_ok = False
            print(f"[FAIL] {loc}: {len(errs)} validation error(s):", file=sys.stderr)
            for e in errs[:50]:
                print(f"  - {e}", file=sys.stderr)
            if len(errs) > 50:
                print(f"  ... and {len(errs) - 50} more error(s)", file=sys.stderr)

    return 0 if overall_ok else 1


# ---------------------------------------------------------------------------
# MERGE
# ---------------------------------------------------------------------------
def build_plural_xc_node(variants: dict[str, str], cats: list[str]) -> dict[str, Any]:
    return {
        "variations": {
            "plural": {
                cat: {
                    "stringUnit": {
                        "state": "translated",
                        "value": variants[cat],
                    }
                }
                for cat in cats
            }
        }
    }


def cmd_merge(args: argparse.Namespace) -> int:
    repo_root = pathlib.Path(args.repo_root)
    scratch_dir = pathlib.Path(args.scratch_dir)
    src_dir = scratch_dir / "source"

    if args.locales:
        locales = [x.strip() for x in args.locales.split(",") if x.strip()]
    else:
        locales = list(ALL_TARGET_LOCALES)

    # Validate every requested locale before touching any .xcstrings file
    bundles_by_loc: dict[str, dict[str, Any]] = {}
    for loc in locales:
        ok, errs, bundle = validate_locale_pack(scratch_dir, loc)
        if not ok:
            print(f"[ABORT] {loc} failed validation ({len(errs)} error(s)):", file=sys.stderr)
            for e in errs[:25]:
                print(f"  - {e}", file=sys.stderr)
            return 1
        bundles_by_loc[loc] = bundle

    plain_meta = json.loads((src_dir / "plain_index.json").read_text(encoding="utf-8"))
    plurals_src = json.loads((src_dir / "plurals_main.json").read_text(encoding="utf-8"))
    sys_src = json.loads((src_dir / "system_surfaces.json").read_text(encoding="utf-8"))

    catalogs_mem: dict[str, dict[str, Any]] = {}
    for rel in ALL_CATALOG_RELS:
        catalogs_mem[rel] = json.loads((repo_root / rel).read_text(encoding="utf-8"))

    main_strings = catalogs_mem[MAIN_LOCALIZABLE_REL]["strings"]

    # Merge plain + plurals into main Localizable.xcstrings, and system_surfaces into the other 10
    for loc in locales:
        bundle = bundles_by_loc[loc]
        cats = required_plural_categories(loc)

        for sid, meta in plain_meta["entries"].items():
            key = meta["key"]
            val = bundle["plain"][sid]
            main_strings[key].setdefault("localizations", {})[loc] = {
                "stringUnit": {
                    "state": "translated",
                    "value": val,
                }
            }

        for src_it in plurals_src["items"]:
            pid = src_it["id"]
            key = src_it["key"]
            tgt_it = bundle["plurals"][pid]
            if src_it["kind"] == "top_plural":
                main_strings[key].setdefault("localizations", {})[loc] = build_plural_xc_node(
                    tgt_it["variants"], cats
                )
            else:
                subs_node = {}
                for sname, en_sbody in src_it["en"]["substitutions"].items():
                    tsub = tgt_it["substitutions"][sname]
                    tvars = tsub["variants"] if "variants" in tsub else tsub
                    subs_node[sname] = {
                        "argNum": en_sbody["argNum"],
                        "formatSpecifier": en_sbody["formatSpecifier"],
                        **build_plural_xc_node(tvars, cats),
                    }
                main_strings[key].setdefault("localizations", {})[loc] = {
                    "stringUnit": {
                        "state": "translated",
                        "value": tgt_it["template"],
                    },
                    "substitutions": subs_node,
                }

        for src_it in sys_src["items"]:
            sid = src_it["id"]
            rel = src_it["catalog"]
            key = src_it["key"]
            kind = src_it["kind"]
            tgt_it = bundle["system"][sid]
            cstrings = catalogs_mem[rel]["strings"]
            if kind == "string_set":
                cstrings[key].setdefault("localizations", {})[loc] = {
                    "stringSet": {
                        "state": "translated",
                        "values": tgt_it["values"],
                    }
                }
            elif kind == "plain":
                cstrings[key].setdefault("localizations", {})[loc] = {
                    "stringUnit": {
                        "state": "translated",
                        "value": tgt_it["value"],
                    }
                }
            elif kind == "top_plural":
                cstrings[key].setdefault("localizations", {})[loc] = build_plural_xc_node(
                    tgt_it["variants"], cats
                )

    # Write out and run json.tool + xcstringstool compile --dry-run on all 11 .xcstrings
    with tempfile.TemporaryDirectory(prefix="catbird-xcstrings-merge-") as tmpd:
        for idx, rel in enumerate(ALL_CATALOG_RELS):
            cpath = repo_root / rel
            write_xcstrings(cpath, catalogs_mem[rel])
            # Verify valid JSON via json.tool
            subprocess.run(["python3", "-m", "json.tool", str(cpath)], check=True, stdout=subprocess.DEVNULL)
            out_dir = pathlib.Path(tmpd) / f"cat_{idx}"
            res = subprocess.run(
                ["xcrun", "xcstringstool", "compile", str(cpath), "--output-directory", str(out_dir), "--dry-run"],
                capture_output=True,
                text=True,
            )
            if res.returncode != 0 or res.stderr.strip():
                print(
                    f"[ERROR] xcstringstool compile --dry-run failed/warned on {rel}: rc={res.returncode}\n{res.stderr}",
                    file=sys.stderr,
                )
                return 1
            print(f"[MERGED] {rel}: {len(catalogs_mem[rel]['strings'])} keys, {len(locales)} locale(s), xcstringstool OK")

    return 0


def build_parser() -> argparse.ArgumentParser:
    common = argparse.ArgumentParser(add_help=False)
    common.add_argument(
        "--scratch-dir",
        default=str(DEFAULT_SCRATCH_DIR),
        help=f"Scratch directory for source shards and locale packs (default: {DEFAULT_SCRATCH_DIR})",
    )
    common.add_argument(
        "--repo-root",
        default=str(DEFAULT_REPO_ROOT),
        help=f"Path to Catbird repository root (default: {DEFAULT_REPO_ROOT})",
    )

    parser = argparse.ArgumentParser(
        description="Catbird String Catalog (.xcstrings) export, derive, validate, and merge pipeline.",
        parents=[common],
    )
    sub = parser.add_subparsers(dest="subcommand", required=True)

    sub.add_parser("export", parents=[common], help="Export all 11 .xcstrings catalogs into source shards.")

    p_derive = sub.add_parser(
        "derive",
        parents=[common],
        help="Derive a regional locale translation pack from 'en' or another validated locale pack.",
    )
    p_derive.add_argument("--base", required=True, help="Base locale ('en' or an existing locale in translations/).")
    p_derive.add_argument("--target", required=True, help="Target locale identifier (e.g. en-GB, es-419, pt-PT).")
    p_derive.add_argument("--overrides", help="Optional path to JSON override rules file.")

    p_val = sub.add_parser("validate", parents=[common], help="Strictly validate one or more locale translation packs.")
    p_val.add_argument(
        "--locale",
        required=True,
        action="append",
        help="Target locale identifier to validate (may be passed multiple times or comma-separated).",
    )

    p_merge = sub.add_parser("merge", parents=[common], help="Merge validated locale packs into all 11 .xcstrings files.")
    p_merge.add_argument(
        "--locales",
        help="Optional comma-separated list of locales to merge (defaults to all 39 target locales).",
    )

    return parser


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    if args.subcommand == "export":
        return cmd_export(args)
    if args.subcommand == "derive":
        return cmd_derive(args)
    if args.subcommand == "validate":
        return cmd_validate(args)
    if args.subcommand == "merge":
        return cmd_merge(args)
    parser.error(f"Unknown subcommand {args.subcommand}")
    return 2


if __name__ == "__main__":
    sys.exit(main())
