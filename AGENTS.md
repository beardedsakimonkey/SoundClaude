Authoritative technical sources (use these; do not invent endpoints or headers):
- OpenAPI / Swagger UI: https://developers.soundcloud.com/docs/api/explorer/open-api
- OpenAPI spec JSON: /docs/api/explorer/api.json
- OpenAPI spec YAML (local): ./docs/api.yaml
- API Guide (auth, uploads, playback, pagination, errors): https://developers.soundcloud.com/docs/api/guide
- LLM-oriented overview: https://developers.soundcloud.com/docs/llm-context

Rules:
1. Base URL for API calls: https://api.soundcloud.com. Token endpoint host: https://secure.soundcloud.com
2. Authentication is OAuth 2.1; PKCE is required for the authorization code flow. Prefer the flows and parameters described in the API Guide.
3. Send access tokens on API requests using the header: Authorization: OAuth <access_token> (unless the spec documents a different requirement for a specific endpoint).
4. Access tokens expire after roughly one hour. Refresh tokens are single-use; implement refresh without infinite retry loops. Refreshing and reusing tokens until they are close to expiry avoids unnecessary token exchanges that can hit rate limits on new-token requests.
5. Client Credentials token exchange is rate-limited (per app and per IP). Cache access tokens; renew with the refresh_token grant instead of requesting new client_credentials tokens on every startup or request.
6. Respect rate limits (including play-stream limits). On HTTP 429, back off exponentially and surface errors clearly.
7. Many list endpoints support pagination with linked_partitioning=true and a next_href field; follow it until absent.
8. Not all tracks are playable for every client; handle preview/blocked/streamable states as documented.
9. Never hardcode client_id, client_secret, or tokens; load them from environment variables or a secrets manager.
10. Comply with the SoundCloud API Terms of Use and attribution/branding requirements when shipping a product.
