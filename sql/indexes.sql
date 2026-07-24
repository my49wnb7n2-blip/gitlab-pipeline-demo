CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_audit_logs_cleanup
ON audit_logs (created_at, id);

