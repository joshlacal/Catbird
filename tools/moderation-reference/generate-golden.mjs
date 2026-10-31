#!/usr/bin/env node
/**
 * generate-golden.mjs
 *
 * PURPOSE
 *   Produce golden moderation expectations from the ACTUAL shipped Bluesky
 *   moderation code, so Catbird's Swift port (Catbird/Core/Moderation) can be
 *   tested against real behavior instead of against a hand-written model of it.
 *   Everything in `expected` is computed by running the real sdk functions
 *   (moderatePost, moderateProfile, interpretLabelValueDefinitions, getPreferences)
 *   on the inputs written next to it; nothing is hand-copied.
 *
 * PINNED REFERENCE
 *   @bsky/sdk 1.0.1, as installed in the official social-app checkout at commit
 *   5b88335bb118f4f65dcb564e10109d6c6a78cb67 (2026-08-26, `main`). The script
 *   refuses to run against any other sdk version or social-app commit unless
 *   --allow-unpinned is given, and records sha256 prefixes of the sdk files that
 *   define the behavior so drift is detectable even when the version string is not.
 *
 * OUTPUTS (written next to this script unless overridden)
 *   golden.json                                          compact JSON, the golden
 *   ../../CatbirdTests/Moderation/ModerationReferenceGolden.swift   same JSON embedded
 *                                                        as raw-string chunks
 *
 * HOW TO RERUN
 *   node Catbird/tools/moderation-reference/generate-golden.mjs \
 *     --sdk /Users/joshlacalamito/Developer/Catbird+Petrel/social-app/node_modules/@bsky/sdk \
 *     --social-app /Users/joshlacalamito/Developer/Catbird+Petrel/social-app
 *   Optional: --social-app-commit <sha> (instead of reading <social-app>/.git),
 *             --social-app-commit-date <yyyy-mm-dd>, --out-json <file>,
 *             --out-swift <file>, --allow-unpinned,
 *             --check (generate in memory and fail if the files on disk differ).
 *   Output is deterministic: fixed timestamps (see NOW), fixed DIDs, stable order.
 *   Only Node (v22 tested) and the social-app checkout's node_modules are needed.
 *
 * FILE FORMAT (see README.md for the field-by-field description)
 *   meta         provenance, conventions, builtin label table, intentional deviations
 *   prefs        preference-normalization cases: raw server array -> real getPreferences()
 *   prefSets     named preference sets (real getPreferences output) that scenarios refer to
 *   definitions  named label value definitions {definedBy, raw, interpreted} that scenarios refer to
 *   scenarios    {id, input, expected, catbird?}; expected covers all 8 moderation contexts
 *                (only non-default values are stored: absent = false / empty list)
 *
 * INTENTIONAL CATBIRD DEVIATIONS encoded here (scenarios and preference cases carrying a `catbird` field):
 *   (a) negated (neg:true) or expired (exp <= NOW) labels are ignored
 *   (b) a labeler's definition of a builtin identifier (porn, sexual, nudity,
 *       graphic-media, and the deprecated builtin gore) or of a "!"-prefixed
 *       value is ignored
 *   (c) an exact duplicate label (same src, uri, val) in one list counts once
 *   (d) Catbird's former private preference key "graphic" is a fallback for
 *       graphic-media when the stored preferences hold no global graphic-media
 *       or gore entry (preference cases only; see PRIVATE_KEY below)
 *   In each case `catbird.expected` is the real sdk run on the transformed input;
 *   every other scenario and preference case must match the sdk exactly.
 */
import fs from 'node:fs';
import crypto from 'node:crypto';
import path from 'node:path';
import { createRequire } from 'node:module';
import { fileURLToPath, pathToFileURL } from 'node:url';

const HERE = path.dirname(fileURLToPath(import.meta.url));

// ---------------------------------------------------------------------------
// Pins and fixed constants
// ---------------------------------------------------------------------------

const PINNED_SDK_VERSION = '1.0.1';
const PINNED_SOCIAL_APP_COMMIT = '5b88335bb118f4f65dcb564e10109d6c6a78cb67';
const DEFAULT_COMMIT_DATE = '2026-08-26';

/** The fixed "current time" for exp handling. Catbird must be run with this `now`. */
const NOW = '2026-10-01T12:00:00.000Z';
const CTS = '2026-09-01T00:00:00.000Z';
const EXP_PAST = '2026-09-15T00:00:00.000Z';
const EXP_FUTURE = '2026-12-01T00:00:00.000Z';

const BSKY = 'did:plc:ar7c4by46qjdydhdevvrndac'; // Bluesky Moderation Service (an app labeler)
const C1 = 'did:plc:labelerone'; //                 custom labeler, subscribed where stated
const C2 = 'did:plc:labelertwo'; //                 second custom labeler
const UNSUB = 'did:plc:labelerunsub'; //            labeler the viewer never subscribed to
const AUTHOR = 'did:plc:author'; //                 author of the post / owner of the profile
const QUOTED = 'did:plc:quoted'; //                 author of a quoted post
const VIEWER = 'did:plc:viewer'; //                 some other signed-in user
const LISTER = 'did:plc:lister';

// Fields the lexicons require but moderation never reads. Every post and quoted post carries them so a subject
// decodes straight into the typed models (Petrel / Jacquard / Kotlin) with no completion step.
const PLACEHOLDER_CID = 'bafyreidfayvfuwqa7qlnopdjiqrxzs6blmoeu4rujcjtnci5beludirz2a';
const placeholderPostRecord = () => ({ $type: 'app.bsky.feed.post', text: '', createdAt: CTS });

const POST_URI = `at://${AUTHOR}/app.bsky.feed.post/p1`;
const QUOTE_URI = `at://${QUOTED}/app.bsky.feed.post/q1`;
const profileSelfUri = (did) => `at://${did}/app.bsky.actor.profile/self`;

const CONTEXTS = [
  'profileList',
  'profileView',
  'avatar',
  'banner',
  'displayName',
  'contentList',
  'contentView',
  'contentMedia',
];

const BANG = ['!hide', '!warn', '!no-unauthenticated'];
const CONF = ['porn', 'sexual', 'nudity', 'graphic-media'];
// "gore" is a deprecated builtin of its own in the sdk table: own identifier, own preference key, behaves like graphic-media.
const DEPRECATED_BUILTIN = 'gore';
const BUILTIN_REDEFINABLE = new Set([...CONF, DEPRECATED_BUILTIN]);

// ---------------------------------------------------------------------------
// Arguments and pin checks
// ---------------------------------------------------------------------------

function parseArgs(argv) {
  const flags = new Set(['allow-unpinned', 'check']);
  const out = {};
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (!a.startsWith('--')) throw new Error(`unexpected argument: ${a}`);
    let key = a.slice(2);
    let value;
    const eq = key.indexOf('=');
    if (eq >= 0) {
      value = key.slice(eq + 1);
      key = key.slice(0, eq);
    }
    if (flags.has(key)) {
      out[key] = true;
    } else {
      if (value === undefined) value = argv[++i];
      if (value === undefined) throw new Error(`--${key} needs a value`);
      out[key] = value;
    }
  }
  return out;
}

function readGitCommit(repo) {
  let gitDir = path.join(repo, '.git');
  if (fs.statSync(gitDir).isFile()) {
    const m = fs.readFileSync(gitDir, 'utf8').match(/^gitdir:\s*(.+)$/m);
    if (!m) throw new Error(`cannot parse ${gitDir}`);
    gitDir = path.resolve(repo, m[1].trim());
  }
  let commonDir = gitDir;
  const commonFile = path.join(gitDir, 'commondir');
  if (fs.existsSync(commonFile)) {
    commonDir = path.resolve(gitDir, fs.readFileSync(commonFile, 'utf8').trim());
  }
  const head = fs.readFileSync(path.join(gitDir, 'HEAD'), 'utf8').trim();
  if (/^[0-9a-f]{40}$/.test(head)) return head;
  const ref = head.match(/^ref:\s*(.+)$/)?.[1];
  if (!ref) throw new Error(`cannot parse HEAD in ${gitDir}`);
  for (const dir of [gitDir, commonDir]) {
    const refFile = path.join(dir, ref);
    if (fs.existsSync(refFile)) return fs.readFileSync(refFile, 'utf8').trim();
  }
  const packed = path.join(commonDir, 'packed-refs');
  if (fs.existsSync(packed)) {
    for (const line of fs.readFileSync(packed, 'utf8').split('\n')) {
      const [sha, name] = line.trim().split(' ');
      if (name === ref && /^[0-9a-f]{40}$/.test(sha)) return sha;
    }
  }
  throw new Error(`cannot resolve ${ref} in ${repo}`);
}

const args = parseArgs(process.argv.slice(2));
if (!args.sdk) throw new Error('--sdk <path to @bsky/sdk> is required');

const sdkRoot = path.resolve(args.sdk);
const sdkDist = fs.existsSync(path.join(sdkRoot, 'dist', 'moderation', 'index.js'))
  ? path.join(sdkRoot, 'dist')
  : sdkRoot;
const sdkPackage = JSON.parse(fs.readFileSync(path.join(sdkDist, '..', 'package.json'), 'utf8'));

let socialAppCommit = args['social-app-commit'];
let socialAppDeclaresSdk = null;
if (args['social-app']) {
  const repo = path.resolve(args['social-app']);
  socialAppCommit ??= readGitCommit(repo);
  const pkg = JSON.parse(fs.readFileSync(path.join(repo, 'package.json'), 'utf8'));
  socialAppDeclaresSdk = pkg.dependencies?.['@bsky/sdk'] ?? pkg.devDependencies?.['@bsky/sdk'] ?? null;
}
if (!socialAppCommit) throw new Error('give --social-app <path> or --social-app-commit <sha>');
const socialAppCommitDate = args['social-app-commit-date'] ?? DEFAULT_COMMIT_DATE;

if (!args['allow-unpinned']) {
  if (sdkPackage.version !== PINNED_SDK_VERSION) {
    throw new Error(`sdk is ${sdkPackage.version}, pinned ${PINNED_SDK_VERSION} (use --allow-unpinned to override)`);
  }
  if (socialAppCommit !== PINNED_SOCIAL_APP_COMMIT) {
    throw new Error(`social-app is ${socialAppCommit}, pinned ${PINNED_SOCIAL_APP_COMMIT} (use --allow-unpinned)`);
  }
  if (socialAppDeclaresSdk !== null && socialAppDeclaresSdk !== PINNED_SDK_VERSION) {
    throw new Error(`social-app declares @bsky/sdk ${socialAppDeclaresSdk}, pinned ${PINNED_SDK_VERSION}`);
  }
}

// ---------------------------------------------------------------------------
// Load the real sdk
// ---------------------------------------------------------------------------

const urlOf = (rel) => pathToFileURL(path.join(sdkDist, rel)).href;
const mod = await import(urlOf('moderation/index.js'));
const lex = await import(urlOf('lexicons/index.js'));
const prefDefs = await import(urlOf('lexicons/app/bsky/actor/defs.defs.js'));
const prefsApi = await import(urlOf('actions/preferences.js'));

// preferences.js reads `Client.appLabelers` from @atproto/lex. Resolve that package the
// way the sdk does (from the sdk's own directory) so we set the very same class object.
const requireFromSdk = createRequire(path.join(sdkDist, 'index.js'));
const { Client } = await import(pathToFileURL(requireFromSdk.resolve('@atproto/lex')).href);
Client.appLabelers = [BSKY];

function sha12(rel) {
  return crypto.createHash('sha256').update(fs.readFileSync(path.join(sdkDist, rel))).digest('hex').slice(0, 12);
}
const SDK_FILES = [
  'moderation/const/labels.js',
  'moderation/decision.js',
  'moderation/ui.js',
  'moderation/util.js',
  'moderation/types.js',
  'moderation/subjects/account.js',
  'moderation/subjects/post.js',
  'moderation/subjects/profile.js',
  'actions/preferences.js',
];

// ---------------------------------------------------------------------------
// Preference normalization: run the REAL getPreferences with a minimal fake client
// ---------------------------------------------------------------------------

/**
 * getPreferences only touches `client.call(getPreferences.main, {}, {service})`
 * (and, when no saved-feeds pref exists, the updatePreferences read-modify-write that
 * calls get/put again). A saved-feeds v2 pref is always included so no migration runs.
 */
function fakeClient(initial) {
  let stored = structuredClone(initial);
  const client = {
    async call(action, input, opts) {
      if (typeof action === 'function') return action(client, input, opts);
      if (action?.nsid === 'app.bsky.actor.getPreferences') return { preferences: structuredClone(stored) };
      if (action?.nsid === 'app.bsky.actor.putPreferences') {
        stored = structuredClone(input.preferences);
        return {};
      }
      throw new Error(`fake client: unexpected call ${action?.nsid ?? action}`);
    },
  };
  return client;
}

/**
 * @param {{adult?: boolean|null, labelers?: string[]|null, content?: {label:string,visibility:string,labelerDid?:string}[],
 *          mutedWords?: object[], hiddenPosts?: string[]}} raw
 */
function rawPreferenceArray(raw) {
  const prefs = [];
  if (raw.adult !== undefined && raw.adult !== null) {
    prefs.push({ $type: prefDefs.adultContentPref.$type, enabled: raw.adult });
  }
  if (raw.labelers) {
    prefs.push({ $type: prefDefs.labelersPref.$type, labelers: raw.labelers.map((did) => ({ did })) });
  }
  for (const c of raw.content ?? []) {
    prefs.push({
      $type: prefDefs.contentLabelPref.$type,
      label: c.label,
      visibility: c.visibility,
      ...(c.labelerDid !== undefined ? { labelerDid: c.labelerDid } : {}),
    });
  }
  if (raw.mutedWords?.length) prefs.push({ $type: prefDefs.mutedWordsPref.$type, items: raw.mutedWords });
  if (raw.hiddenPosts?.length) prefs.push({ $type: prefDefs.hiddenPostsPref.$type, items: raw.hiddenPosts });
  prefs.push({
    $type: prefDefs.savedFeedsPrefV2.$type,
    items: [{ id: '3kaaaaaaaaaaa', type: 'timeline', value: 'following', pinned: true }],
  });
  return prefs;
}

async function runGetPreferences(raw) {
  const { moderationPrefs } = await prefsApi.getPreferences(fakeClient(rawPreferenceArray(raw)));
  return moderationPrefs;
}

async function normalizedPrefs(raw) {
  const m = await runGetPreferences(raw);
  return {
    adultContentEnabled: m.adultContentEnabled,
    labels: { ...m.labels },
    labelers: m.labelers.map((l) => ({ did: l.did, labels: { ...l.labels } })),
  };
}

// ---------------------------------------------------------------------------
// Label definitions (what a labeler service publishes) and their interpretation
// ---------------------------------------------------------------------------

const DID_ALIAS = { [BSKY]: 'bsky', [C1]: 'c1', [C2]: 'c2', [UNSUB]: 'unsub', [AUTHOR]: 'author', [QUOTED]: 'quoted' };
const alias = (did) => DID_ALIAS[did] ?? did;

function rawDef({ id, blurs, severity, defaultSetting, adultOnly }) {
  return {
    identifier: id,
    severity,
    blurs,
    ...(defaultSetting !== undefined ? { defaultSetting } : {}),
    ...(adultOnly !== undefined ? { adultOnly } : {}),
    locales: [{ lang: 'en', name: id, description: 'd' }],
  };
}

/** Run the real interpretLabelValueDefinitions exactly as the app does for a labeler view. */
function interpretDefs(did, rawDefs) {
  return mod.interpretLabelValueDefinitions({
    creator: { did },
    policies: { labelValueDefinitions: rawDefs },
  });
}

/**
 * Definitions are stored once, in the top-level `definitions` map, as
 * {definedBy, raw, interpreted}; scenarios list the keys they use. `interpreted` is the output of the
 * real interpretLabelValueDefinitions for that single definition (null if the sdk drops it as invalid).
 */
const registry = { prefSets: {}, definitions: {} };
const defKeyByCanonical = new Map();

function registerDef(did, raw) {
  const canonical = JSON.stringify([did, raw]);
  if (defKeyByCanonical.has(canonical)) return defKeyByCanonical.get(canonical);
  const base = `${raw.identifier}@${alias(did)}`;
  let key = base;
  for (let n = 2; registry.definitions[key]; n++) key = `${base}#${n}`;
  registry.definitions[key] = { definedBy: did, raw, interpreted: interpretDefs(did, [raw])[0] ?? null };
  defKeyByCanonical.set(canonical, key);
  return key;
}

/** {did: rawDef[]} -> [definition keys] (undefined when empty). */
function registerDefs(map) {
  const keys = [];
  for (const [did, raws] of Object.entries(map ?? {})) for (const raw of raws) keys.push(registerDef(did, raw));
  return keys.length ? keys : undefined;
}

/** Identifier for a generated definition; matches /^[a-z-]+$/ so the sdk treats it as custom. */
const defId = (d) =>
  `${d.blurs}-${d.severity}-${d.defaultSetting ?? 'nodefault'}${d.adultOnly ? '-adult' : ''}`;
const makeDef = (d) => rawDef({ ...d, id: d.id ?? defId(d) });

// ---------------------------------------------------------------------------
// Subject builders (the JSON here IS what moderatePost / moderateProfile receive)
// ---------------------------------------------------------------------------

const label = (src, uri, val, extra = {}) => ({ src, uri, val, ...extra, cts: CTS });

function profBasic(did, handle, labels, viewer) {
  const p = { did, handle };
  if (labels?.length) p.labels = labels;
  if (viewer) p.viewer = viewer;
  return p;
}

const IMAGES_VIEW = {
  $type: 'app.bsky.embed.images#view',
  images: [{ thumb: 'https://img.test/t.jpg', fullsize: 'https://img.test/f.jpg', alt: '' }],
};

function viewRecord(q) {
  const r = {
    $type: 'app.bsky.embed.record#viewRecord',
    uri: QUOTE_URI,
    cid: PLACEHOLDER_CID,
    author: profBasic(QUOTED, 'quoted.test', q.authorLabels, q.authorViewer),
    value: placeholderPostRecord(),
    indexedAt: CTS,
  };
  if (q.labels?.length) r.labels = q.labels;
  return r;
}

function blockedRecord(q) {
  return {
    $type: 'app.bsky.embed.record#viewBlocked',
    uri: QUOTE_URI,
    blocked: true,
    author: { did: QUOTED, viewer: q.blocked },
  };
}

/**
 * @param {{postLabels?:object[], authorLabels?:object[], authorViewer?:object, record?:object,
 *          images?:boolean, quote?:{media?:boolean, labels?:object[], authorLabels?:object[],
 *                                   authorViewer?:object, blocked?:object}}} p
 */
function buildPost(p) {
  const subject = {
    uri: POST_URI,
    cid: PLACEHOLDER_CID,
    author: profBasic(AUTHOR, 'author.test', p.authorLabels, p.authorViewer),
    record: p.record ?? placeholderPostRecord(),
    indexedAt: CTS,
  };
  if (p.postLabels?.length) subject.labels = p.postLabels;
  let embed;
  if (p.quote) {
    const rec = p.quote.blocked ? blockedRecord(p.quote) : viewRecord(p.quote);
    const recordView = { $type: 'app.bsky.embed.record#view', record: rec };
    embed = p.quote.media
      ? { $type: 'app.bsky.embed.recordWithMedia#view', record: recordView, media: IMAGES_VIEW }
      : recordView;
  } else if (p.images) {
    embed = IMAGES_VIEW;
  }
  if (embed) subject.embed = embed;
  return subject;
}

function postShape(p) {
  if (p.quote?.blocked) return p.quote.media ? 'quote-blocked+images' : 'quote-blocked';
  if (p.quote) return p.quote.media ? 'quote+images' : 'quote';
  return p.images ? 'images' : 'text';
}

function buildProfile(p) {
  return profBasic(AUTHOR, 'author.test', p.labels, p.viewer);
}

// ---------------------------------------------------------------------------
// Evaluation: run the real sdk and project the result into the golden shape
// ---------------------------------------------------------------------------

function userDidFor(viewer) {
  switch (viewer) {
    case 'other':
      return VIEWER;
    case 'me':
      return AUTHOR;
    case 'quoted':
      return QUOTED;
    case 'out':
      return null;
    default:
      throw new Error(`unknown viewer ${viewer}`);
  }
}

function entryOf(c) {
  if (c.type === 'label') return { val: c.label.val, src: c.label.src, target: c.target, priority: c.priority };
  return { type: c.type, priority: c.priority };
}

function causeOf(c) {
  if (c.type !== 'label') {
    const base = { type: c.type, priority: c.priority, source: c.source.type };
    if (c.downgraded) base.downgraded = true;
    return base;
  }
  const base = {
    type: 'label',
    val: c.label.val,
    src: c.label.src,
    target: c.target,
    setting: c.setting,
    priority: c.priority,
    source: c.source.type,
  };
  if (c.noOverride) base.noOverride = true;
  if (c.downgraded) base.downgraded = true;
  return base;
}

/** Only non-default values are stored: absent boolean = false, absent list = [], absent context = all defaults. */
function summarize(decision) {
  const contexts = {};
  for (const ctx of CONTEXTS) {
    const ui = decision.ui(ctx);
    const e = {};
    if (ui.filter) e.filter = true;
    if (ui.blur) e.blur = true;
    if (ui.alert) e.alert = true;
    if (ui.inform) e.inform = true;
    if (ui.noOverride) e.noOverride = true;
    if (ui.filters.length) e.filters = ui.filters.map(entryOf);
    if (ui.blurs.length) e.blurs = ui.blurs.map(entryOf);
    if (ui.alerts.length) e.alerts = ui.alerts.map(entryOf);
    if (ui.informs.length) e.informs = ui.informs.map(entryOf);
    if (Object.keys(e).length) contexts[ctx] = e;
  }
  const out = { contexts, decision: { causes: decision.causes.map(causeOf) } };
  if (decision.isMe) out.decision.isMe = true;
  return out;
}

function evaluate(input, ctx = registry) {
  const inp = structuredClone(input);
  const labelDefs = {};
  for (const key of inp.labelDefs ?? []) {
    const d = ctx.definitions[key];
    if (!d) throw new Error(`unknown definition key ${key}`);
    if (d.interpreted) (labelDefs[d.definedBy] ??= []).push(structuredClone(d.interpreted));
  }
  const p = structuredClone(ctx.prefSets[inp.prefs]);
  if (!p) throw new Error(`unknown prefs key ${inp.prefs}`);
  const opts = {
    userDid: inp.userDid ?? undefined,
    prefs: {
      adultContentEnabled: p.adultContentEnabled,
      labels: p.labels,
      labelers: p.labelers,
      mutedWords: p.mutedWords ?? [],
      hiddenPosts: p.hiddenPosts ?? [],
    },
    labelDefs,
  };
  const decision =
    inp.kind === 'post' ? mod.moderatePost(inp.subject, opts) : mod.moderateProfile(inp.subject, opts);
  return summarize(decision);
}

// ---------------------------------------------------------------------------
// Scenario registry
// ---------------------------------------------------------------------------

const scenarios = [];
const seenIds = new Set();

/**
 * Preference sets are stored once in `prefSets`; a scenario names its set. The key spells out the raw
 * inputs, e.g. "adultOn+porn=warn+bsky:porn=ignore+sub:c1". The value is the output of the real getPreferences().
 */
async function prefsFor(p) {
  const parts = [p.adult ? 'adultOn' : 'adultOff'];
  for (const [l, v] of p.global ?? []) parts.push(`${l}=${v}`);
  for (const [did, l, v] of p.scoped ?? []) parts.push(`${alias(did)}:${l}=${v}`);
  if (p.subscribed?.length) parts.push(`sub:${p.subscribed.map(alias).join(',')}`);
  if (p.mutedWords) parts.push('mutedWords');
  if (p.hiddenPosts) parts.push('hiddenPosts');
  const key = parts.join('+');
  const raw = {
    adult: p.adult,
    labelers: p.subscribed?.length ? p.subscribed : null,
    content: [
      ...(p.global ?? []).map(([l, v]) => ({ label: l, visibility: v })),
      ...(p.scoped ?? []).map(([did, l, v]) => ({ label: l, visibility: v, labelerDid: did })),
    ],
    mutedWords: p.mutedWords,
    hiddenPosts: p.hiddenPosts,
  };
  const m = await runGetPreferences(raw);
  const value = {
    adultContentEnabled: m.adultContentEnabled,
    labels: { ...m.labels },
    labelers: m.labelers.map((l) => ({ did: l.did, labels: { ...l.labels } })),
  };
  if (m.mutedWords.length) value.mutedWords = m.mutedWords;
  if (m.hiddenPosts.length) value.hiddenPosts = m.hiddenPosts;
  const existing = registry.prefSets[key];
  if (existing && JSON.stringify(existing) !== JSON.stringify(value)) throw new Error(`prefs key collision: ${key}`);
  registry.prefSets[key] = value;
  return key;
}

/**
 * spec: {id, kind, viewer, prefs, defs?, subject, shape, catbird?: {reason, transform(input)->input}}
 */
async function add(spec) {
  if (seenIds.has(spec.id)) throw new Error(`duplicate scenario id ${spec.id}`);
  seenIds.add(spec.id);
  const labelDefs = registerDefs(spec.defs);
  const input = {
    kind: spec.kind,
    shape: spec.shape,
    userDid: userDidFor(spec.viewer),
    prefs: await prefsFor(spec.prefs),
    ...(labelDefs ? { labelDefs } : {}),
    subject: spec.subject,
  };
  const sc = { id: spec.id, input, expected: evaluate(input) };
  if (spec.catbird) {
    sc.catbird = {
      reason: spec.catbird.reason,
      expected: evaluate(spec.catbird.transform(structuredClone(input))),
    };
  }
  scenarios.push(sc);
}

// ---------------------------------------------------------------------------
// Catbird-deviation transforms (operate on a scenario `input`)
// ---------------------------------------------------------------------------

/** Visit every label array the sdk can see for a subject. */
function labelArrays(subject) {
  const arrays = [];
  if (subject.labels) arrays.push(subject.labels);
  if (subject.author?.labels) arrays.push(subject.author.labels);
  const embed = subject.embed;
  const rec = embed?.$type?.endsWith('recordWithMedia#view') ? embed.record?.record : embed?.record;
  if (rec) {
    if (rec.labels) arrays.push(rec.labels);
    if (rec.author?.labels) arrays.push(rec.author.labels);
  }
  return arrays;
}

function transformLabels(input, fn) {
  for (const arr of labelArrays(input.subject)) {
    const kept = fn(arr);
    arr.length = 0;
    arr.push(...kept);
  }
  return input;
}

const isInactive = (l) => l.neg === true || (l.exp !== undefined && l.exp <= NOW);
const dropInactive = (input) => transformLabels(input, (arr) => arr.filter((l) => !isInactive(l)));
const dropDuplicates = (input) =>
  transformLabels(input, (arr) => {
    const seen = new Set();
    return arr.filter((l) => {
      const key = `${l.src}\u0000${l.uri}\u0000${l.val}`;
      if (seen.has(key)) return false;
      seen.add(key);
      return true;
    });
  });
const isBuiltinDefinition = (identifier) => identifier.startsWith('!') || BUILTIN_REDEFINABLE.has(identifier);
function dropBuiltinDefinitions(input) {
  if (!input.labelDefs) return input;
  const kept = input.labelDefs.filter((k) => !isBuiltinDefinition(registry.definitions[k].raw.identifier));
  if (kept.length) input.labelDefs = kept;
  else delete input.labelDefs;
  return input;
}

const DEV = {
  inactive: {
    reason: 'negated or expired label is ignored',
    rule: 'Catbird ignores negated (neg:true) and expired (exp <= now) labels; the sdk does not look at neg or exp. Expected = sdk output with those labels removed from the subject.',
    transform: dropInactive,
  },
  builtinDef: {
    reason: 'definition of a builtin or "!" value is ignored',
    rule: 'Catbird ignores a labeler definition that redefines a builtin identifier (porn, sexual, nudity, graphic-media, gore) or a "!"-prefixed value. The sdk applies the redefinition for the five plain identifiers and already ignores "!" ones (so those scenarios have catbird.expected equal to expected). Expected = sdk output with the definition removed.',
    transform: dropBuiltinDefinitions,
  },
  duplicate: {
    reason: 'duplicate label counts once',
    rule: 'Catbird counts an exact duplicate label (same src, uri, val) in one label list once; the sdk adds one cause per copy. Expected = sdk output with the duplicate removed.',
    transform: dropDuplicates,
  },
};

/**
 * Deviation (d), preference cases only. Catbird's former private preference key "graphic" is honored as a
 * fallback for "graphic-media": when the stored preferences hold NO global graphic-media or gore entry (any
 * visibility value counts as an entry; labeler-scoped entries do not), every global "graphic" entry is read as
 * a "graphic-media" entry, in array order. When such an entry exists "graphic" stays an inert key, exactly as in
 * the sdk. Expected = real getPreferences() on the raw entries with that rename applied.
 */
const PRIVATE_KEY = {
  reason: 'private "graphic" key is a fallback for graphic-media',
  rule: 'Catbird reads Catbird\'s former private preference key "graphic" as "graphic-media" when the stored preferences hold no global graphic-media or gore entry; the sdk passes "graphic" through as an inert key. When a global graphic-media or gore entry exists, "graphic" stays inert as in the sdk. Expected = real getPreferences() on the raw entries with the rename applied.',
  transform(rawContent) {
    const isGlobal = (c) => c.labelerDid === undefined;
    const hasExplicit = rawContent.some((c) => isGlobal(c) && (c.label === 'graphic-media' || c.label === 'gore'));
    if (hasExplicit) return rawContent;
    return rawContent.map((c) => (isGlobal(c) && c.label === 'graphic' ? { ...c, label: 'graphic-media' } : c));
  },
};

// ---------------------------------------------------------------------------
// The single-label scenario builder used by most families
// ---------------------------------------------------------------------------

const adultTag = (a) => (a ? 'adultOn' : 'adultOff');
const cap = (s) => s.charAt(0).toUpperCase() + s.slice(1);
const DID_TAG = { [BSKY]: 'Bsky', [C1]: 'C1', [C2]: 'C2', [UNSUB]: 'Unsub' };

/**
 * Where a label lands, per target:
 *   post / post-account / post-profile      label on the post, the author's account, the author's profile record
 *   quote* / quotemedia*                    same three places on a quoted post (record / recordWithMedia shapes)
 *   profile-account / profile-profile       moderateProfile subject (account label / profile-self label)
 */
const TARGETS = {
  post: { kind: 'post', owner: AUTHOR, slot: 'postLabels', uri: POST_URI },
  'post-account': { kind: 'post', owner: AUTHOR, slot: 'authorLabels', uri: AUTHOR },
  'post-profile': { kind: 'post', owner: AUTHOR, slot: 'authorLabels', uri: profileSelfUri(AUTHOR) },
  quote: { kind: 'post', owner: QUOTED, slot: 'quoteLabels', uri: QUOTE_URI, quote: 'record' },
  'quote-account': { kind: 'post', owner: QUOTED, slot: 'quoteAuthorLabels', uri: QUOTED, quote: 'record' },
  'quote-profile': { kind: 'post', owner: QUOTED, slot: 'quoteAuthorLabels', uri: profileSelfUri(QUOTED), quote: 'record' },
  quotemedia: { kind: 'post', owner: QUOTED, slot: 'quoteLabels', uri: QUOTE_URI, quote: 'media' },
  'quotemedia-account': { kind: 'post', owner: QUOTED, slot: 'quoteAuthorLabels', uri: QUOTED, quote: 'media' },
  'quotemedia-profile': { kind: 'post', owner: QUOTED, slot: 'quoteAuthorLabels', uri: profileSelfUri(QUOTED), quote: 'media' },
  'profile-account': { kind: 'profile', owner: AUTHOR, slot: 'accountLabels', uri: AUTHOR },
  'profile-profile': { kind: 'profile', owner: AUTHOR, slot: 'profileLabels', uri: profileSelfUri(AUTHOR) },
};

/** Source name -> DID for a label whose subject owner is `owner`. */
function sourceDid(src, owner) {
  switch (src) {
    case 'bsky':
      return BSKY;
    case 'c1':
      return C1;
    case 'c2':
      return C2;
    case 'unsub':
      return UNSUB;
    case 'self':
      return owner;
    default:
      throw new Error(`unknown source ${src}`);
  }
}

/** Build the subject for a target, putting `labels` (already built) into the right slot. */
function subjectFor(targetName, labels, { images = false, extra = {} } = {}) {
  const t = TARGETS[targetName];
  if (t.kind === 'profile') {
    const account = t.slot === 'accountLabels' ? labels : [];
    const profile = t.slot === 'profileLabels' ? labels : [];
    return { kind: 'profile', shape: 'profile', subject: buildProfile({ labels: [...account, ...profile], ...extra }) };
  }
  const p = { ...extra };
  if (t.quote) {
    p.quote = { media: t.quote === 'media' };
    if (t.slot === 'quoteLabels') p.quote.labels = labels;
    if (t.slot === 'quoteAuthorLabels') p.quote.authorLabels = labels;
  } else {
    p[t.slot] = labels;
    if (images) p.images = true;
  }
  return { kind: 'post', shape: postShape(p), subject: buildPost(p) };
}

/**
 * o: {target, val, src, adult=true, pref='unset', scoped?: [labelerKey, value], viewer='other',
 *     images, defs, global?: [[label, value]...], subscribe?: string[], family?, tag?, catbird?, labelExtra?}
 */
async function labelScenario(o) {
  const t = TARGETS[o.target];
  const src = sourceDid(o.src, t.owner);
  const adult = o.adult ?? true;
  const pref = o.pref ?? 'unset';
  const viewer = o.viewer ?? 'other';
  const subscribed = [...(o.subscribe ?? [])];
  if (o.src === 'c1' && !subscribed.includes(C1)) subscribed.push(C1);

  const global = [...(o.global ?? [])];
  if (pref !== 'unset') global.push([o.val, pref]);
  const scoped = [];
  let scopedTag = '';
  if (o.scoped) {
    const [key, value] = o.scoped;
    const did = sourceDid(key, t.owner);
    scoped.push([did, o.val, value]);
    scopedTag = `scoped${DID_TAG[did] ?? 'X'}${cap(value)}`;
  }
  const prefTag = [pref === 'unset' && scopedTag ? 'prefUnset' : `pref${cap(pref)}`, scopedTag].filter(Boolean).join('+');

  const lbl = label(src, t.uri, o.val, o.labelExtra);
  const built = subjectFor(o.target, [lbl, ...(o.moreLabels ?? [])], { images: o.images });
  const id = [
    ...(o.family ? [o.family] : []),
    o.target,
    o.val,
    o.src,
    adultTag(adult),
    prefTag,
    viewer,
    ...(o.images ? ['img'] : []),
    ...(o.tag ? [o.tag] : []),
  ].join('/');

  await add({
    id,
    kind: built.kind,
    shape: built.shape,
    viewer,
    prefs: { adult, global, scoped, subscribed },
    defs: o.defs,
    subject: built.subject,
    catbird: o.catbird,
  });
}

const both = [true, false];
const PREF4 = ['unset', 'ignore', 'warn', 'hide'];
const opposite = { ignore: 'hide', warn: 'ignore', hide: 'ignore' };

// ---------------------------------------------------------------------------
// FAMILY: post-level labels (target = post content)
// ---------------------------------------------------------------------------

async function familyPost() {
  const target = 'post';
  // "!" labels are not configurable: the source and the viewer matter; adult mode and preferences must not.
  for (const val of BANG) {
    for (const viewer of ['other', 'me', 'out']) await labelScenario({ target, val, src: 'bsky', viewer });
  }
  for (const [val, src] of [
    ['!hide', 'c1'],
    ['!hide', 'unsub'],
    ['!hide', 'self'], // no-self: ignored
    ['!warn', 'self'], // no-self: ignored
    ['!no-unauthenticated', 'self'], // not no-self: accepted
  ]) {
    await labelScenario({ target, val, src });
  }
  await labelScenario({ target, val: '!hide', src: 'bsky', adult: false });
  await labelScenario({ target, val: '!hide', src: 'bsky', pref: 'ignore' }); // bogus global pref
  await labelScenario({ target, val: '!hide', src: 'bsky', scoped: ['bsky', 'ignore'] }); // bogus scoped pref

  // configurable adult labels: source x adult mode x global preference
  for (const val of CONF) {
    for (const adult of both) {
      for (const pref of PREF4) await labelScenario({ target, val, src: 'bsky', adult, pref });
    }
  }
  for (const adult of both) {
    for (const pref of ['unset', 'hide']) await labelScenario({ target, val: 'porn', src: 'self', adult, pref });
    for (const val of ['sexual', 'nudity', 'graphic-media']) await labelScenario({ target, val, src: 'self', adult });
    await labelScenario({ target, val: 'porn', src: 'c1', adult });
  }
  await labelScenario({ target, val: 'graphic-media', src: 'c1', adult: false });
  await labelScenario({ target, val: 'porn', src: 'unsub' });

  // other viewers: isMe suppresses filters and no-override; logged-out changes nothing for these
  for (const adult of both) await labelScenario({ target, val: 'porn', src: 'bsky', adult, pref: 'hide', viewer: 'me' });
  await labelScenario({ target, val: 'porn', src: 'bsky', pref: 'hide', viewer: 'out' });

  // image posts: same decisions, different subject shape
  await labelScenario({ target, val: 'porn', src: 'bsky', pref: 'hide', images: true });
  await labelScenario({ target, val: '!hide', src: 'bsky', images: true });
  await labelScenario({ target, val: 'porn', src: 'self', images: true });
  await labelScenario({ target, val: 'sexual', src: 'bsky', images: true });
  await labelScenario({ target, val: 'porn', src: 'bsky', adult: false, pref: 'hide', images: true });
  await labelScenario({ target, val: 'graphic-media', src: 'bsky', adult: false, images: true });

  // labeler-scoped preferences beat the global one, but never the forced hide when adult content is off
  for (const scoped of ['ignore', 'warn', 'hide']) {
    for (const adult of both) await labelScenario({ target, val: 'porn', src: 'bsky', adult, scoped: ['bsky', scoped] });
    await labelScenario({ target, val: 'porn', src: 'bsky', pref: opposite[scoped], scoped: ['bsky', scoped] });
  }
  for (const [val, scoped] of [
    ['sexual', 'ignore'],
    ['nudity', 'hide'],
  ]) {
    await labelScenario({ target, val, src: 'bsky', scoped: ['bsky', scoped] });
  }
  for (const scoped of ['ignore', 'hide']) await labelScenario({ target, val: 'porn', src: 'c1', scoped: ['c1', scoped] });
  // a scoped preference for a DIFFERENT labeler must not apply
  await labelScenario({ target, val: 'porn', src: 'bsky', scoped: ['c1', 'ignore'], subscribe: [C1] });
  await labelScenario({ target, val: 'porn', src: 'c1', scoped: ['bsky', 'ignore'], pref: 'warn' });
}

// ---------------------------------------------------------------------------
// FAMILY: account labels and profile-self labels on a post's author
// ---------------------------------------------------------------------------

async function familyAuthor() {
  // account label (uri = the author's DID)
  {
    const target = 'post-account';
    for (const val of BANG) await labelScenario({ target, val, src: 'bsky' });
    await labelScenario({ target, val: '!hide', src: 'bsky', viewer: 'me' });
    await labelScenario({ target, val: '!no-unauthenticated', src: 'bsky', viewer: 'out' });
    for (const adult of both) {
      for (const pref of ['unset', 'hide']) await labelScenario({ target, val: 'porn', src: 'bsky', adult, pref });
      await labelScenario({ target, val: 'sexual', src: 'bsky', adult });
    }
    await labelScenario({ target, val: 'porn', src: 'bsky', pref: 'warn' });
    await labelScenario({ target, val: 'nudity', src: 'bsky', pref: 'warn' });
    await labelScenario({ target, val: 'graphic-media', src: 'bsky', adult: false });
    await labelScenario({ target, val: 'porn', src: 'bsky', pref: 'hide', viewer: 'me' });
    await labelScenario({ target, val: 'porn', src: 'c1' });
  }
  // profile-self label (uri = at://<did>/app.bsky.actor.profile/self); this is where self-labels live
  {
    const target = 'post-profile';
    for (const val of BANG) await labelScenario({ target, val, src: 'bsky' });
    await labelScenario({ target, val: '!no-unauthenticated', src: 'self' }); // accepted: not no-self
    await labelScenario({ target, val: '!hide', src: 'self' }); // no-self: ignored
    for (const adult of both) {
      for (const pref of ['unset', 'hide']) await labelScenario({ target, val: 'porn', src: 'self', adult, pref });
    }
    await labelScenario({ target, val: 'porn', src: 'bsky' });
    await labelScenario({ target, val: 'sexual', src: 'self' });
    await labelScenario({ target, val: 'graphic-media', src: 'self', adult: false });
    await labelScenario({ target, val: 'nudity', src: 'self', pref: 'warn' });
    await labelScenario({ target, val: 'porn', src: 'self', pref: 'hide', viewer: 'me' });
  }
}

// ---------------------------------------------------------------------------
// FAMILY: quoted posts (record and recordWithMedia shapes)
// ---------------------------------------------------------------------------

async function familyQuote() {
  // quote (record shape): content label, author account label, author profile-self label
  {
    const target = 'quote';
    for (const val of BANG) await labelScenario({ target, val, src: 'bsky' });
    await labelScenario({ target, val: '!hide', src: 'bsky', viewer: 'me' });
    await labelScenario({ target, val: '!hide', src: 'bsky', viewer: 'quoted' });
    await labelScenario({ target, val: '!no-unauthenticated', src: 'bsky', viewer: 'out' });
    for (const [val, adult, pref] of [
      ['porn', true, 'unset'],
      ['porn', true, 'warn'],
      ['porn', false, 'unset'],
      ['sexual', true, 'hide'],
      ['nudity', true, 'warn'],
      ['graphic-media', false, 'unset'],
    ]) {
      await labelScenario({ target, val, src: 'bsky', adult, pref });
    }
    for (const src of ['c1', 'self']) await labelScenario({ target, val: 'porn', src });
    await labelScenario({ target, val: 'porn', src: 'bsky', pref: 'hide', viewer: 'me' });
  }
  {
    const target = 'quote-account';
    for (const val of ['!hide', '!no-unauthenticated']) await labelScenario({ target, val, src: 'bsky' });
    for (const [adult, pref] of [[true, 'unset'], [true, 'warn'], [false, 'unset']]) {
      await labelScenario({ target, val: 'porn', src: 'bsky', adult, pref });
    }
    await labelScenario({ target, val: 'porn', src: 'c1' });
  }
  {
    const target = 'quote-profile';
    await labelScenario({ target, val: '!hide', src: 'bsky' });
    for (const [adult, pref] of [[true, 'unset'], [true, 'warn'], [false, 'unset']]) {
      await labelScenario({ target, val: 'porn', src: 'bsky', adult, pref });
    }
    await labelScenario({ target, val: 'porn', src: 'self' });
  }
  // quotemedia (recordWithMedia shape)
  {
    const target = 'quotemedia';
    await labelScenario({ target, val: '!hide', src: 'bsky' });
    for (const [adult, pref] of [[true, 'unset'], [true, 'warn'], [false, 'unset']]) {
      await labelScenario({ target, val: 'porn', src: 'bsky', adult, pref });
    }
    await labelScenario({ target, val: 'sexual', src: 'bsky', pref: 'hide' });
    await labelScenario({ target, val: 'porn', src: 'self' });
  }
  await labelScenario({ target: 'quotemedia-account', val: '!hide', src: 'bsky' });
  for (const adult of both) await labelScenario({ target: 'quotemedia-account', val: 'porn', src: 'bsky', adult });
  await labelScenario({ target: 'quotemedia-profile', val: '!warn', src: 'bsky' });
  await labelScenario({ target: 'quotemedia-profile', val: 'porn', src: 'bsky' });
  await labelScenario({ target: 'quotemedia-profile', val: 'porn', src: 'self' });
}

// ---------------------------------------------------------------------------
// FAMILY: moderateProfile subjects (account label / profile-self label)
// ---------------------------------------------------------------------------

async function familyProfile() {
  {
    const target = 'profile-account';
    for (const val of BANG) await labelScenario({ target, val, src: 'bsky' });
    await labelScenario({ target, val: '!hide', src: 'bsky', viewer: 'me' });
    await labelScenario({ target, val: '!no-unauthenticated', src: 'bsky', viewer: 'out' });
    await labelScenario({ target, val: '!hide', src: 'c1' });
    for (const adult of both) {
      for (const pref of ['unset', 'warn', 'hide']) await labelScenario({ target, val: 'porn', src: 'bsky', adult, pref });
    }
    for (const pref of ['unset', 'hide']) await labelScenario({ target, val: 'sexual', src: 'bsky', pref });
    await labelScenario({ target, val: 'graphic-media', src: 'bsky', adult: false });
    await labelScenario({ target, val: 'nudity', src: 'bsky', pref: 'warn' });
    await labelScenario({ target, val: 'porn', src: 'bsky', pref: 'hide', viewer: 'me' });
    await labelScenario({ target, val: 'porn', src: 'bsky', pref: 'hide', viewer: 'out' });
    await labelScenario({ target, val: 'porn', src: 'unsub' });
  }
  {
    const target = 'profile-profile';
    for (const val of BANG) await labelScenario({ target, val, src: 'bsky' });
    await labelScenario({ target, val: '!no-unauthenticated', src: 'self' });
    await labelScenario({ target, val: '!hide', src: 'self' });
    for (const adult of both) {
      for (const pref of ['unset', 'hide']) await labelScenario({ target, val: 'porn', src: 'self', adult, pref });
    }
    await labelScenario({ target, val: 'porn', src: 'bsky' });
    await labelScenario({ target, val: 'sexual', src: 'self' });
    await labelScenario({ target, val: 'graphic-media', src: 'self', adult: false });
    await labelScenario({ target, val: 'nudity', src: 'self', pref: 'warn' });
    await labelScenario({ target, val: 'porn', src: 'self', pref: 'hide', viewer: 'me' });
  }
  // a profile carrying both an account label and a profile-self label of different kinds
  await add({
    id: 'profile/mixed/account-porn+profile-sexual/adultOn/prefUnset/other',
    kind: 'profile',
    shape: 'profile',
    viewer: 'other',
    prefs: { adult: true },
    subject: buildProfile({
      labels: [label(BSKY, AUTHOR, 'porn'), label(AUTHOR, profileSelfUri(AUTHOR), 'sexual')],
    }),
  });
  // "!no-unauthenticated" on the profile record also counts as an account label
  for (const viewer of ['other', 'out']) {
    await add({
      id: `profile/!no-unauthenticated/profile-record-counts-as-account-too/adultOn/${viewer}`,
      kind: 'profile',
      shape: 'profile',
      viewer,
      prefs: { adult: true },
      subject: buildProfile({ labels: [label(BSKY, profileSelfUri(AUTHOR), '!no-unauthenticated')] }),
    });
  }
}

// ---------------------------------------------------------------------------
// FAMILY: custom labeler definitions
// ---------------------------------------------------------------------------

const DEF_BLURS = ['content', 'media', 'none'];
const DEF_SEVERITY = ['alert', 'inform', 'none'];
/** A `blurs` / `severity` string the lexicon allows (both are open strings) but the sdk does not recognize. */
const UNKNOWN_DEF_VALUE = 'weird';

async function customScenario(o) {
  const def = makeDef(o.def);
  await labelScenario({
    target: o.target ?? 'post',
    val: def.identifier,
    src: o.src ?? 'c1',
    adult: o.adult ?? true,
    pref: o.pref ?? 'unset',
    scoped: o.scoped,
    viewer: o.viewer,
    family: o.family ?? 'custom',
    tag: o.tag,
    defs: { [o.defsDid ?? C1]: [def, ...(o.moreDefs ?? [])] },
    catbird: o.catbird,
    moreLabels: o.moreLabels,
    labelExtra: o.labelExtra,
    subscribe: o.subscribe,
    global: o.global,
  });
}

async function familyCustom() {
  const warnDef = (blurs, severity, extra = {}) => ({ blurs, severity, defaultSetting: 'warn', ...extra });
  // definition shapes on a post-level label from a subscribed custom labeler
  for (const blurs of DEF_BLURS) {
    for (const severity of DEF_SEVERITY) await customScenario({ def: warnDef(blurs, severity) });
    await customScenario({ def: warnDef(blurs, 'alert', { adultOnly: true }) });
  }
  // adult-only combines with severity differently per blur kind (content: contentView always blurs)
  await customScenario({ def: warnDef('content', 'inform', { adultOnly: true }) });
  await customScenario({ def: warnDef('content', 'none', { adultOnly: true }) });
  await customScenario({ def: warnDef('media', 'inform', { adultOnly: true }) });
  await customScenario({ def: { blurs: 'content', severity: 'alert', defaultSetting: 'hide' } });
  await customScenario({ def: { blurs: 'content', severity: 'alert', defaultSetting: 'ignore' } });
  // defaultSetting absent / unrecognised falls back to warn
  await customScenario({ def: { id: 'content-alert-nodefault', blurs: 'content', severity: 'alert' } });
  await customScenario({ def: { id: 'content-alert-weirddefault', blurs: 'content', severity: 'alert', defaultSetting: 'block' } });
  // blurs / severity values the sdk does not recognize: an unknown blurs yields no behaviors at all, an unknown severity
  // yields blur behaviors but never an alert or an inform (interpretLabelValueDefinition compares both by equality)
  for (const severity of DEF_SEVERITY) await customScenario({ def: warnDef(UNKNOWN_DEF_VALUE, severity) });
  await customScenario({ def: warnDef(UNKNOWN_DEF_VALUE, 'alert', { adultOnly: true }) });
  await customScenario({ def: warnDef(UNKNOWN_DEF_VALUE, 'alert', { adultOnly: true }), adult: false });
  await customScenario({ def: { blurs: UNKNOWN_DEF_VALUE, severity: 'alert', defaultSetting: 'hide' } });
  await customScenario({ def: { blurs: UNKNOWN_DEF_VALUE, severity: 'alert', defaultSetting: 'hide' }, pref: 'warn' });
  for (const blurs of DEF_BLURS) {
    await customScenario({ def: warnDef(blurs, UNKNOWN_DEF_VALUE) });
    await customScenario({ def: warnDef(blurs, UNKNOWN_DEF_VALUE, { adultOnly: true }) });
    await customScenario({ def: warnDef(blurs, UNKNOWN_DEF_VALUE, { adultOnly: true }), adult: false });
  }
  await customScenario({ def: { blurs: 'content', severity: UNKNOWN_DEF_VALUE, defaultSetting: 'hide' } });
  for (const target of ['post-account', 'post-profile', 'quote', 'profile-account', 'profile-profile']) {
    await customScenario({ def: warnDef(UNKNOWN_DEF_VALUE, 'alert'), target });
    await customScenario({ def: warnDef('content', UNKNOWN_DEF_VALUE), target });
  }
  // adult-only definitions with adult content disabled: forced hide, no override
  for (const blurs of DEF_BLURS) await customScenario({ def: warnDef(blurs, 'alert', { adultOnly: true }), adult: false });
  await customScenario({ def: warnDef('content', 'alert'), adult: false }); // not adult-only: unaffected
  // explicit global / labeler-scoped preference over a definition default
  for (const [blurs, pref] of [['content', 'ignore'], ['content', 'hide'], ['media', 'hide']]) {
    await customScenario({ def: warnDef(blurs, 'alert'), pref });
  }
  for (const pref of ['ignore', 'hide']) await customScenario({ def: warnDef('content', 'alert', { adultOnly: true }), pref });
  for (const value of ['ignore', 'hide']) await customScenario({ def: warnDef('content', 'alert'), scoped: ['c1', value] });
  await customScenario({ def: { blurs: 'content', severity: 'alert', defaultSetting: 'hide' }, pref: 'warn' });
  await customScenario({ def: { blurs: 'media', severity: 'alert', defaultSetting: 'ignore' }, pref: 'hide' });
  // custom labels on other targets
  for (const target of ['post-account', 'post-profile', 'quote', 'profile-account', 'profile-profile']) {
    for (const blurs of target === 'quote' || target === 'profile-account' ? ['content', 'media'] : ['content']) {
      await customScenario({ def: warnDef(blurs, 'alert'), target });
    }
  }
  await customScenario({ def: warnDef('content', 'alert'), target: 'quote-account' });
  await customScenario({ def: warnDef('media', 'alert'), target: 'quotemedia' });
  // viewer variations
  await customScenario({ def: { blurs: 'content', severity: 'alert', defaultSetting: 'hide' }, viewer: 'me' });
}

/** Labels the labeler does not (or cannot) define, and values the sdk does not know: ignored. */
async function familyUndefined() {
  const d = makeDef({ blurs: 'content', severity: 'alert', defaultSetting: 'warn' });
  const mk = (id, labelVal, src, defs, extra = {}) =>
    add({
      id: `custom/${id}`,
      kind: 'post',
      shape: 'text',
      viewer: 'other',
      prefs: { adult: true, subscribed: extra.subscribed ?? [C1] },
      defs,
      subject: buildPost({ postLabels: [label(src, POST_URI, labelVal)] }),
    });
  await mk('undefined-value/c1-no-definitions', 'not-defined', C1, undefined);
  await mk('defined-by-other-labeler/c2-defines-c1-labels', d.identifier, C1, { [C2]: [d] }, { subscribed: [C1, C2] });
  await mk('defined-by-same-labeler/control', d.identifier, C1, { [C1]: [d] });
  await mk('definition-belongs-to-c1/label-from-bsky', d.identifier, BSKY, { [C1]: [d] });
  await mk('definition-present/label-from-unsubscribed', d.identifier, UNSUB, { [UNSUB]: [d] });
  await mk('definition-keyed-by-author/self-label', d.identifier, AUTHOR, { [AUTHOR]: [d] });
  for (const bad of ['Spoiler', 'spoil_er']) {
    const bd = rawDef({ id: bad, blurs: 'content', severity: 'alert', defaultSetting: 'hide' });
    await mk(`invalid-identifier/${bad}`, bad, C1, { [C1]: [bd] });
  }
  // legacy / non-builtin names the sdk's LABELS table does not contain
  for (const val of ['nsfw', 'suggestive', '!takedown', 'PORN']) {
    await add({
      id: `unknown/${val}/bsky/adultOn/prefUnset/other`,
      kind: 'post',
      shape: 'text',
      viewer: 'other',
      prefs: { adult: true },
      subject: buildPost({ postLabels: [label(BSKY, POST_URI, val)] }),
    });
  }
  // "gore" is still in the sdk LABELS table as a deprecated alias of graphic-media, with its own preference key
  for (const [adult, tag, global] of [
    [true, 'prefUnset', []],
    [true, 'prefGoreHide', [['gore', 'hide']]],
    [true, 'prefGraphicMediaHide', [['graphic-media', 'hide']]],
    [true, 'prefGoreIgnore', [['gore', 'ignore']]],
    [false, 'prefUnset', []],
  ]) {
    await add({
      id: `unknown/gore/bsky/${adultTag(adult)}/${tag}/other`,
      kind: 'post',
      shape: 'text',
      viewer: 'other',
      prefs: { adult, global },
      subject: buildPost({ postLabels: [label(BSKY, POST_URI, 'gore')] }),
    });
  }
}

// ---------------------------------------------------------------------------
// FAMILY: ordering and multiple labels / labelers
// ---------------------------------------------------------------------------

async function familyOrderAndMulti() {
  const defAdult = makeDef({ blurs: 'content', severity: 'alert', defaultSetting: 'warn', adultOnly: true });
  const defInform = makeDef({ blurs: 'none', severity: 'inform', defaultSetting: 'warn' });
  const defX = makeDef({ id: 'content-alert-warn-x', blurs: 'content', severity: 'alert', defaultSetting: 'warn' });
  const defY = makeDef({ id: 'content-alert-warn-y', blurs: 'content', severity: 'alert', defaultSetting: 'warn' });

  const labelsByKey = {
    A_hide: label(BSKY, POST_URI, '!hide'), //             priority 1
    B_porn: label(BSKY, POST_URI, 'porn'), //              hide by default, priority 2
    C_adult: label(C1, POST_URI, defAdult.identifier), //  adult-only content blur, priority 5
    D_sexual: label(BSKY, POST_URI, 'sexual'), //          warn, media blur, priority 7
    E_inform: label(C1, POST_URI, defInform.identifier), // inform only, priority 8
    X: label(C1, POST_URI, defX.identifier), //            priority 7
    Y: label(C1, POST_URI, defY.identifier), //            priority 7
  };
  const defsFor = (keys) => {
    const byKey = { C_adult: defAdult, E_inform: defInform, X: defX, Y: defY };
    const used = keys.filter((k) => byKey[k]).map((k) => byKey[k]);
    return used.length ? { [C1]: used } : undefined;
  };
  const orderScenario = (name, keys) =>
    add({
      id: `order/${name}`,
      kind: 'post',
      shape: 'text',
      viewer: 'other',
      prefs: { adult: true, subscribed: [C1] },
      defs: defsFor(keys),
      subject: buildPost({ postLabels: keys.map((k) => labelsByKey[k]) }),
    });

  for (const [a, b] of [
    ['A_hide', 'B_porn'],
    ['A_hide', 'C_adult'],
    ['B_porn', 'C_adult'],
    ['B_porn', 'D_sexual'],
    ['C_adult', 'D_sexual'],
    ['C_adult', 'E_inform'],
    ['D_sexual', 'E_inform'],
    ['D_sexual', 'B_porn'],
  ]) {
    await orderScenario(`pair/${a}+${b}`, [a, b]);
  }
  await orderScenario('all/shuffled', ['C_adult', 'E_inform', 'A_hide', 'D_sexual', 'B_porn']);
  await orderScenario('tie/X+Y', ['X', 'Y']);
  await orderScenario('tie/Y+X', ['Y', 'X']);
  await orderScenario('tie/X+D_sexual', ['X', 'D_sexual']);
  await orderScenario('tie/D_sexual+X', ['D_sexual', 'X']);
  // equal priority across targets: post label first, then quote, then account, then profile
  const porn = (uri, src = BSKY) => label(src, uri, 'porn');
  await add({
    id: 'order/cross-target/porn-warn-on-post+account+profile+quote',
    kind: 'post',
    shape: 'quote',
    viewer: 'other',
    prefs: { adult: true, global: [['porn', 'warn']] },
    subject: buildPost({
      postLabels: [porn(POST_URI)],
      authorLabels: [porn(AUTHOR), porn(profileSelfUri(AUTHOR))],
      quote: { labels: [porn(QUOTE_URI)], authorLabels: [porn(QUOTED), porn(profileSelfUri(QUOTED))] },
    }),
  });

  // multiple labelers labeling the same value
  const sameValue = async (name, labelers, prefs) =>
    add({
      id: `multi/${name}`,
      kind: 'post',
      shape: 'text',
      viewer: 'other',
      prefs: { adult: true, subscribed: [C1, C2], ...prefs },
      subject: buildPost({ postLabels: labelers.map((l) => label(l, POST_URI, 'porn')) }),
    });
  await sameValue('porn/bsky+c1', [BSKY, C1], {});
  await sameValue('porn/bsky+c1+c2', [BSKY, C1, C2], {});
  await sameValue('porn/c1+bsky/scoped-c1-ignore', [C1, BSKY], { scoped: [[C1, 'porn', 'ignore']] });
  await sameValue('porn/bsky+c1/scoped-bsky-ignore+c1-hide', [BSKY, C1], {
    global: [['porn', 'warn']],
    scoped: [[BSKY, 'porn', 'ignore'], [C1, 'porn', 'hide']],
  });
  await add({
    id: 'multi/porn/bsky+self',
    kind: 'post',
    shape: 'text',
    viewer: 'other',
    prefs: { adult: true },
    subject: buildPost({ postLabels: [label(BSKY, POST_URI, 'porn'), label(AUTHOR, POST_URI, 'porn')] }),
  });
  await add({
    id: 'multi/porn/same-src-different-uri-both-count',
    kind: 'post',
    shape: 'text',
    viewer: 'other',
    prefs: { adult: true, global: [['porn', 'warn']] },
    subject: buildPost({ postLabels: [label(BSKY, POST_URI, 'porn'), label(BSKY, `${POST_URI}-other`, 'porn')] }),
  });
  // same custom value defined differently by two labelers; each label resolves its own labeler's definition
  const dC1 = makeDef({ id: 'shared-value', blurs: 'content', severity: 'alert', defaultSetting: 'warn' });
  const dC2 = makeDef({ id: 'shared-value', blurs: 'media', severity: 'inform', defaultSetting: 'hide' });
  const shared = (name, labelers, prefs = {}) =>
    add({
      id: `multi/custom-shared-value/${name}`,
      kind: 'post',
      shape: 'text',
      viewer: 'other',
      prefs: { adult: true, subscribed: [C1, C2], ...prefs },
      defs: { [C1]: [dC1], [C2]: [dC2] },
      subject: buildPost({ postLabels: labelers.map((l) => label(l, POST_URI, 'shared-value')) }),
    });
  await shared('c2', [C2]);
  await shared('c1+c2', [C1, C2]);
  await shared('c2+c1', [C2, C1]);
  await shared('c1+c2/global-hide', [C1, C2], { global: [['shared-value', 'hide']] });
  await shared('c1+c2/scoped-c2-ignore', [C1, C2], { scoped: [[C2, 'shared-value', 'ignore']] });
}

// ---------------------------------------------------------------------------
// FAMILY: other restrictions combined with media-only label blur
// ---------------------------------------------------------------------------

async function familyRestriction() {
  const list = { uri: `at://${LISTER}/app.bsky.graph.list/l1`, cid: PLACEHOLDER_CID, name: 'list', purpose: 'app.bsky.graph.defs#modlist' };
  const block = `at://${VIEWER}/app.bsky.graph.block/b1`;
  const restrictions = {
    muted: { authorViewer: { muted: true } },
    'muted-by-list': { authorViewer: { muted: true, mutedByList: list } },
    blocking: { authorViewer: { blocking: block } },
    'blocking-by-list': { authorViewer: { blocking: block, blockingByList: list } },
    'blocked-by': { authorViewer: { blockedBy: true } },
    hidden: { prefs: { hiddenPosts: [POST_URI] } },
    'mute-word': {
      prefs: { mutedWords: [{ value: 'spoilerword', targets: ['content'], actorTarget: 'all' }] },
      record: { $type: 'app.bsky.feed.post', text: 'this has spoilerword in it', createdAt: CTS, langs: ['en'] },
    },
  };
  const labelStates = {
    none: { global: [], labels: [] },
    'porn-media-warn': { global: [['porn', 'warn']], labels: [label(BSKY, POST_URI, 'porn')] },
    'porn-hide': { global: [], labels: [label(BSKY, POST_URI, 'porn')] },
  };
  const run = async (rName, lName, adult, viewer) => {
    const r = restrictions[rName];
    const ls = labelStates[lName];
    await add({
      id: `restriction/${rName}/${lName}/${adultTag(adult)}/${viewer}`,
      kind: 'post',
      shape: 'text',
      viewer,
      prefs: { adult, global: ls.global, ...r.prefs },
      subject: buildPost({ postLabels: ls.labels, authorViewer: r.authorViewer, record: r.record }),
    });
  };
  for (const rName of ['muted', 'blocking', 'blocked-by', 'hidden', 'mute-word']) {
    if (rName === 'muted' || rName === 'hidden' || rName === 'mute-word') await run(rName, 'none', true, 'other');
    await run(rName, 'porn-media-warn', true, 'other');
    await run(rName, 'porn-hide', true, 'other');
  }
  await run('muted', 'porn-media-warn', true, 'me');
  await run('muted-by-list', 'porn-media-warn', true, 'other');
  await run('blocking-by-list', 'porn-media-warn', true, 'other');
  await run('muted', 'porn-media-warn', false, 'other');

  // the account itself restricted, with an avatar-level (account) label
  for (const [rName, viewerState] of [['muted', { muted: true }], ['blocking', { blocking: block }]]) {
    for (const withLabel of rName === 'muted' ? both : [true]) {
      await add({
        id: `restriction/profile-${rName}/${withLabel ? 'porn-account-warn' : 'none'}/adultOn/other`,
        kind: 'profile',
        shape: 'profile',
        viewer: 'other',
        prefs: { adult: true, global: [['porn', 'warn']] },
        subject: buildProfile({ labels: withLabel ? [label(BSKY, AUTHOR, 'porn')] : [], viewer: viewerState }),
      });
    }
  }
  // blocked / restricted quoted post (viewBlocked) under an outer post
  const quoteStates = {
    blocking: { blocking: `at://${VIEWER}/app.bsky.graph.block/b2` },
    'blocked-by': { blockedBy: true },
    muted: { muted: true }, // viewBlocked reads viewer.muted too
  };
  for (const [qName, blocked] of Object.entries(quoteStates)) {
    for (const [media, outer] of [[false, true], [true, false]]) {
      const p = { quote: { media, blocked }, postLabels: outer ? [label(BSKY, POST_URI, 'porn')] : [] };
      await add({
        id: `blockedquote/${qName}/${media ? 'withMedia' : 'record'}/${outer ? 'porn-media-warn' : 'none'}/adultOn/other`,
        kind: 'post',
        shape: postShape(p),
        viewer: 'other',
        prefs: { adult: true, global: [['porn', 'warn']] },
        subject: buildPost(p),
      });
    }
  }
}

// ---------------------------------------------------------------------------
// FAMILY: intentional Catbird deviations
// ---------------------------------------------------------------------------

async function familyDeviation() {
  const dSpoiler = makeDef({ id: 'spoiler', blurs: 'content', severity: 'alert', defaultSetting: 'hide' });

  // (a) negated / expired labels
  const inactive = [
    ['neg', { neg: true }],
    ['exp-past', { exp: EXP_PAST }],
  ];
  for (const [tag, extra] of inactive) {
    for (const [val, target, src, defs] of [
      ['porn', 'post', 'bsky'],
      ['!hide', 'post', 'bsky'],
      ['spoiler', 'post', 'c1', { [C1]: [dSpoiler] }],
      ['porn', 'post-account', 'bsky'],
      ['porn', tag === 'neg' ? 'post-profile' : 'quote', tag === 'neg' ? 'self' : 'bsky'],
    ]) {
      await labelScenario({ target, val, src, defs, labelExtra: extra, family: `deviation/inactive-${tag}`, catbird: DEV.inactive });
    }
    // adult content disabled: still ignored by Catbird because the label is not active
    await labelScenario({ target: 'post', val: 'porn', src: 'bsky', adult: false, labelExtra: extra, family: `deviation/inactive-${tag}`, catbird: DEV.inactive });
    // only the inactive one of two labels is dropped
    await add({
      id: `deviation/inactive-${tag}/two-labels-only-one-inactive`,
      kind: 'post',
      shape: 'text',
      viewer: 'other',
      prefs: { adult: true },
      subject: buildPost({
        postLabels: [label(BSKY, POST_URI, 'porn', extra), label(BSKY, POST_URI, 'sexual')],
      }),
      catbird: DEV.inactive,
    });
  }
  // controls: still-active labels must match the sdk exactly (no catbird field)
  await labelScenario({ target: 'post', val: 'porn', src: 'bsky', labelExtra: { exp: EXP_FUTURE }, family: 'deviation/active-control-exp-future' });
  await labelScenario({ target: 'post', val: 'porn', src: 'bsky', labelExtra: { neg: false, exp: EXP_FUTURE }, family: 'deviation/active-control-neg-false-exp-future' });

  // (b) redefining a builtin identifier / "!"-prefixed value
  const weaken = (id) => rawDef({ id, blurs: 'none', severity: 'none', defaultSetting: 'ignore' });
  const strengthen = (id) => rawDef({ id, blurs: 'content', severity: 'alert', defaultSetting: 'hide', adultOnly: true });
  for (const val of [...CONF, DEPRECATED_BUILTIN]) {
    // the seeded global default for nudity is "ignore", which beats any definition default, so use an explicit "warn"
    const pref = val === 'nudity' ? 'warn' : 'unset';
    const variants = ['porn', 'nudity', DEPRECATED_BUILTIN].includes(val) ? [['weaken', weaken(val)], ['strengthen', strengthen(val)]] : [['weaken', weaken(val)]];
    for (const [tag, d] of variants) {
      await labelScenario({ target: 'post', val, src: 'c1', pref, defs: { [C1]: [d] }, family: `deviation/builtin-redefined-${tag}`, catbird: DEV.builtinDef });
    }
  }
  await labelScenario({ target: 'post', val: 'porn', src: 'c1', adult: false, defs: { [C1]: [strengthen('porn')] }, family: 'deviation/builtin-redefined-strengthen', catbird: DEV.builtinDef });
  await labelScenario({ target: 'post-account', val: 'porn', src: 'c1', defs: { [C1]: [weaken('porn')] }, family: 'deviation/builtin-redefined-weaken', catbird: DEV.builtinDef });
  await labelScenario({ target: 'quote', val: 'sexual', src: 'c1', defs: { [C1]: [weaken('sexual')] }, family: 'deviation/builtin-redefined-weaken', catbird: DEV.builtinDef });
  for (const val of BANG) {
    await labelScenario({ target: 'post', val, src: 'c1', defs: { [C1]: [weaken(val)] }, family: 'deviation/bang-redefined-weaken', catbird: DEV.builtinDef });
  }
  await labelScenario({ target: 'post', val: '!hide', src: 'c1', defs: { [C1]: [strengthen('!hide')] }, family: 'deviation/bang-redefined-strengthen', catbird: DEV.builtinDef });
  // the redefinition is dropped but an ordinary definition by the same labeler still works
  await add({
    id: 'deviation/builtin-redefined-weaken/with-ordinary-definition/porn+spoiler/c1/adultOn/prefUnset/other',
    kind: 'post',
    shape: 'text',
    viewer: 'other',
    prefs: { adult: true, subscribed: [C1] },
    defs: { [C1]: [weaken('porn'), dSpoiler] },
    subject: buildPost({ postLabels: [label(C1, POST_URI, 'porn'), label(C1, POST_URI, 'spoiler')] }),
    catbird: DEV.builtinDef,
  });
  // a redefinition by a labeler that is not the label's source never applied; the result is unchanged
  await add({
    id: 'deviation/control-redefinition-unused/c1-defines-porn-but-bsky-labels/adultOn/prefUnset/other',
    kind: 'post',
    shape: 'text',
    viewer: 'other',
    prefs: { adult: true, subscribed: [C1] },
    defs: { [C1]: [weaken('porn')] },
    subject: buildPost({ postLabels: [label(BSKY, POST_URI, 'porn')] }),
    catbird: DEV.builtinDef,
  });

  // (c) duplicate identical labels
  const dupOf = (o) => ({
    ...o,
    family: 'deviation/duplicate',
    catbird: DEV.duplicate,
    moreLabels: [label(sourceDid(o.src, TARGETS[o.target].owner), TARGETS[o.target].uri, o.val)],
  });
  for (const o of [
    { target: 'post', val: 'porn', src: 'bsky' },
    { target: 'post', val: '!warn', src: 'bsky' },
    { target: 'post', val: 'sexual', src: 'self' },
    { target: 'post', val: 'spoiler', src: 'c1', defs: { [C1]: [dSpoiler] } },
    { target: 'post-account', val: 'porn', src: 'bsky' },
    { target: 'quote', val: 'porn', src: 'bsky' },
    { target: 'profile-account', val: 'porn', src: 'bsky' },
  ]) {
    await labelScenario(dupOf(o));
  }
  // three copies
  await labelScenario({
    target: 'post',
    val: 'porn',
    src: 'bsky',
    family: 'deviation/duplicate',
    catbird: DEV.duplicate,
    moreLabels: [label(BSKY, POST_URI, 'porn'), label(BSKY, POST_URI, 'porn')],
    tag: 'three-copies',
  });
  // controls: different uri, different source, different value are NOT duplicates
  {
    const base = { target: 'post', val: 'porn', src: 'bsky', family: 'deviation/duplicate-control' };
    await labelScenario({ ...base, moreLabels: [label(BSKY, `${POST_URI}-other`, 'porn')], tag: 'different-uri' });
    await labelScenario({ ...base, moreLabels: [label(C1, POST_URI, 'porn')], subscribe: [C1], tag: 'different-source' });
    await labelScenario({ ...base, moreLabels: [label(BSKY, POST_URI, 'sexual')], tag: 'different-value' });
  }
}

// ---------------------------------------------------------------------------
// FAMILY: stored visibility strings the sdk does not recognise
// ---------------------------------------------------------------------------

/**
 * getPreferences passes an unrecognised visibility through unchanged (only exactly "show" is rewritten, to
 * "ignore"). decision.ts then reads a preference by truthiness: any non-empty string other than "ignore" and "hide"
 * overrides the default and behaves like "warn" (no filter, severity priority), and the empty string is falsy, so
 * it falls through to the next source (labeler-scoped, then global, then the definition default).
 */
async function familyUnknownVisibility() {
  const dSpoiler = makeDef({ id: 'spoiler', blurs: 'content', severity: 'alert', defaultSetting: 'hide' });
  for (const pref of ['block', 'HIDE', 'Show', '']) {
    const family = `unknown-visibility/${pref === '' ? 'empty' : pref}`;
    await labelScenario({ target: 'post', val: 'porn', src: 'bsky', pref, family });
    await labelScenario({ target: 'post', val: 'porn', src: 'bsky', adult: false, pref, family });
    await labelScenario({ target: 'post', val: 'sexual', src: 'bsky', pref, family });
    await labelScenario({ target: 'post', val: 'nudity', src: 'bsky', pref, family });
    await labelScenario({ target: 'post-account', val: 'porn', src: 'bsky', pref, family });
    await labelScenario({ target: 'post', val: 'gore', src: 'bsky', pref, family });
    await labelScenario({ target: 'post', val: 'spoiler', src: 'c1', pref, defs: { [C1]: [dSpoiler] }, family });
    // a labeler-scoped value is read before the global one
    await labelScenario({ target: 'post', val: 'porn', src: 'bsky', scoped: ['bsky', pref], family: `${family}/scoped` });
    await labelScenario({ target: 'post', val: 'spoiler', src: 'c1', scoped: ['c1', pref], defs: { [C1]: [dSpoiler] }, family: `${family}/scoped` });
  }
}

// ---------------------------------------------------------------------------
// PREFS section: raw server array -> real getPreferences
// ---------------------------------------------------------------------------

const prefCases = [];

/** raw: [[label, visibility, labelerDid?], ...] */
async function prefCase(id, { raw = [], adult = null, labelers = [], note } = {}) {
  const content = raw.map(([l, v, did]) => ({ label: l, visibility: v, ...(did !== undefined ? { labelerDid: did } : {}) }));
  const stored = { adult, labelers: labelers.length ? labelers : null };
  const normalized = await normalizedPrefs({ ...stored, content });
  const entry = {
    id,
    ...(note ? { note } : {}),
    raw: content,
    adultContentEnabled: adult,
    labelers,
    normalized,
  };
  // deviation (d): only cases whose Catbird reading differs from the sdk carry a catbird field
  const transformed = PRIVATE_KEY.transform(content);
  if (JSON.stringify(transformed) !== JSON.stringify(content)) {
    entry.catbird = {
      reason: PRIVATE_KEY.reason,
      raw: transformed,
      expected: await normalizedPrefs({ ...stored, content: transformed }),
    };
  }
  prefCases.push(entry);
}

async function buildPrefs() {
  await prefCase('empty');
  await prefCase('adult/true', { adult: true });
  await prefCase('adult/false', { adult: false });
  // each legacy key alone, plus the legacy 'show' value
  for (const v of ['hide', 'warn', 'ignore', 'show']) await prefCase(`legacy-alone/nsfw=${v}`, { raw: [['nsfw', v]] });
  await prefCase('legacy-alone/gore=hide', { raw: [['gore', 'hide']] });
  await prefCase('legacy-alone/suggestive=hide', { raw: [['suggestive', 'hide']] });
  // canonical keys alone
  for (const v of ['hide', 'warn', 'ignore', 'show']) await prefCase(`canonical-alone/porn=${v}`, { raw: [['porn', v]] });
  await prefCase('canonical-alone/sexual=hide', { raw: [['sexual', 'hide']] });
  await prefCase('canonical-alone/graphic-media=hide', { raw: [['graphic-media', 'hide']] });
  await prefCase('canonical-alone/nudity=warn', { raw: [['nudity', 'warn']] });
  // legacy + canonical with conflicting values, in both array orders (the last entry wins; the legacy name is also set)
  const pairs = [['nsfw', 'porn'], ['gore', 'graphic-media'], ['suggestive', 'sexual']];
  for (const [legacy, canonical] of pairs) {
    for (const [lv, cv] of legacy === 'nsfw' ? [['hide', 'ignore'], ['show', 'warn']] : [['hide', 'ignore']]) {
      await prefCase(`legacy+canonical/${legacy}=${lv}-then-${canonical}=${cv}`, { raw: [[legacy, lv], [canonical, cv]] });
      await prefCase(`canonical+legacy/${canonical}=${cv}-then-${legacy}=${lv}`, { raw: [[canonical, cv], [legacy, lv]] });
    }
  }
  await prefCase('duplicates/porn=hide-then-porn=warn', { raw: [['porn', 'hide'], ['porn', 'warn']] });
  await prefCase('duplicates/porn=warn-then-porn=hide', { raw: [['porn', 'warn'], ['porn', 'hide']] });
  await prefCase('duplicates/nsfw=ignore-then-porn=hide-then-nsfw=warn', { raw: [['nsfw', 'ignore'], ['porn', 'hide'], ['nsfw', 'warn']] });
  await prefCase('all-legacy-and-canonical', {
    raw: [['nsfw', 'warn'], ['suggestive', 'hide'], ['gore', 'ignore'], ['porn', 'hide'], ['sexual', 'ignore'], ['graphic-media', 'hide']],
  });
  // unknown visibility strings are passed through unchanged (only 'show' is rewritten)
  for (const v of ['block', 'HIDE', '']) {
    await prefCase(`unknown-visibility/porn=${JSON.stringify(v)}`, { raw: [['porn', v]] });
  }
  await prefCase('unknown-visibility/custom="block"', { raw: [['spoiler', 'block']] });
  await prefCase('unknown-visibility/scoped-bsky="block"', { raw: [['porn', 'block', BSKY]] });
  // 'show' is rewritten only when it is exactly "show"; the empty string is stored as is (falsy, so decisions ignore it)
  await prefCase('unknown-visibility/porn="Show"', { raw: [['porn', 'Show']] });
  await prefCase('unknown-visibility/porn=ignore-then-""', { raw: [['porn', 'ignore'], ['porn', '']] });
  await prefCase('unknown-visibility/porn=""-then-ignore', { raw: [['porn', ''], ['porn', 'ignore']] });
  await prefCase('unknown-visibility/nsfw="block"', { raw: [['nsfw', 'block']] });
  await prefCase('unknown-visibility/nsfw=""', { raw: [['nsfw', '']] });
  await prefCase('unknown-visibility/scoped-bsky=""', { raw: [['porn', '', BSKY]] });
  await prefCase('unknown-visibility/scoped-bsky=hide-then-""', { raw: [['porn', 'hide', BSKY], ['porn', '', BSKY]] });
  await prefCase('unknown-visibility/scoped-c1-custom="block"', { raw: [['spoiler', 'block', C1]], labelers: [C1] });
  await prefCase('custom-label/global-spoiler=hide', { raw: [['spoiler', 'hide']] });
  await prefCase('custom-label/global-spoiler=show', { raw: [['spoiler', 'show']] });
  // Catbird's old private key: the reference passes it through unmapped
  await prefCase('private-key/graphic=hide-passes-through-unmapped', { raw: [['graphic', 'hide']] });
  await prefCase('private-key/graphic=warn+graphic-media=hide', { raw: [['graphic', 'warn'], ['graphic-media', 'hide']] });
  await prefCase('private-key/graphic-media=hide+graphic=warn', { raw: [['graphic-media', 'hide'], ['graphic', 'warn']] });
  await prefCase('private-key/scoped-graphic=hide', { raw: [['graphic', 'hide', BSKY]] });
  // deviation (d): the fallback applies only while no global graphic-media / gore entry exists
  await prefCase('private-key/graphic=show', { raw: [['graphic', 'show']] });
  await prefCase('private-key/graphic=""', { raw: [['graphic', '']] });
  await prefCase('private-key/graphic=warn-then-graphic=hide', { raw: [['graphic', 'warn'], ['graphic', 'hide']] });
  await prefCase('private-key/graphic=hide+nsfw=warn', { raw: [['graphic', 'hide'], ['nsfw', 'warn']] });
  await prefCase('private-key/graphic=hide+gore=warn', { raw: [['graphic', 'hide'], ['gore', 'warn']] });
  await prefCase('private-key/gore=warn+graphic=hide', { raw: [['gore', 'warn'], ['graphic', 'hide']] });
  await prefCase('private-key/graphic=hide+graphic-media=""', { raw: [['graphic', 'hide'], ['graphic-media', '']] });
  await prefCase('private-key/graphic=hide+scoped-graphic-media=warn', { raw: [['graphic', 'hide'], ['graphic-media', 'warn', BSKY]] });
  await prefCase('private-key/graphic=hide+scoped-gore=warn', { raw: [['graphic', 'hide'], ['gore', 'warn', BSKY]] });
  await prefCase('private-key/graphic=hide+scoped-graphic=warn', { raw: [['graphic', 'hide'], ['graphic', 'warn', BSKY]] });
  // labelers
  await prefCase('labelers/none-subscribed-app-labeler-only');
  await prefCase('labelers/subscribed-c1', { labelers: [C1] });
  await prefCase('labelers/subscribed-c2+c1-order-kept', { labelers: [C2, C1] });
  await prefCase('labelers/subscribed-bsky-explicitly-dedupes', { labelers: [BSKY, C1] });
  await prefCase('labelers/scoped-on-subscribed-c1', { raw: [['porn', 'hide', C1]], labelers: [C1] });
  await prefCase('labelers/scoped-on-app-labeler-bsky', { raw: [['porn', 'ignore', BSKY]] });
  await prefCase('labelers/scoped-on-unsubscribed-is-dropped', { raw: [['porn', 'hide', UNSUB]], labelers: [C1] });
  await prefCase('labelers/scoped-and-global-mix', {
    raw: [['porn', 'warn'], ['porn', 'hide', BSKY], ['sexual', 'ignore', C1], ['nudity', 'hide']],
    labelers: [C1],
  });
  await prefCase('labelers/scoped-legacy-nsfw-not-remapped', { raw: [['nsfw', 'hide', BSKY]] });
  await prefCase('labelers/scoped-legacy-gore-not-remapped-and-no-double-write', { raw: [['gore', 'hide', C1]], labelers: [C1] });
  await prefCase('labelers/scoped-show-becomes-ignore', { raw: [['porn', 'show', BSKY]] });
  await prefCase('labelers/scoped-same-key-twice-last-wins', { raw: [['porn', 'hide', BSKY], ['porn', 'warn', BSKY]] });
  await prefCase('labelers/scoped-custom-value', { raw: [['spoiler', 'hide', C1]], labelers: [C1] });
  await prefCase('labelers/everything', {
    adult: true,
    raw: [['nsfw', 'hide'], ['porn', 'warn', BSKY], ['gore', 'ignore'], ['spoiler', 'warn', C1], ['sexual', 'show', C2]],
    labelers: [C1, C2],
  });
}

// ---------------------------------------------------------------------------
// Run
// ---------------------------------------------------------------------------

await buildPrefs();
await familyPost();
await familyAuthor();
await familyQuote();
await familyProfile();
await familyCustom();
await familyUndefined();
await familyOrderAndMulti();
await familyRestriction();
await familyDeviation();
await familyUnknownVisibility();

// ---------------------------------------------------------------------------
// Assemble, validate, write
// ---------------------------------------------------------------------------

const topFamily = (id) => id.split('/')[0];

const golden = {
  meta: {
    description:
      'Golden moderation expectations computed by running the real @bsky/sdk moderation code. See tools/moderation-reference/README.md.',
    sdkPackage: '@bsky/sdk',
    sdkVersion: sdkPackage.version,
    socialAppCommit,
    socialAppCommitDate,
    socialAppDeclaresSdk,
    sdkSourceHashes: Object.fromEntries(SDK_FILES.map((f) => [f, sha12(f)])),
    generator: 'Catbird/tools/moderation-reference/generate-golden.mjs',
    now: NOW,
    labelCts: CTS,
    appLabelers: [BSKY],
    dids: { bskyModeration: BSKY, customLabeler1: C1, customLabeler2: C2, unsubscribedLabeler: UNSUB, author: AUTHOR, quotedAuthor: QUOTED, viewer: VIEWER },
    contexts: CONTEXTS,
    conventions: {
      expectedContexts:
        'expected.contexts lists only contexts that are not all-default. A context that is absent, or a boolean/list that is absent inside one, means false / [] and MUST still be asserted. Entries without "type" are label causes.',
      expectedDecision: 'expected.decision.causes is the full cause list in sdk order; isMe is present only when true.',
      userDid: 'null means logged out. "did:plc:author" is the post author / profile owner (isMe).',
      prefs:
        'input.prefs is a key into prefSets. Each value is the output of the real getPreferences() for the raw preferences the key spells out (defaults seeded, legacy keys remapped, app labeler first); mutedWords / hiddenPosts appear only where used.',
      labelDefs:
        'input.labelDefs is a list of keys into definitions (absent = none). definitions[key] = {definedBy, raw, interpreted}: raw is what the labeler service publishes, interpreted is the output of the real interpretLabelValueDefinitions (null if the sdk drops it). Group the keys by definedBy, in list order, to get the per-labeler map handed to moderatePost.',
      subject: 'input.subject is exactly the object handed to moderatePost / moderateProfile, and decodes straight into the typed models: fields the lexicons require but moderation never reads (cid, indexedAt, an empty post record) carry placeholder values.',
      catbird: 'Only scenarios and preference cases with a catbird field differ from the sdk. catbird.expected replaces expected (for a preference case: replaces normalized) for Catbird; everything else must match the sdk exactly.',
    },
    defaultLabelSettings: { ...mod.DEFAULT_LABEL_SETTINGS },
    builtinLabels: JSON.parse(JSON.stringify(mod.LABELS)),
    deviations: [DEV.inactive, DEV.builtinDef, DEV.duplicate, PRIVATE_KEY].map((d) => ({ reason: d.reason, rule: d.rule })),
    counts: {},
  },
  prefs: prefCases,
  prefSets: registry.prefSets,
  definitions: registry.definitions,
  scenarios,
};

// -- validation ------------------------------------------------------------

function fail(msg) {
  throw new Error(`validation failed: ${msg}`);
}
const deepEqual = (a, b) => JSON.stringify(a) === JSON.stringify(b);

// 1. every scenario replays from its serialized form alone (registries included)
const reparsed = JSON.parse(JSON.stringify(golden));
for (const sc of reparsed.scenarios) {
  const replay = evaluate(sc.input, reparsed);
  if (!deepEqual(replay, sc.expected)) fail(`replay mismatch for ${sc.id}`);
}
for (const [key, d] of Object.entries(reparsed.definitions)) {
  const again = interpretDefs(d.definedBy, [d.raw])[0] ?? null;
  if (!deepEqual(again, d.interpreted)) fail(`definition interpretation mismatch for ${key}`);
}
for (const sc of reparsed.scenarios) {
  if (!reparsed.prefSets[sc.input.prefs]) fail(`missing prefs set for ${sc.id}`);
  for (const k of sc.input.labelDefs ?? []) if (!reparsed.definitions[k]) fail(`missing definition ${k} for ${sc.id}`);
}
// 2. every preference case replays through the real getPreferences
for (const pc of prefCases) {
  const again = await normalizedPrefs({ adult: pc.adultContentEnabled, labelers: pc.labelers.length ? pc.labelers : null, content: pc.raw });
  if (!deepEqual(again, pc.normalized)) fail(`prefs replay mismatch for ${pc.id}`);
  if (pc.normalized.labelers[0]?.did !== BSKY) fail(`app labeler missing in ${pc.id}`);
}
// 3. catbird field only where intended, and it must (mostly) differ from the sdk
const withCatbird = scenarios.filter((s) => s.catbird);
for (const s of withCatbird) if (!s.id.startsWith('deviation/')) fail(`catbird field outside deviation family: ${s.id}`);
const catbirdIdentical = withCatbird.filter((s) => deepEqual(s.catbird.expected, s.expected)).map((s) => s.id);
// identical results are only legitimate where the sdk already ignores the input (bang-redefined, unused redefinition)
for (const id of catbirdIdentical) {
  if (!/bang-redefined|control-redefinition-unused/.test(id)) fail(`catbird expected equals sdk expected: ${id}`);
}
// 3b. preference cases: a catbird field exists only for the private-key family and must differ from the sdk
for (const pc of prefCases) {
  if (!pc.catbird) continue;
  if (!pc.id.startsWith('private-key/')) fail(`catbird field outside private-key family: ${pc.id}`);
  if (deepEqual(pc.catbird.expected, pc.normalized)) fail(`catbird expected equals sdk normalized: ${pc.id}`);
  const again = await normalizedPrefs({ adult: pc.adultContentEnabled, labelers: pc.labelers.length ? pc.labelers : null, content: pc.catbird.raw });
  if (!deepEqual(again, pc.catbird.expected)) fail(`catbird prefs replay mismatch for ${pc.id}`);
}
// 4. coverage sanity: every context, every priority, downgraded and noOverride all occur
const seenContexts = new Set();
const seenPriorities = new Set();
let sawDowngraded = false;
let sawNoOverride = false;
let sawFilter = false;
for (const s of scenarios) {
  for (const [ctx, e] of Object.entries(s.expected.contexts)) {
    seenContexts.add(ctx);
    if (e.noOverride) sawNoOverride = true;
    if (e.filter) sawFilter = true;
  }
  for (const c of s.expected.decision.causes) {
    seenPriorities.add(c.priority);
    if (c.downgraded) sawDowngraded = true;
  }
}
for (const ctx of CONTEXTS) if (!seenContexts.has(ctx)) fail(`context never exercised: ${ctx}`);
for (const p of [1, 2, 3, 4, 5, 6, 7, 8]) if (!seenPriorities.has(p)) fail(`priority never exercised: ${p}`);
if (!sawDowngraded || !sawNoOverride || !sawFilter) fail('missing downgraded / noOverride / filter coverage');
// 5. the pinned getPreferences behavior the port must reproduce
const byId = Object.fromEntries(prefCases.map((p) => [p.id, p.normalized]));
if (byId['legacy+canonical/nsfw=hide-then-porn=ignore'].labels.porn !== 'ignore') fail('legacy remap order sanity');
if (byId['canonical+legacy/porn=ignore-then-nsfw=hide'].labels.porn !== 'hide') fail('legacy remap order sanity (reverse)');
if (byId['private-key/graphic=hide-passes-through-unmapped'].labels.graphic !== 'hide') fail('graphic passthrough sanity');

// -- counts ----------------------------------------------------------------

const counts = { scenarios: scenarios.length, prefs: prefCases.length, withCatbird: withCatbird.length, prefsWithCatbird: prefCases.filter((p) => p.catbird).length, scenariosByFamily: {} };
for (const s of scenarios) counts.scenariosByFamily[topFamily(s.id)] = (counts.scenariosByFamily[topFamily(s.id)] ?? 0) + 1;
const byTarget = {};
for (const s of scenarios) {
  const key = s.id.startsWith('deviation/') ? s.id.split('/').slice(0, 2).join('/') : topFamily(s.id);
  byTarget[key] = (byTarget[key] ?? 0) + 1;
}
counts.scenariosByFamilyDetailed = byTarget;
counts.catbirdIdenticalToSdk = catbirdIdentical;
golden.meta.counts = {
  scenarios: counts.scenarios,
  prefs: counts.prefs,
  withCatbird: counts.withCatbird,
  prefsWithCatbird: counts.prefsWithCatbird,
  scenariosByFamily: counts.scenariosByFamily,
};

// -- serialize -------------------------------------------------------------

const compact = JSON.stringify(golden);
JSON.parse(compact); // must parse
if (/[^\x20-\x7e]/.test(compact)) fail('golden contains non-ASCII or control characters');
if (compact.includes('"""') || compact.includes('\\#')) fail('golden contains a sequence that breaks a Swift raw string');

const CHUNK = 96 * 1024;
function chunkJson(text) {
  const chunks = [];
  let start = 0;
  while (start < text.length) {
    let end = Math.min(start + CHUNK, text.length);
    if (end < text.length) {
      const boundary = text.indexOf('},{"id":"', end);
      end = boundary === -1 ? text.length : boundary + 2; // cut after "},"
    }
    chunks.push(text.slice(start, end));
    start = end;
  }
  return chunks;
}
const chunks = chunkJson(compact);
if (chunks.join('') !== compact) fail('chunking changed the JSON');

const swiftSource = [
  '// Generated by Catbird/tools/moderation-reference/generate-golden.mjs. Do not edit.',
  '// Source of truth: the real @bsky/sdk moderation code, pinned below. Regenerate, do not hand-edit.',
  '// swiftlint:disable all',
  '// swiftformat:disable all',
  '',
  '/// Golden moderation expectations (see tools/moderation-reference/README.md).',
  'enum ModerationReferenceGolden {',
  `  static let sdkVersion = ${JSON.stringify(sdkPackage.version)}`,
  `  static let socialAppCommit = ${JSON.stringify(socialAppCommit)}`,
  '',
  '  /// The golden JSON, assembled from raw-string chunks.',
  `  static let json: String = [${chunks.map((_, i) => `part${i}`).join(', ')}].joined()`,
  '',
  ...chunks.flatMap((c, i) => [`  private static let part${i} = #"""`, c, '"""#', '']),
  '}',
  '',
].join('\n');

const outJson = path.resolve(args['out-json'] ?? path.join(HERE, 'golden.json'));
const outSwift = path.resolve(
  args['out-swift'] ?? path.join(HERE, '..', '..', 'CatbirdTests', 'Moderation', 'ModerationReferenceGolden.swift'),
);

if (args.check) {
  const same = fs.existsSync(outJson) && fs.readFileSync(outJson, 'utf8') === compact + '\n'
    && fs.existsSync(outSwift) && fs.readFileSync(outSwift, 'utf8') === swiftSource;
  console.log(same ? 'check: golden files are up to date' : 'check: golden files DIFFER from a fresh run');
  process.exit(same ? 0 : 1);
}

fs.mkdirSync(path.dirname(outJson), { recursive: true });
fs.mkdirSync(path.dirname(outSwift), { recursive: true });
fs.writeFileSync(outJson, compact + '\n');
fs.writeFileSync(outSwift, swiftSource);

// -- report ----------------------------------------------------------------

console.log(`sdk ${sdkPackage.version}  social-app ${socialAppCommit}`);
console.log(`wrote ${outJson} (${(compact.length / 1024).toFixed(1)} KB)`);
console.log(`wrote ${outSwift} (${(swiftSource.length / 1024).toFixed(1)} KB, ${chunks.length} chunk(s))`);
console.log(`prefs cases: ${prefCases.length}  (with catbird field: ${counts.prefsWithCatbird})`);
console.log(`scenarios: ${scenarios.length}  (with catbird field: ${withCatbird.length})`);
for (const [k, v] of Object.entries(counts.scenariosByFamily)) console.log(`  ${k.padEnd(20)} ${v}`);
console.log('  deviation breakdown:');
for (const [k, v] of Object.entries(byTarget).filter(([k]) => k.startsWith('deviation/'))) console.log(`    ${k.padEnd(48)} ${v}`);
console.log(`catbird expected identical to sdk (sdk already ignores the input): ${catbirdIdentical.length}`);
