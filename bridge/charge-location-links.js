'use strict';

function validCoordinates(item) {
  const lat = Number(item?.lat ?? item?.location_lat);
  const lng = Number(item?.lng ?? item?.location_lng);
  return Number.isFinite(lat) && Number.isFinite(lng)
    && lat >= -90 && lat <= 90 && lng >= -180 && lng <= 180
    && !(lat === 0 && lng === 0);
}

function coordinates(item) {
  return {
    lat: Number(item?.lat ?? item?.location_lat),
    lng: Number(item?.lng ?? item?.location_lng),
  };
}

function distanceM(a, b) {
  const left = coordinates(a);
  const right = coordinates(b);
  const radius = 6_371_000;
  const dLat = (right.lat - left.lat) * Math.PI / 180;
  const dLng = (right.lng - left.lng) * Math.PI / 180;
  const value = Math.sin(dLat / 2) ** 2
    + Math.cos(left.lat * Math.PI / 180) * Math.cos(right.lat * Math.PI / 180)
    * Math.sin(dLng / 2) ** 2;
  return radius * 2 * Math.atan2(Math.sqrt(value), Math.sqrt(1 - value));
}

function normalizedName(value) {
  return String(value || '').trim().toLocaleLowerCase('pt-BR');
}

function discoverChargeLocations(stored, charges, makeId) {
  const locations = (Array.isArray(stored) ? stored : []).map(item => ({ ...item }));
  const usedIds = new Set(locations.map(item => String(item.id)));
  let changed = false;

  for (const charge of Array.isArray(charges) ? charges : []) {
    const name = String(charge?.location_name || '').trim();
    if (!name) continue;

    const hasCoordinates = validCoordinates(charge);
    const existing = locations.find(location => {
      if (hasCoordinates && validCoordinates(location)) return distanceM(location, charge) < 100;
      if (!hasCoordinates && !validCoordinates(location)) {
        return normalizedName(location.name) === normalizedName(name);
      }
      return false;
    });
    if (existing) continue;

    const point = hasCoordinates ? coordinates(charge) : { lat: null, lng: null };
    let id = makeId();
    while (usedIds.has(String(id))) id = makeId();
    usedIds.add(String(id));
    locations.push({
      id,
      name,
      lat: point.lat,
      lng: point.lng,
      known_place_id: null,
    });
    changed = true;
  }

  return { locations, changed };
}

function resolveChargeLocationLinks(stored, knownPlaces) {
  const knownIds = new Set((Array.isArray(knownPlaces) ? knownPlaces : []).map(place => String(place.id)));
  let changed = false;
  const locations = (Array.isArray(stored) ? stored : []).map(item => {
    if (item.known_place_id == null || knownIds.has(String(item.known_place_id))) return { ...item };
    changed = true;
    return { ...item, known_place_id: null };
  });
  return { locations, changed };
}

function setChargeLocationLink(stored, locationId, knownPlaces, knownPlaceId) {
  const location = (Array.isArray(stored) ? stored : []).find(item => String(item.id) === String(locationId));
  const knownPlace = (Array.isArray(knownPlaces) ? knownPlaces : []).find(item => String(item.id) === String(knownPlaceId));
  if (!location || !knownPlace) return false;
  location.known_place_id = knownPlace.id;
  return true;
}

function findNearbyKnownPlace(knownPlaces, location, maxDistance = 50) {
  if (!validCoordinates(location)) return null;
  return (Array.isArray(knownPlaces) ? knownPlaces : []).find(place =>
    validCoordinates(place) && distanceM(place, location) < maxDistance
  ) || null;
}

function runPersistedMutation(apply, persist, rollback) {
  apply();
  try {
    persist();
  } catch (error) {
    rollback();
    throw error;
  }
}

module.exports = {
  discoverChargeLocations,
  findNearbyKnownPlace,
  hasChargeLocationCoordinates: validCoordinates,
  resolveChargeLocationLinks,
  runPersistedMutation,
  setChargeLocationLink,
};
