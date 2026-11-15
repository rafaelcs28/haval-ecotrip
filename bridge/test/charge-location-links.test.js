'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const {
  discoverChargeLocations,
  findNearbyKnownPlace,
  hasChargeLocationCoordinates,
  resolveChargeLocationLinks,
  runPersistedMutation,
  setChargeLocationLink,
} = require('../charge-location-links');

test('requires both real coordinates before creating a known place', () => {
  assert.equal(hasChargeLocationCoordinates({ lat: null, lng: null }), false);
  assert.equal(hasChargeLocationCoordinates({ lat: 0, lng: 0 }), false);
  assert.equal(hasChargeLocationCoordinates({ lat: 0, lng: 10 }), true);
  assert.equal(hasChargeLocationCoordinates({ lat: -16.7, lng: -49.2 }), true);
});

test('same display name at distant coordinates is not a known-place duplicate', () => {
  const knownPlaces = [{ id: 1, name: 'Shopping', lat: -16.7, lng: -49.2 }];

  assert.equal(findNearbyKnownPlace(knownPlaces, { name: 'Shopping', lat: -17.7, lng: -50.2 }), null);
  assert.equal(findNearbyKnownPlace(knownPlaces, { name: 'Outro nome', lat: -16.7001, lng: -49.2001 })?.id, 1);
});

test('restores in-memory state when persistence fails', () => {
  const state = { value: 'before' };

  assert.throws(() => runPersistedMutation(
    () => { state.value = 'after'; },
    () => { throw new Error('disk full'); },
    () => { state.value = 'before'; }
  ), /disk full/);
  assert.equal(state.value, 'before');
});

test('discovers persisted candidates from charge history without changing charges', () => {
  const charges = [{
    location_name: 'YellotMob | T-63',
    location_lat: -16.701,
    location_lng: -49.261,
  }];
  const original = structuredClone(charges);

  const result = discoverChargeLocations([], charges, () => 101);

  assert.equal(result.changed, true);
  assert.deepEqual(result.locations, [{
    id: 101,
    name: 'YellotMob | T-63',
    lat: -16.701,
    lng: -49.261,
    known_place_id: null,
  }]);
  assert.deepEqual(charges, original);
});

test('preserves legacy entries and their stable identifiers', () => {
  const stored = [{ id: 7, name: 'Nome antigo', lat: -16.7, lng: -49.2 }];
  const charges = [{ location_name: 'Nome novo', location_lat: -16.7001, location_lng: -49.2001 }];

  const result = discoverChargeLocations(stored, charges, () => 99);

  assert.equal(result.changed, false);
  assert.deepEqual(result.locations, stored);
  assert.equal(result.locations[0].id, 7);
});

test('skips generated identifiers already used by persisted entries', () => {
  const ids = [7, 8];
  const result = discoverChargeLocations(
    [{ id: 7, name: 'Legado', lat: -16.7, lng: -49.2 }],
    [{ location_name: 'Novo', location_lat: -17.7, location_lng: -50.2 }],
    () => ids.shift()
  );

  assert.equal(result.locations[1].id, 8);
});

test('deduplicates different names only when coordinates are within 100 meters', () => {
  let nextId = 1;
  const charges = [
    { location_name: 'A', location_lat: -16.7000, location_lng: -49.2000 },
    { location_name: 'B', location_lat: -16.7002, location_lng: -49.2002 },
  ];

  const result = discoverChargeLocations([], charges, () => nextId++);

  assert.equal(result.locations.length, 1);
});

test('keeps same name at distant coordinates as separate candidates', () => {
  let nextId = 1;
  const charges = [
    { location_name: 'Shopping', location_lat: -16.7, location_lng: -49.2 },
    { location_name: 'Shopping', location_lat: -16.8, location_lng: -49.3 },
  ];

  const result = discoverChargeLocations([], charges, () => nextId++);

  assert.deepEqual(result.locations.map(item => item.id), [1, 2]);
});

test('groups coordinate-less history by display name but does not link it', () => {
  let nextId = 1;
  const charges = [
    { location_name: 'Garagem' },
    { location_name: ' garagem ' },
  ];

  const result = discoverChargeLocations([], charges, () => nextId++);

  assert.equal(result.locations.length, 1);
  assert.equal(result.locations[0].lat, null);
  assert.equal(result.locations[0].lng, null);
  assert.equal(result.locations[0].known_place_id, null);
});

test('keeps valid links and clears links to deleted known places', () => {
  const stored = [
    { id: 1, name: 'A', known_place_id: 10 },
    { id: 2, name: 'B', known_place_id: 99 },
  ];

  const result = resolveChargeLocationLinks(stored, [{ id: 10 }]);

  assert.equal(result.changed, true);
  assert.equal(result.locations[0].known_place_id, 10);
  assert.equal(result.locations[1].known_place_id, null);
});

test('links only existing charging and known place identifiers', () => {
  const stored = [{ id: 1, name: 'A', known_place_id: null }];
  const known = [{ id: 10, name: 'Casa' }];

  assert.equal(setChargeLocationLink(stored, '1', known, '10'), true);
  assert.equal(stored[0].known_place_id, 10);
  assert.equal(setChargeLocationLink(stored, 'missing', known, '10'), false);
  assert.equal(setChargeLocationLink(stored, '1', known, 'missing'), false);
});
