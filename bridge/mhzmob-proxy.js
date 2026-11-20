'use strict';

const ALLOWED_PATHS = new Set(['/chargers', '/current-session', '/sessions']);
const SAFE_ERRORS = new Map([
  [400, new Set(['invalid_query', 'invalid_session_id'])],
  [401, new Set(['unauthorized'])],
  [404, new Set(['charger_not_found'])],
  [502, new Set([
    'charger_name_ambiguous',
    'upstream_error',
    'upstream_invalid_data',
    'upstream_invalid_json',
  ])],
  [503, new Set(['auth_not_configured'])],
]);

function allowedPath(path) {
  return ALLOWED_PATHS.has(path) || /^\/sessions\/[^/]+$/.test(path);
}

function createMhzMobProxy({
  express,
  baseUrl = 'http://127.0.0.1:8792',
  fetchImpl = global.fetch,
}) {
  const router = express.Router();

  router.get('*', async (request, response) => {
    if (request.method !== 'GET' || !allowedPath(request.path)) {
      response.status(404).json({ error: 'not_found' });
      return;
    }

    try {
      const upstreamUrl = new URL(`/api${request.url}`, baseUrl);
      const upstream = await fetchImpl(upstreamUrl, {
        signal: AbortSignal.timeout(5_000),
      });
      const contentType = upstream.headers.get('content-type') || '';
      if (!contentType.includes('application/json')) throw new Error('non-json response');
      const body = await upstream.json();
      if (upstream.ok) {
        response.status(upstream.status).json(body);
        return;
      }
      const allowed = SAFE_ERRORS.get(upstream.status);
      if (
        !allowed?.has(body?.error)
        || !body
        || typeof body !== 'object'
        || Array.isArray(body)
        || Object.keys(body).length !== 1
      ) {
        throw new Error('unbounded upstream error');
      }
      response.status(upstream.status).json({ error: body.error });
    } catch {
      response.status(502).json({ error: 'mhzmob_unavailable' });
    }
  });

  router.use((_request, response) => {
    response.status(404).json({ error: 'not_found' });
  });

  return router;
}

module.exports = { createMhzMobProxy };
