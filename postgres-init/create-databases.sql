-- Runs once on first Postgres init. Creates one database per stateful service
-- (grading-service is stateless and has none). The role is POSTGRES_USER.
CREATE DATABASE auth_db;
CREATE DATABASE quiz_db;
CREATE DATABASE quiz_attempt_db;
CREATE DATABASE quiz_notification_db;
CREATE DATABASE quiz_analytics_db;
