#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

run_node_test <<'JS'
const fs = require('fs')
const picker = requireFromRoot('shell/plugins/image-picker/ImagePickerModel.js')

assertEqual(picker.nameForPath('/themes/nord-river.png'), 'nord-river', 'image picker strips directory and extension')
assertEqual(picker.labelForPath('/themes/nord_river.png'), 'Nord River', 'image picker builds display labels')

const rows = [
  '/themes/a/nord-river.png\t/cache/nord-river.jpg',
  '/themes/b/nord-river.png\t/cache/duplicate.jpg',
  '/themes/a/gruvbox-dark.jpeg',
  '',
  '\t/cache/no-path.jpg',
  '/themes/a/plain'
].join('\n')

const images = picker.loadRows(rows)
assertEqual(picker.loadRows('/themes/__proto__\n/themes/constructor').length, 2, 'image picker keeps names that match object prototype properties')
assertDeepEqual(
  images,
  [
    { filePath: '/themes/a/nord-river.png', fileName: 'nord-river.png', thumbnailPath: '/cache/nord-river.jpg' },
    { filePath: '/themes/a/gruvbox-dark.jpeg', fileName: 'gruvbox-dark.jpeg', thumbnailPath: '/themes/a/gruvbox-dark.jpeg' },
    { filePath: '/themes/a/plain', fileName: 'plain', thumbnailPath: '/themes/a/plain' }
  ],
  'image picker parses rows and dedupes by file name'
)

assert(picker.itemMatches(images, 0, 'river'), 'image picker matches file names')
assert(picker.itemMatches(images, 1, 'Gruvbox Dark'), 'image picker matches labels case-insensitively')
assert(!picker.itemMatches(images, 2, 'river'), 'image picker rejects non-matching filters')
assertEqual(picker.firstMatchingIndex(images, 'plain'), 2, 'image picker finds first matching index')
assertEqual(picker.indexForSelectedImage(images, '/themes/a/gruvbox-dark.jpeg'), 1, 'image picker finds selected image')
assertEqual(picker.indexForSelectedImage(images, '/missing.png'), 0, 'image picker defaults selected image to first row')

assertEqual(picker.filteredPosition(images, 2, 'dark'), 1, 'image picker computes filtered position')
assertEqual(picker.selectedFilteredPosition(images, 2, 'dark'), 0, 'image picker selected filtered position falls back when selected is hidden')
assertEqual(picker.nextSelectedIndexForFilter(images, 0, 'dark'), 1, 'image picker moves selection to first match when filter hides current item')

const imagePickerQml = fs.readFileSync(path.join(root, 'shell/plugins/image-picker/ImagePicker.qml'), 'utf8')
assert(
  /function preloadRows[\s\S]*if \(opened \|\| requestActive\) return/.test(imagePickerQml),
  'image picker ignores cache preloads while a request is visible'
)
assert(
  /source: item\.sourceActivated && item\.thumbnailPath \? Util\.fileUrl\(item\.thumbnailPath\) : ""[\s\S]*asynchronous: false/.test(imagePickerQml),
  'image picker loads activated thumbnails synchronously to avoid carousel flicker'
)
JS

picker_test_dir=$(mktemp -d)
trap 'rm -rf "$picker_test_dir"' EXIT
mkdir -p "$picker_test_dir/images" "$picker_test_dir/cache/image-selector"
printf 'original' >"$picker_test_dir/images/wallpaper.png"
signature=$(stat -Lc '%s:%Y' "$picker_test_dir/images/wallpaper.png")
hash=$(printf '%s\t%s' "$picker_test_dir/images/wallpaper.png" "$signature" | md5sum | cut -d ' ' -f 1)
printf 'thumbnail' >"$picker_test_dir/cache/image-selector/$hash.jpg"
picker_rows=$(OMARCHY_PATH="$ROOT" OMARCHY_CACHE_HOME="$picker_test_dir/cache" "$ROOT/shell/plugins/image-picker/list.sh" "$picker_test_dir/images")
[[ $picker_rows == "$picker_test_dir/images/wallpaper.png"$'\t'"$picker_test_dir/cache/image-selector/$hash.jpg" ]] || fail "image picker uses thumbnails from the session cache"
pass "image picker uses thumbnails from the session cache"

run_node_test <<'JS'
const fs = require('fs')
const vm = require('vm')
const source = fs.readFileSync(root + '/shell/plugins/image-picker/ImagePicker.qml', 'utf8')
const completed = []
const state = { requestSerial: 7, requestActive: true, doneFile: '/private/request.done', selectionFile: '/private/selection', opened: true, finishDoneFile: file => completed.push(file) }
state.root = state
vm.createContext(state)
vm.runInContext(source.match(/  function cancel\([^]*?\n  }/)[0], state)
state.cancel()
assertEqual(state.requestSerial, 8, 'cancel invalidates all callbacks belonging to the prior scan')
assertDeepEqual(completed, ['/private/request.done'], 'cancel still completes the waiting caller')
assertEqual(state.opened, false, 'canceled picker stays closed')
JS
