# Incident 01 — App reachable inside the container, not outside

**Symptom**
`curl` from the host returned an empty reply. `docker compose ps` showed
the container Up with no restarts.

**What I checked, in order**
1. `docker compose ps` — container healthy, so not a crash.
2. `docker compose logs app` — clean startup, no errors.
3. `docker compose exec app curl localhost:8080` — worked inside.
   That narrowed it to the network boundary, not the app.
4. `docker compose exec app ss -tlnp` — listening on 127.0.0.1:8080.

**Root cause**
The app bound to the container's own loopback address, which nothing
outside the container can reach.

**Fix**
Bound to 0.0.0.0 so it accepts connections on all interfaces.

**What I'd add to prevent it**
A startup check that fails the container if it isn't listening on 0.0.0.0,
and a Prometheus alert when the scrape target goes down for 2 minutes.

**Time to diagnose:** 12 minutes
