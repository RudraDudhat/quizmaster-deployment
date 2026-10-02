# QuizMaster — Microservices Deployment

One command boots the entire platform: Postgres, Kafka, Eureka, the API gateway,
and all six application services — built from source, wired together, healthchecked.

```bash
cd quizmaster-deployment
docker compose up --build
```

That's it. First run builds 8 images from source (~10–20 min; the Maven cache is
shared so it's much faster afterwards). Add `-d` to run detached.

- **API gateway (everything goes through here):** http://localhost:8080
- **Eureka dashboard (see who registered):** http://localhost:8761

Stop / reset:
```bash
docker compose down           # stop
docker compose down -v        # stop + wipe the Postgres volume (fresh DBs)
```

---

## Architecture

```
                                   ┌──────────────────────────┐
        browser / frontend  ─────▶ │   api-gateway  :8080     │   (JWT verify, CORS,
        (localhost:5173)           │   Spring Cloud Gateway   │    route by path)
                                   └────────────┬─────────────┘
                                                │  lb:// via Eureka
        ┌───────────────────────────────────────┼───────────────────────────────────────┐
        │                     │                  │                  │                     │
        ▼                     ▼                  ▼                  ▼                     ▼
┌───────────────┐   ┌───────────────┐   ┌───────────────┐   ┌───────────────┐   ┌───────────────┐
│ auth-service  │   │ quiz-service  │   │attempt-service│   │notification-svc│   │analytics-svc  │
│    :8081      │   │    :8082      │   │    :8083      │   │    :8085      │   │    :8086      │
│ users, JWT,   │   │ quizzes,      │   │ attempts,     │   │ in-app + email│   │ CQRS read     │
│ groups,       │   │ questions,    │   │ answers,      │   │ (Kafka        │   │ model (Kafka  │
│ students      │   │ snapshot API  │   │ audit         │   │  consumer)    │   │  consumer)    │
└──────┬────────┘   └──────┬────────┘   └──────┬────────┘   └──────┬────────┘   └──────┬────────┘
       │ auth_db           │ quiz_db           │ quiz_attempt_db   │ quiz_          │ quiz_
       │                   │                   │                   │ notification_db│ analytics_db
       └───────────────────┴─────────┬─────────┴───────────────────┴────────────────┘
                                      ▼
                            ┌───────────────────┐        ┌──────────────────────┐
                            │  postgres :5432   │        │  grading-service :8084│
                            │  (5 databases)    │        │  stateless scoring    │
                            └───────────────────┘        │  engine (no DB)       │
                                                         └──────────┬───────────┘
                                      ┌─────────────────────────────┘
                                      ▼
                            ┌───────────────────┐
                            │   kafka :9092     │   (KRaft, no Zookeeper)
                            └───────────────────┘
                                      │
   event flow:  attempt ──quiz.attempt.submitted──▶ grading
                grading ──quiz.attempt.graded─────▶ attempt (persist) + notification + analytics
                grading ──quiz.essay.graded───────▶ notification

   sync (Feign, internal /api/internal, never gateway-routed):
                attempt ──▶ quiz     (fetch quiz snapshot at attempt start)
                grading ──▶ attempt  (fetch grading-job for admin essay regrade)
                auth    ──▶ analytics (embed a student's stats in admin detail)
                quiz    ──▶ auth     (resolve group names)
```

**Dependency rule:** everyone may call `auth`; `auth` calls only `analytics` (a
leaf). No service-to-service cycles. Everything on `/api/internal/**` is
trusted-network only and is never routed by the gateway.

---

## Services & ports

| Service                | Port | Database              | Kafka | Notes                              |
|------------------------|------|-----------------------|-------|------------------------------------|
| api-gateway            | 8080 | –                     | –     | single public entry point          |
| eureka-server          | 8761 | –                     | –     | service discovery dashboard        |
| auth-service           | 8081 | `auth_db`             | –     | users, JWT, groups, student admin  |
| quiz-service           | 8082 | `quiz_db`             | –     | quizzes, questions, snapshot API   |
| attempt-service        | 8083 | `quiz_attempt_db`     | ✅    | attempts; publishes submitted      |
| grading-service        | 8084 | – (stateless)         | ✅    | scoring engine + essay grading     |
| notification-service   | 8085 | `quiz_notification_db`| ✅    | in-app notifications + email stub  |
| analytics-service      | 8086 | `quiz_analytics_db`   | ✅    | stats/reports (CQRS read model)    |
| postgres               | 5433*| –                     | –     | *host 5433 → container 5432        |
| kafka                  | –    | –                     | –     | internal only (`kafka:9092`)       |

Postgres is published on host **5433** to avoid clashing with a local Postgres on 5432.

---

## Configuration

All runtime config lives in [`.env`](.env). Before anything real, change:

- **`JWT_SECRET`** — must be a long random string; auth signs and the gateway verifies with it.
- **`POSTGRES_PASSWORD`** — the DB password.
- `GOOGLE_CLIENT_ID` / `GOOGLE_CLIENT_SECRET` — real values to enable Google login
  (placeholders are non-empty on purpose: auth-service's OAuth2 auto-config refuses to
  start on an empty client id).
- `MAIL_*` — real SMTP to actually send emails (notification-service logs instead by default).

`KAFKA_ENABLED=true` runs the full event-driven flow. Set it to `false` only if you
want the services up without a broker (grading/notifications/analytics go idle).

Databases are created automatically on first boot by
[`postgres-init/create-databases.sql`](postgres-init/create-databases.sql). Schema is
generated by Hibernate (`ddl-auto=update`) — no migrations.

---

## Smoke test (once everything is `Up`)

```bash
# 1. discovery — all services should be listed
open http://localhost:8761

# 2. register + log in through the gateway
curl -X POST http://localhost:8080/api/v1/auth/register \
  -H "Content-Type: application/json" \
  -d '{"email":"admin@quiz.com","password":"Passw0rd!","fullName":"Admin"}'

curl -X POST http://localhost:8080/api/v1/auth/login \
  -H "Content-Type: application/json" \
  -d '{"email":"admin@quiz.com","password":"Passw0rd!"}'
# → copy the accessToken, then call admin/student endpoints with:
#   -H "Authorization: Bearer <token>"
```

The full event demo: create + publish a quiz (quiz-service), start an attempt
(attempt-service), submit → watch `grading-service` log the graded event →
`notification-service` create a "result ready" row → `analytics-service` ingest it.

---

## Troubleshooting

- **First build is slow / seems stuck.** It's compiling 8 Spring Boot apps from
  source. Watch progress with `docker compose build`. Requires Docker BuildKit
  (default on modern Docker Desktop) for the shared Maven cache mount.
- **A service restarts a few times at startup.** Expected — it waits for Eureka /
  Kafka to be reachable and retries. `depends_on` healthchecks gate on Postgres and
  Kafka; Eureka is tolerated as eventually-available.
- **Port already in use (8080–8086, 8761, 5433).** Stop any locally-running instance
  of that service (you don't need to run them locally and in Docker at once).
- **See a service's logs:** `docker compose logs -f attempt-service`
- **Rebuild one service after a code change:** `docker compose up -d --build quiz-service`
- **Fresh databases:** `docker compose down -v && docker compose up --build`
```
