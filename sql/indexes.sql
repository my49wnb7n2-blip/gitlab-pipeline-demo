CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_audit_logs_test_cleanup
ON audit_logs_test (created_at, uuid);
