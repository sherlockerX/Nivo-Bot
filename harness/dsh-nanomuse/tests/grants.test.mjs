// The Permissions page's standing grants (src/desk.ts): every remembered permission as one
// list — the remote-control switch, the devices allowed without asking, the hands' per-app
// grants — with the tier each belongs to, and the grouping by tier the page draws.
import assert from 'node:assert/strict'
import { test } from 'node:test'
import { DEVICE_GRANT_PREFIX, GRANT_TIERS, groupGrants, REMOTE_CONTROL_GRANT_ID, standingGrants } from '../lib/desk.js'

test('the three tiers, highest first, are the contract', () => {
  assert.deepEqual([...GRANT_TIERS], ['highest', 'confirm', 'notice'])
})

test('nothing remembered is an empty list and no groups', () => {
  assert.deepEqual(standingGrants({}), [])
  assert.deepEqual(standingGrants({ grants: [], trusted: [], remoteControl: false }), [])
  assert.deepEqual(groupGrants([]), [])
})

test('every store lands in the list with its kind, tier and a revocable id', () => {
  const list = standingGrants({
    grants: [{ id: 'g-1a2b', target: 'computer_app:Safari', at: 3000 }],
    trusted: [{ id: 'dev-9', name: 'Pixel', at: 2000 }, { id: 'dev-nameless', name: '', at: 1000 }],
    remoteControl: true,
  })
  assert.deepEqual(list, [
    { id: REMOTE_CONTROL_GRANT_ID, kind: 'remote_control', tier: 'highest', target: '', at: 0 },
    { id: `${DEVICE_GRANT_PREFIX}dev-9`, kind: 'device', tier: 'confirm', target: 'Pixel', at: 2000 },
    { id: `${DEVICE_GRANT_PREFIX}dev-nameless`, kind: 'device', tier: 'confirm', target: 'dev-nameless', at: 1000 },
    { id: 'g-1a2b', kind: 'computer_app', tier: 'confirm', target: 'Safari', at: 3000 },
  ])
  // the hands' grant keeps the id the host gave it, so the Computer page's Revoke and this one are the same call
  assert.equal(list[3].id, 'g-1a2b')
})

test('the switch off and no devices leaves the hands alone in the card tier', () => {
  const list = standingGrants({ grants: [{ id: 'g-1', target: 'computer_app:Finder', at: 1 }], remoteControl: false })
  assert.equal(list.length, 1)
  assert.equal(list[0].tier, 'confirm')
  assert.equal(list[0].target, 'Finder')
})

test('groups come in tier order, newest first inside, empty tiers left out', () => {
  const groups = groupGrants([
    { id: 'g-old', kind: 'computer_app', tier: 'confirm', target: 'Safari', at: 100 },
    { id: 'device:x', kind: 'device', tier: 'confirm', target: 'Pixel', at: 300 },
    { id: 'remote-control', kind: 'remote_control', tier: 'highest', target: '', at: 0 },
    { id: 'g-new', kind: 'computer_app', tier: 'confirm', target: 'Mail', at: 200 },
  ])
  assert.deepEqual(groups.map((g) => g.tier), ['highest', 'confirm'])
  assert.deepEqual(groups[0].grants.map((g) => g.id), ['remote-control'])
  assert.deepEqual(groups[1].grants.map((g) => g.id), ['device:x', 'g-new', 'g-old'])
  // only the card tier: one group
  assert.deepEqual(groupGrants(standingGrants({ grants: [{ id: 'g-1', target: 'computer_app:Safari', at: 1 }] })).map((g) => g.tier), ['confirm'])
})
